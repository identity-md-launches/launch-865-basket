// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BasketTestBase, BaskVault} from "./Base.t.sol";

contract LossesTest is BasketTestBase {
    function testLossDelayNoAutomaticReductionAndMinCurrentShortfall() public {
        _deposit(0, 10e18);
        address token = address(stocks[0]);
        stocks[0].burn(address(vault), 4e18);
        assertEq(vault.managed(token), 10e18);
        BaskVault.AssetView[] memory all = vault.allAssets();
        assertTrue(all[0].short);
        _status(BaskVault.Reason.Short, token, 1);
        vm.prank(OTHER);
        vault.flagDeficit(token);
        (uint256 amount, uint256 since) = vault.deficits(token);
        assertEq(amount, 4e18);
        assertEq(since, vm.getBlockTimestamp());
        vm.expectRevert(BaskVault.InvalidInput.selector);
        vault.flagDeficit(token);
        vm.warp(vm.getBlockTimestamp() + 7 days - 1);
        vm.expectRevert(BaskVault.LossNotReady.selector);
        vault.recognizeLoss(token);
        stocks[0].mint(address(vault), 1e18);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(OTHER);
        vault.recognizeLoss(token);
        assertEq(vault.managed(token), 7e18);
        (amount, since) = vault.deficits(token);
        assertEq(amount, 0);
        assertEq(since, 0);
        _refresh();
        _deposit(1, 1e18);
    }

    function testLargerFlagResetsClockAndUnrecordedLossRemains() public {
        _deposit(0, 10e18);
        address token = address(stocks[0]);
        stocks[0].burn(address(vault), 1e18);
        vault.flagDeficit(token);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        stocks[0].burn(address(vault), 1e18);
        vault.flagDeficit(token);
        (, uint256 since) = vault.deficits(token);
        assertEq(since, vm.getBlockTimestamp());
        stocks[0].burn(address(vault), 1e18);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        vm.expectRevert(BaskVault.LossNotReady.selector);
        vault.recognizeLoss(token);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vault.recognizeLoss(token);
        assertEq(vault.managed(token), 8e18);
        vault.flagDeficit(token);
        (uint256 deficit,) = vault.deficits(token);
        assertEq(deficit, 1e18);
    }

    function testSuccessfulDepositClearsEveryRecoveredRecord() public {
        for (uint256 i; i < 3; ++i) {
            _deposit(i, 1e18);
            stocks[i].burn(address(vault), 1e17);
            vault.flagDeficit(address(stocks[i]));
            stocks[i].mint(address(vault), 1e17);
        }
        // Re-flag all three simultaneously, then restore collateral without a deposit.
        for (uint256 i; i < 3; ++i) {
            (uint256 existing,) = vault.deficits(address(stocks[i]));
            if (existing != 0) continue;
            stocks[i].burn(address(vault), 1e17);
            vault.flagDeficit(address(stocks[i]));
            stocks[i].mint(address(vault), 1e17);
        }
        _deposit(0, 1e18);
        for (uint256 i; i < 3; ++i) {
            (uint256 amount, uint256 since) = vault.deficits(address(stocks[i]));
            assertEq(amount, 0);
            assertEq(since, 0);
        }
    }

    function testTotalLossZeroNAVBlocksDepositButNotRedeem() public {
        _deposit(0, 1e18);
        stocks[0].burn(address(vault), 1e18);
        vault.flagDeficit(address(stocks[0]));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vault.recognizeLoss(address(stocks[0]));
        _refresh();
        _status(BaskVault.Reason.ZeroNAV, address(0), 1);
        uint256[] memory result = _redeem(vault.balanceOf(USER));
        assertEq(result[0], 0);
    }

    function testUnderfundedOwedBlocksDepositIntoToken() public {
        _deposit(0, 1e18);
        stocks[0].modes(1, 0);
        _redeem(50e18);
        stocks[0].modes(0, 0);
        stocks[0].burn(address(vault), 1e18);
        _status(BaskVault.Reason.OwedUnderfunded, address(stocks[0]), 0);
        _status(BaskVault.Reason.Short, address(stocks[0]), 1);
    }

    function testUnreadableBalanceCannotRecognizeLoss() public {
        _deposit(0, 1e18);
        stocks[0].burn(address(vault), 1e17);
        vault.flagDeficit(address(stocks[0]));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        stocks[0].modes(0, 1);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.TransferFailed.selector, address(stocks[0])));
        vault.recognizeLoss(address(stocks[0]));
        assertEq(vault.managed(address(stocks[0])), 1e18);
        uint256[] memory result = _redeem(1e18);
        assertGt(result[0], 0);
    }
}
