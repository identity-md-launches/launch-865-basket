// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BasketTestBase, BaskVault, StockMock, FeedMock} from "./Base.t.sol";

contract RedemptionTest is BasketTestBase {
    function testRedeemFormulaAndNoPriceRead() public {
        for (uint256 i; i < 3; ++i) {
            _deposit(i, 10e18);
        }
        uint256 shares = vault.balanceOf(USER) / 2;
        uint256 supply = vault.totalSupply();
        uint256 fee = (shares + 199) / 200;
        (uint256[] memory preview, uint256 previewFee) = vault.previewRedeem(shares);
        assertEq(previewFee, fee);
        for (uint256 i; i < 3; ++i) {
            feeds[i].configure(8, address(0), true);
            stocks[i].configure(18, true, true);
        }
        vm.prank(GUARDIAN);
        vault.pauseDeposits();
        vm.warp(vm.getBlockTimestamp() + 10 days);
        uint256[] memory result = _redeem(shares);
        assertEq(result, preview);
        for (uint256 i; i < 3; ++i) {
            assertEq(result[i], 10e18 * (shares - fee) / supply);
            assertEq(vault.managed(address(stocks[i])), 10e18 - result[i]);
        }
        assertEq(vault.totalSupply(), supply - shares);
    }

    function testBlockedCallerDefersOnlyBadLegThenClaimsElsewhere() public {
        for (uint256 i; i < 3; ++i) {
            _deposit(i, 10e18);
        }
        stocks[1].blockHolder(USER, true);
        uint256 supply = vault.totalSupply();
        uint256[] memory result = _redeem(100e18);
        assertGt(result[1], 0);
        assertEq(stocks[1].rawBalance(address(vault)), 10e18);
        assertEq(vault.owed(USER, address(stocks[1])), result[1]);
        assertEq(vault.totalOwed(address(stocks[1])), result[1]);
        assertEq(vault.managed(address(stocks[1])), 10e18 - result[1]);
        assertEq(vault.totalSupply(), supply - 100e18);
        assertEq(vault.owed(USER, address(stocks[0])), 0);
        assertEq(stocks[0].rawBalance(address(vault)), 10e18 - result[0]);
        vm.prank(USER);
        vault.claim(address(stocks[1]), OTHER);
        assertEq(stocks[1].rawBalance(OTHER), result[1]);
        assertEq(vault.owed(USER, address(stocks[1])), 0);
        assertEq(vault.totalOwed(address(stocks[1])), 0);
    }

    function testHostileTransfersRollBackAndCreateDebt() public {
        _deposit(0, 10e18);
        uint256[6] memory modes = [uint256(1), 2, 5, 6, 7, 8];
        uint256 debt;
        for (uint256 i; i < modes.length; ++i) {
            stocks[0].modes(modes[i], 0);
            uint256 beforeBalance = stocks[0].rawBalance(USER);
            uint256[] memory result = _redeem(10e18);
            debt += result[0];
            assertEq(stocks[0].rawBalance(USER), beforeBalance);
            assertEq(stocks[0].rawBalance(address(vault)), 10e18);
            assertEq(vault.owed(USER, address(stocks[0])), debt);
        }
        stocks[0].modes(3, 0); // A void return with an exact balance fall is valid.
        vm.prank(USER);
        assertEq(vault.claim(address(stocks[0]), USER), debt);
        assertEq(vault.totalOwed(address(stocks[0])), 0);
    }

    function testEveryUnreadableBalanceOutcomeUsesManaged() public {
        _deposit(0, 10e18);
        for (uint256 mode = 1; mode <= 5; ++mode) {
            stocks[0].modes(0, mode);
            uint256 shares = 10e18;
            uint256 expected = vault.managed(address(stocks[0])) * (shares - shares / 200) / vault.totalSupply();
            uint256 debt = vault.owed(USER, address(stocks[0]));
            uint256[] memory result = _redeem(shares);
            assertEq(result[0], expected);
            assertEq(vault.owed(USER, address(stocks[0])), debt + expected);
        }
        stocks[0].modes(0, 0);
        vm.prank(USER);
        vault.claim(address(stocks[0]), USER);
        assertEq(stocks[0].rawBalance(address(vault)), vault.managed(address(stocks[0])));
    }

    function testUpgradeToNoCodeCannotBlockRedeem() public {
        _deposit(0, 10e18);
        address token = address(stocks[0]);
        vm.etch(token, hex"");
        uint256[] memory amounts = _redeem(100e18);
        assertGt(amounts[0], 0);
        assertEq(vault.owed(USER, token), amounts[0]);
    }

    function testClaimHasNo250kPaymentLimit() public {
        _deposit(0, 10e18);
        stocks[0].modes(9, 0);
        uint256[] memory amounts = _redeem(100e18);
        assertEq(vault.owed(USER, address(stocks[0])), amounts[0]);
        vm.prank(USER);
        uint256 paid = vault.claim(address(stocks[0]), USER);
        assertEq(paid, amounts[0]);
        assertEq(vault.totalOwed(address(stocks[0])), 0);
    }

    function testClaimFailurePreservesDebtAndPartialClaimUsesBalance() public {
        _deposit(0, 10e18);
        stocks[0].modes(1, 0);
        uint256[] memory amounts = _redeem(100e18);
        uint256 debt = amounts[0];
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.TransferFailed.selector, address(stocks[0])));
        vault.claim(address(stocks[0]), USER);
        assertEq(vault.owed(USER, address(stocks[0])), debt);
        stocks[0].modes(0, 0);
        stocks[0].burn(address(vault), 10e18 - debt / 2);
        vm.prank(USER);
        assertEq(vault.claim(address(stocks[0]), OTHER), debt / 2);
        assertEq(vault.owed(USER, address(stocks[0])), debt - debt / 2);
        vm.prank(USER);
        assertEq(vault.claim(address(stocks[0]), OTHER), 0);
        stocks[0].mint(address(vault), debt);
        vm.prank(USER);
        vault.claim(address(stocks[0]), OTHER);
        assertEq(vault.totalOwed(address(stocks[0])), 0);
    }

    function testOwedIsReservedFromLaterRedemptions() public {
        _deposit(0, 10e18);
        stocks[0].modes(1, 0);
        uint256[] memory first = _redeem(100e18);
        stocks[0].modes(0, 0);
        stocks[0].burn(address(vault), 9e18);
        uint256 available = 1e18 > first[0] ? 1e18 - first[0] : 0;
        uint256 expected = available * 99.5e18 / vault.totalSupply();
        uint256[] memory second = _redeem(100e18);
        assertEq(second[0], expected);
        assertEq(vault.totalOwed(address(stocks[0])), first[0]);
        assertEq(vault.managed(address(stocks[0])), 10e18 - first[0] - second[0]);
    }

    function testSlippageAndDeadlineAreAtomicEvenAfterEarlierLegPaid() public {
        for (uint256 i; i < 3; ++i) {
            _deposit(i, 10e18);
        }
        uint256[] memory minimums = new uint256[](3);
        minimums[2] = 100e18;
        uint256 supply = vault.totalSupply();
        uint256 beforeBalance = stocks[0].rawBalance(USER);
        vm.prank(USER);
        vm.expectRevert(BaskVault.Slippage.selector);
        vault.redeem(100e18, minimums, vm.getBlockTimestamp());
        assertEq(vault.totalSupply(), supply);
        assertEq(stocks[0].rawBalance(USER), beforeBalance);
        assertEq(vault.managed(address(stocks[0])), 10e18);
        vm.prank(USER);
        vm.expectRevert(BaskVault.DeadlineExpired.selector);
        vault.redeem(1, new uint256[](0), vm.getBlockTimestamp() - 1);
        vm.prank(OTHER);
        vm.expectRevert(BaskVault.InsufficientShares.selector);
        vault.redeem(1, new uint256[](0), vm.getBlockTimestamp());
        _redeem(1); // The rounded-up fee is the whole share; every leg is zero.
    }

    function testAllUserFacingEntrypointsRejectReentrancy() public {
        bytes[] memory payloads = new bytes[](25);
        address token = address(stocks[0]);
        payloads[0] = abi.encodeCall(vault.approve, (USER, 1));
        payloads[1] = abi.encodeCall(vault.transfer, (USER, 0));
        payloads[2] = abi.encodeCall(vault.transferFrom, (USER, OTHER, 0));
        payloads[3] = abi.encodeCall(vault.deposit, (token, 1, USER, 0, vm.getBlockTimestamp()));
        payloads[4] = abi.encodeCall(vault.redeem, (0, new uint256[](0), vm.getBlockTimestamp()));
        payloads[5] = abi.encodeCall(vault.claim, (token, USER));
        payloads[6] = abi.encodeCall(vault.flagDeficit, (token));
        payloads[7] = abi.encodeCall(vault.recognizeLoss, (token));
        payloads[8] = abi.encodeCall(vault.pauseDeposits, ());
        payloads[9] = abi.encodeCall(vault.unpauseDeposits, ());
        payloads[10] = abi.encodeCall(vault.closeAsset, (token));
        payloads[11] = abi.encodeCall(vault.lowerNAVCap, (0));
        payloads[12] = abi.encodeCall(vault.setFeeRecipient, (USER));
        payloads[13] = abi.encodeCall(vault.transferOwnership, (USER));
        payloads[14] = abi.encodeCall(vault.acceptOwnership, ());
        payloads[15] = abi.encodeCall(vault.proposeAsset, (token, address(feeds[0])));
        payloads[16] = abi.encodeCall(vault.proposeFeed, (token, address(feeds[0])));
        payloads[17] = abi.encodeCall(vault.proposeBand, (token));
        payloads[18] = abi.encodeCall(vault.proposeReopen, (token));
        payloads[19] = abi.encodeCall(vault.proposeGuardian, (USER));
        payloads[20] = abi.encodeCall(vault.cancelProposal, (1));
        payloads[21] = abi.encodeCall(vault.executeProposal, (1));
        payloads[22] = abi.encodeCall(vault.finalizeGenesis, ());
        payloads[23] = abi.encodeCall(vault.proposeNAVCap, (2_000_000e18));
        payloads[24] = abi.encodeCall(vault.proposeAssets, (new address[](0), new address[](0)));
        for (uint256 i; i < payloads.length; ++i) {
            stocks[0].setCallback(address(vault), payloads[i]);
            _deposit(0, 1e18);
            assertTrue(stocks[0].callbackBlocked());
            _redeem(1e18);
            assertEq(vault.totalOwed(token), 0);
        }
        stocks[0].modes(1, 0);
        _redeem(1e18);
        stocks[0].modes(0, 0);
        vm.prank(USER);
        vault.claim(token, USER);
        assertEq(vault.totalOwed(token), 0);
    }

    function testFuzzRedeemConservesManagedPaidAndOwed(uint96 amountSeed, uint96 sharesSeed, bool blocked) public {
        uint256 amount = bound(uint256(amountSeed), 1e16, 250e18);
        _deposit(0, amount);
        uint256 shares = bound(uint256(sharesSeed), 1, vault.balanceOf(USER));
        uint256 supply = vault.totalSupply();
        uint256 expected = amount * (shares - (shares + 199) / 200) / supply;
        stocks[0].blockHolder(USER, blocked);
        uint256[] memory result = _redeem(shares);
        assertEq(result[0], expected);
        assertEq(vault.managed(address(stocks[0])) + expected, amount);
        assertEq(
            stocks[0].rawBalance(address(vault)),
            vault.managed(address(stocks[0])) + vault.totalOwed(address(stocks[0]))
        );
        assertEq(vault.owed(USER, address(stocks[0])), blocked ? expected : 0);
        assertEq(vault.totalSupply(), supply - shares);
    }
}

contract RedemptionGasTest is BasketTestBase {
    function _prepare64() internal {
        _emptyVault(64);
        vm.prank(OWNER);
        vault.finalizeGenesis();
        vm.warp(MONDAY + 3 days);
        _refresh();
        for (uint256 i; i < 64; ++i) {
            _deposit(i, 1e18);
        }
    }

    function _gasCheck() internal {
        uint256 shares = vault.balanceOf(USER);
        for (uint256 i; i < 64; ++i) {
            vm.cool(address(stocks[i]));
        }
        vm.cool(address(vault));
        bytes memory data = abi.encodeCall(vault.redeem, (shares, new uint256[](0), vm.getBlockTimestamp()));
        vm.prank(USER);
        uint256 start = gasleft();
        (bool ok, bytes memory result) = address(vault).call{gas: 28_000_000}(data);
        uint256 used = start - gasleft();
        assertTrue(ok, "64-asset redemption exceeded its gas budget or reverted");
        assertLt(used, 28_000_000);
        assertEq(abi.decode(result, (uint256[])).length, 64);
        emit log_named_uint("64-asset redeem gas", used);
    }

    function test64GasBurningTransfersAndCostlyReadableBalances() public {
        _prepare64();
        for (uint256 i; i < 64; ++i) {
            stocks[i].modes(6, 6);
        }
        _gasCheck();
        for (uint256 i; i < 64; ++i) {
            assertGt(vault.owed(USER, address(stocks[i])), 0);
        }
    }

    function test64UnreadableGasBombs() public {
        _prepare64();
        for (uint256 i; i < 64; ++i) {
            stocks[i].modes(6, 4);
        }
        _gasCheck();
    }

    function test64MixedPausedBlockedUpgradedAndHealthyAssets() public {
        _prepare64();
        for (uint256 i; i < 64; ++i) {
            stocks[i].modes(i % 10, i % 7);
            feeds[i].configure(8, address(0), true);
            if (i % 3 == 0) stocks[i].blockHolder(USER, true);
            vm.prank(GUARDIAN);
            vault.closeAsset(address(stocks[i]));
        }
        vm.prank(GUARDIAN);
        vault.pauseDeposits();
        vm.prank(OWNER);
        vault.lowerNAVCap(0);
        _gasCheck();
    }
}
