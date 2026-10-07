// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BasketTestBase, BaskVault, FeedMock} from "./Base.t.sol";

contract AdversarialSequencesTest is BasketTestBase {
    /// @dev Prices stay fixed throughout each campaign; changing/lagging feed profit is accepted design.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzzRepeatedBasketRoundTripsCannotCreateValue(
        uint256 amountSeed,
        uint256 priceSeed,
        uint8 cyclesSeed,
        bool feesSet
    ) public {
        if (feesSet) {
            vm.prank(OWNER);
            vault.setFeeRecipient(address(0xFEE));
        }
        uint256[3] memory prices;
        for (uint256 i; i < 3; ++i) {
            prices[i] = bound(uint256(keccak256(abi.encode(priceSeed, i))), 25e8, 400e8);
            feeds[i].set(int256(prices[i]), vm.getBlockTimestamp());
            _deposit(i, 10e18);
            stocks[i].mint(OTHER, 100e18);
            vm.prank(OTHER);
            stocks[i].approve(address(vault), type(uint256).max);
        }
        uint256 cycles = bound(uint256(cyclesSeed), 2, 16);
        uint256 valueBefore;
        for (uint256 i; i < 3; ++i) {
            valueBefore += stocks[i].rawBalance(OTHER) * prices[i];
        }
        for (uint256 n; n < cycles; ++n) {
            uint256 i = n % 3;
            uint256 amount = bound(uint256(keccak256(abi.encode(amountSeed, n))), 1e14, 2e18);
            vm.prank(OTHER);
            uint256 shares = vault.deposit(address(stocks[i]), amount, OTHER, 0, vm.getBlockTimestamp());
            // Each cycle also exercises the no-price-read promise during the exit.
            for (uint256 j; j < 3; ++j) {
                feeds[j].configure(8, address(1), true);
            }
            vm.prank(OTHER);
            vault.redeem(shares, new uint256[](0), vm.getBlockTimestamp());
            uint256 valueAfter;
            for (uint256 j; j < 3; ++j) {
                feeds[j].configure(8, address(1), false);
                valueAfter += stocks[j].rawBalance(OTHER) * prices[j];
            }
            assertLe(valueAfter, valueBefore, "fixed-price round trip extracted value");
            assertEq(vault.balanceOf(OTHER), 0, "round trip left unexpected shares");
            valueBefore = valueAfter;
        }
    }

    function testOwnerOnlyEntrypointsRejectGuardianAndUnrelatedCaller() public {
        address token = address(stocks[0]);
        bytes[] memory actions = new bytes[](13);
        actions[0] = abi.encodeCall(vault.transferOwnership, (OTHER));
        actions[1] = abi.encodeCall(vault.setFeeRecipient, (OTHER));
        actions[2] = abi.encodeCall(vault.unpauseDeposits, ());
        actions[3] = abi.encodeCall(vault.lowerNAVCap, (0));
        actions[4] = abi.encodeCall(vault.finalizeGenesis, ());
        actions[5] = abi.encodeCall(vault.proposeAsset, (token, address(feeds[0])));
        actions[6] = abi.encodeCall(vault.proposeAssets, (new address[](0), new address[](0)));
        actions[7] = abi.encodeCall(vault.proposeFeed, (token, address(feeds[1])));
        actions[8] = abi.encodeCall(vault.proposeBand, (token));
        actions[9] = abi.encodeCall(vault.proposeReopen, (token));
        actions[10] = abi.encodeCall(vault.proposeGuardian, (OTHER));
        actions[11] = abi.encodeCall(vault.proposeNAVCap, (2_000_000e18));
        actions[12] = abi.encodeCall(vault.acceptOwnership, ());
        for (uint256 i; i < actions.length; ++i) {
            _mustReject(GUARDIAN, actions[i], BaskVault.Unauthorized.selector);
            _mustReject(USER, actions[i], BaskVault.Unauthorized.selector);
        }
        _mustReject(USER, abi.encodeCall(vault.pauseDeposits, ()), BaskVault.Unauthorized.selector);
        _mustReject(USER, abi.encodeCall(vault.closeAsset, (token)), BaskVault.Unauthorized.selector);
        _mustReject(USER, abi.encodeCall(vault.cancelProposal, (1)), BaskVault.Unauthorized.selector);
        address[3] memory callers = [OWNER, GUARDIAN, USER];
        for (uint256 i; i < callers.length; ++i) {
            _mustReject(
                callers[i], abi.encodeCall(vault.payLeg, (token, callers[i], 1)), BaskVault.Unauthorized.selector
            );
        }
        assertEq(vault.proposalCount(), 0);
        assertEq(vault.owner(), OWNER);
        assertEq(vault.guardian(), GUARDIAN);
        assertEq(vault.feeRecipient(), address(0));
    }

    function testClaimsBelongToCallerEvenAfterSharesAreTransferredAndAllRolesCloseDeposits() public {
        _deposit(0, 10e18);
        stocks[0].blockHolder(USER, true);
        uint256[] memory legs = _redeem(100e18);
        uint256 debt = legs[0];
        assertGt(debt, 0);
        uint256 shares = vault.balanceOf(USER);
        vm.prank(USER);
        vault.transfer(OTHER, shares);
        vm.prank(GUARDIAN);
        vault.closeAsset(address(stocks[0]));
        vm.prank(OWNER);
        vault.pauseDeposits();
        vm.prank(OWNER);
        vault.lowerNAVCap(0);
        feeds[0].configure(8, address(0), true);
        stocks[0].configure(18, true, true);
        vm.warp(vm.getBlockTimestamp() + 6 days);
        vm.prank(OTHER);
        assertEq(vault.claim(address(stocks[0]), OTHER), 0, "shares must not convey another user's debt");
        vm.prank(USER);
        assertEq(vault.claim(address(stocks[0]), OTHER), debt);
        assertEq(stocks[0].rawBalance(OTHER), debt);
        assertEq(vault.owed(USER, address(stocks[0])), 0);
        vm.prank(USER);
        assertEq(vault.claim(address(stocks[0]), OTHER), 0, "claim must not pay twice");
        vm.prank(OTHER);
        vault.redeem(shares, new uint256[](0), vm.getBlockTimestamp());
        assertGt(stocks[0].rawBalance(OTHER), debt, "new holder must still be able to exit");
    }

    function testCompetingFeedProposalsRecheckUniquenessAndKeepFailedProposalPending() public {
        FeedMock replacement = new FeedMock();
        vm.startPrank(OWNER);
        uint256 first = vault.proposeFeed(address(stocks[0]), address(replacement));
        uint256 second = vault.proposeFeed(address(stocks[1]), address(replacement));
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vault.executeProposal(first);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 cooldown = vault.nextAssetChangeAt();
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidFeed.selector, address(replacement)));
        vault.executeProposal(second);
        assertEq(vault.nextAssetChangeAt(), cooldown, "failed execution consumed change cooldown");
        (uint256[] memory ids,) = vault.pendingProposals();
        assertEq(ids.length, 1);
        assertEq(ids[0], second, "failed execution consumed proposal");
        assertEq(vault.feedAsset(address(replacement)), address(stocks[0]));
        assertEq(vault.feedAsset(address(feeds[1])), address(stocks[1]));
    }

    function testZeroAndOneWeiRedemptionsAndFullWalletExit() public {
        uint256[] memory zero = _redeem(0);
        assertEq(zero.length, 3);
        assertEq(vault.totalSupply(), 0);
        _deposit(0, 1e18);
        uint256 supply = vault.totalSupply();
        uint256 managedBefore = vault.managed(address(stocks[0]));
        uint256[] memory dust = _redeem(1);
        assertEq(dust[0], 0);
        assertEq(vault.totalSupply(), supply - 1);
        assertEq(vault.managed(address(stocks[0])), managedBefore);
        _redeem(vault.balanceOf(USER));
        assertEq(vault.balanceOf(USER), 0);
        assertEq(vault.totalSupply(), 1e15);
        assertGt(vault.managed(address(stocks[0])), 0, "locked shares must retain backing");
        _deposit(1, 1e18);
        assertGt(vault.balanceOf(USER), 0, "vault must accept deposits after every user exits");
        assertEq(vault.balanceOf(address(0xdEaD)), 1e15, "locked mint must happen once");
    }

    function testDepositDeferredRedemptionAndClaimEmitAccountingEvents() public {
        address token = address(stocks[0]);
        (uint256 shares, uint256 depositFee) = vault.previewDeposit(token, 1e18);
        vm.expectEmit(true, true, true, true, address(vault));
        emit BaskVault.Deposited(USER, token, OTHER, 1e18, shares, depositFee);
        vm.prank(USER);
        vault.deposit(token, 1e18, OTHER, shares, vm.getBlockTimestamp());
        stocks[0].modes(1, 0);
        (uint256[] memory legs, uint256 redeemFee) = vault.previewRedeem(shares);
        vm.expectEmit(true, true, false, true, address(vault));
        emit BaskVault.PaymentDeferred(OTHER, token, legs[0]);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BaskVault.Redeemed(OTHER, shares, redeemFee);
        vm.prank(OTHER);
        vault.redeem(shares, new uint256[](0), vm.getBlockTimestamp());
        stocks[0].modes(0, 0);
        vm.expectEmit(true, true, true, true, address(vault));
        emit BaskVault.Claimed(OTHER, token, USER, legs[0]);
        vm.prank(OTHER);
        vault.claim(token, USER);
        assertEq(vault.totalOwed(token), 0);
    }

    function _mustReject(address caller, bytes memory action, bytes4 errorSelector) internal {
        vm.prank(caller);
        (bool ok, bytes memory result) = address(vault).call(action);
        assertFalse(ok, "unauthorized action succeeded");
        assertEq(result, abi.encodeWithSelector(errorSelector));
    }
}
