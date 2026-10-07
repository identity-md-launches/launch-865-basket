// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaskVault} from "src/BaskVault.sol";
import {StockMock, FeedMock} from "../mocks/Mocks.sol";

/// @dev Fixed prices isolate accounting from the explicitly accepted stale-price arbitrage.
/// Issuer changes persist between calls; only recoverMarket restores transfer/read availability.
contract BasketHandler is Test {
    BaskVault public immutable vault;
    StockMock[3] internal stocks;
    FeedMock[3] internal feeds;
    address[4] public actors;
    uint256[3] public deposited;
    uint256[3] public donated;
    uint256[3] public issuerBurned;
    uint256[3] public paid;
    uint256[3] public losses;
    uint256 public successfulDeposits;
    uint256 public successfulRedemptions;
    uint256 public successfulClaims;
    uint256 public rejectedDeposits;

    constructor(BaskVault v, StockMock[3] memory tokens, FeedMock[3] memory prices) {
        vault = v;
        stocks = tokens;
        feeds = prices;
        actors = [address(0xA11CE), address(0xB0B), address(0xCA11), address(0xFEE)];
        for (uint256 i; i < 3; ++i) {
            for (uint256 j; j < 4; ++j) {
                tokens[i].mint(actors[j], 1_000_000e18);
                vm.prank(actors[j]);
                tokens[i].approve(address(v), type(uint256).max);
            }
        }
    }

    function deposit(uint256 actorSeed, uint256 receiverSeed, uint256 tokenSeed, uint256 amountSeed) public {
        address actor = actors[actorSeed % 4];
        address receiver = actors[receiverSeed % 4];
        uint256 i = tokenSeed % 3;
        address token = address(stocks[i]);
        uint256 amount = bound(amountSeed, 1e14, 5e18);
        bytes32 beforeState = accountingDigest();
        (BaskVault.Reason reason, address fault) = vault.depositStatus(token);
        if (reason != BaskVault.Reason.OK) {
            vm.expectRevert(abi.encodeWithSelector(BaskVault.DepositUnavailable.selector, reason, fault));
            vm.prank(actor);
            vault.deposit(token, amount, receiver, 0, vm.getBlockTimestamp());
            assertEq(accountingDigest(), beforeState, "rejected deposit mutated accounting");
            ++rejectedDeposits;
            return;
        }

        uint256 quote;
        try vault.previewDeposit(token, amount) returns (uint256 quotedShares, uint256) {
            quote = quotedShares;
        } catch (bytes memory err) {
            // These bounded deposits can hit cumulative caps. Unexpected errors fail the campaign.
            assertEq(bytes4(err), BaskVault.DepositUnavailable.selector, "unexpected preview error");
            assertEq(err.length, 68);
            uint256 capReason;
            assembly { capReason := mload(add(err, 36)) }
            assertTrue(
                capReason == uint256(BaskVault.Reason.NAVCap) || capReason == uint256(BaskVault.Reason.AssetCap)
                    || capReason == uint256(BaskVault.Reason.BucketCap),
                "unexpected cap reason"
            );
            vm.expectRevert(err);
            vm.prank(actor);
            vault.deposit(token, amount, receiver, 0, vm.getBlockTimestamp());
            assertEq(accountingDigest(), beforeState);
            ++rejectedDeposits;
            return;
        }

        uint256 actorBefore = stocks[i].rawBalance(actor);
        uint256 receiverBefore = vault.balanceOf(receiver);
        uint256 transferMode = stocks[i].transferMode();
        if (transferMode != 0 && transferMode != 3) {
            vm.expectRevert(abi.encodeWithSelector(BaskVault.TransferFailed.selector, token));
            vm.prank(actor);
            vault.deposit(token, amount, receiver, quote, vm.getBlockTimestamp());
            assertEq(accountingDigest(), beforeState);
            assertEq(stocks[i].rawBalance(actor), actorBefore, "failed pull debited depositor");
            ++rejectedDeposits;
            return;
        }

        vm.prank(actor);
        uint256 shares = vault.deposit(token, amount, receiver, quote, vm.getBlockTimestamp());
        deposited[i] += amount;
        ++successfulDeposits;
        assertEq(shares, quote, "preview differs from actual shares");
        assertGt(shares, 0);
        assertEq(stocks[i].rawBalance(actor) + amount, actorBefore);
        if (receiver != vault.feeRecipient()) assertEq(vault.balanceOf(receiver), receiverBefore + shares);
        for (uint256 j; j < 3; ++j) {
            (uint256 deficit, uint256 since) = vault.deficits(address(stocks[j]));
            assertEq(deficit, 0, "deposit must clear every loss record");
            assertEq(since, 0);
        }
    }

    function redeem(uint256 actorSeed, uint256 sharesSeed, bool fullBalance) public {
        address actor = actors[actorSeed % 4];
        uint256 balance = vault.balanceOf(actor);
        uint256 shares = fullBalance ? balance : bound(sharesSeed, 0, balance);
        uint256 supply = vault.totalSupply();
        uint256[3] memory beforeTokens;
        uint256[3] memory beforeDebts;
        for (uint256 i; i < 3; ++i) {
            beforeTokens[i] = stocks[i].rawBalance(actor);
            beforeDebts[i] = vault.owed(actor, address(stocks[i]));
        }
        // A valid redemption must succeed in every reachable issuer/role/market state.
        vm.prank(actor);
        uint256[] memory legs = vault.redeem(shares, new uint256[](0), vm.getBlockTimestamp());
        ++successfulRedemptions;
        for (uint256 i; i < 3; ++i) {
            uint256 received = stocks[i].rawBalance(actor) - beforeTokens[i];
            uint256 deferred = vault.owed(actor, address(stocks[i])) - beforeDebts[i];
            assertEq(received + deferred, legs[i], "leg must be paid or owed, exactly once");
            paid[i] += received;
        }
        uint256 fee = (shares + 199) / 200;
        assertEq(vault.totalSupply(), supply - shares + (vault.feeRecipient() == address(0) ? 0 : fee));
    }

    function claim(uint256 actorSeed, uint256 tokenSeed, uint256 receiverSeed) public {
        address actor = actors[actorSeed % 4];
        address receiver = actors[receiverSeed % 4];
        uint256 i = tokenSeed % 3;
        address token = address(stocks[i]);
        uint256 debt = vault.owed(actor, token);
        uint256 balance = stocks[i].rawBalance(address(vault));
        uint256 expected = debt < balance ? debt : balance;
        uint256 beforeTokens = stocks[i].rawBalance(receiver);
        bytes32 beforeState = accountingDigest();
        bool readable = stocks[i].balanceMode() == 0;
        bool transferable = stocks[i].transferMode() == 0 || stocks[i].transferMode() == 3;
        if (!readable || (expected != 0 && !transferable)) {
            vm.expectRevert(abi.encodeWithSelector(BaskVault.TransferFailed.selector, token));
            vm.prank(actor);
            vault.claim(token, receiver);
            assertEq(accountingDigest(), beforeState, "failed claim changed debt");
            assertEq(stocks[i].rawBalance(receiver), beforeTokens);
            return;
        }
        vm.prank(actor);
        uint256 amount = vault.claim(token, receiver);
        assertEq(amount, expected);
        assertEq(stocks[i].rawBalance(receiver) - beforeTokens, amount);
        assertEq(vault.owed(actor, token) + amount, debt);
        paid[i] += amount;
        if (amount != 0) ++successfulClaims;
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 amountSeed, bool delegated) external {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        uint256 amount = bound(amountSeed, 0, vault.balanceOf(from));
        uint256 supply = vault.totalSupply();
        uint256 beforeFrom = vault.balanceOf(from);
        uint256 beforeTo = vault.balanceOf(to);
        if (delegated) {
            vm.prank(from);
            vault.approve(address(this), amount);
            vault.transferFrom(from, to, amount);
            assertEq(vault.allowance(from, address(this)), 0);
        } else {
            vm.prank(from);
            vault.transfer(to, amount);
        }
        assertEq(vault.totalSupply(), supply);
        assertEq(vault.balanceOf(from), from == to ? beforeFrom : beforeFrom - amount);
        assertEq(vault.balanceOf(to), from == to ? beforeTo : beforeTo + amount);
    }

    function donate(uint256 tokenSeed, uint256 amountSeed) external {
        uint256 i = tokenSeed % 3;
        uint256 amount = bound(amountSeed, 0, 10e18);
        uint256 managedBefore = vault.managed(address(stocks[i]));
        stocks[i].mint(address(vault), amount);
        donated[i] += amount;
        assertEq(vault.managed(address(stocks[i])), managedBefore, "donation became managed");
    }

    function issuerBurn(uint256 tokenSeed, uint256 amountSeed) external {
        uint256 i = tokenSeed % 3;
        uint256 balance = stocks[i].rawBalance(address(vault));
        uint256 amount = bound(amountSeed, 0, balance);
        uint256 managedBefore = vault.managed(address(stocks[i]));
        stocks[i].burn(address(vault), amount);
        issuerBurned[i] += amount;
        assertEq(vault.managed(address(stocks[i])), managedBefore, "issuer burn automatically recognized");
    }

    function changeIssuerState(uint256 tokenSeed, uint256 modeSeed, bool unreadable, bool pausedOracle) external {
        uint256[6] memory modes = [uint256(0), 1, 2, 3, 5, 8];
        stocks[tokenSeed % 3].modes(modes[modeSeed % 6], unreadable ? 1 : 0);
        stocks[tokenSeed % 3].configure(18, pausedOracle, false);
    }

    function lossAction(uint256 tokenSeed, bool recognize) external {
        uint256 i = tokenSeed % 3;
        address token = address(stocks[i]);
        (uint256 recorded, uint256 since) = vault.deficits(token);
        uint256 managedBefore = vault.managed(token);
        uint256 balance = stocks[i].rawBalance(address(vault));
        uint256 owed = vault.totalOwed(token);
        uint256 available = balance > owed ? balance - owed : 0;
        uint256 shortfall = managedBefore > available ? managedBefore - available : 0;
        bool readable = stocks[i].balanceMode() == 0;
        if (recognize) {
            if (recorded == 0 || vm.getBlockTimestamp() < since + 7 days) {
                vm.expectRevert(BaskVault.LossNotReady.selector);
                vault.recognizeLoss(token);
            } else if (!readable) {
                vm.expectRevert(abi.encodeWithSelector(BaskVault.TransferFailed.selector, token));
                vault.recognizeLoss(token);
            } else {
                uint256 expected = recorded < shortfall ? recorded : shortfall;
                vault.recognizeLoss(token);
                assertEq(vault.managed(token) + expected, managedBefore);
                losses[i] += expected;
                (uint256 remaining, uint256 remainingSince) = vault.deficits(token);
                assertEq(remaining, 0);
                assertEq(remainingSince, 0);
            }
        } else if (!readable) {
            vm.expectRevert(abi.encodeWithSelector(BaskVault.TransferFailed.selector, token));
            vault.flagDeficit(token);
        } else if (shortfall <= recorded) {
            vm.expectRevert(BaskVault.InvalidInput.selector);
            vault.flagDeficit(token);
        } else {
            vault.flagDeficit(token);
            (uint256 amount, uint256 flaggedAt) = vault.deficits(token);
            assertEq(amount, shortfall);
            assertEq(flaggedAt, vm.getBlockTimestamp());
        }
    }

    function pause(bool paused, bool guardian) external {
        if (paused) {
            vm.prank(guardian ? vault.guardian() : vault.owner());
            vault.pauseDeposits();
        } else {
            vm.prank(vault.owner());
            vault.unpauseDeposits();
        }
    }

    function setFees() external {
        address owner = vault.owner();
        if (vault.feeRecipient() != address(0)) vm.expectRevert(BaskVault.InvalidAddress.selector);
        vm.prank(owner);
        vault.setFeeRecipient(actors[3]);
    }

    function advanceTime(uint256 secondsSeed) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 0, 8 days));
    }

    function recoverMarket() public {
        uint256 time = vm.getBlockTimestamp();
        uint256 next = time / 1 days * 1 days + 16 hours;
        if (next < time) next += 1 days;
        while ((next / 1 days + 4) % 7 == 0 || (next / 1 days + 4) % 7 == 6) next += 1 days;
        vm.warp(next);
        for (uint256 i; i < 3; ++i) {
            stocks[i].modes(0, 0);
            stocks[i].configure(18, false, false);
            feeds[i].set(100e8, next);
        }
    }

    function accountingDigest() public view returns (bytes32 result) {
        result = keccak256(abi.encode(vault.totalSupply(), vault.bucket(), vault.bucketUpdatedAt()));
        for (uint256 i; i < 3; ++i) {
            address token = address(stocks[i]);
            (uint256 deficit, uint256 since) = vault.deficits(token);
            result = keccak256(
                abi.encode(
                    result,
                    vault.managed(token),
                    vault.totalOwed(token),
                    stocks[i].rawBalance(address(vault)),
                    deficit,
                    since
                )
            );
            for (uint256 j; j < 4; ++j) {
                result = keccak256(abi.encode(result, vault.owed(actors[j], token), vault.balanceOf(actors[j])));
            }
        }
    }
}
