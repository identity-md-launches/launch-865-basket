// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BasketTestBase, BaskVault, StockMock, FeedMock, RejectCalls} from "./Base.t.sol";

contract DepositTest is BasketTestBase {
    function testDeploymentAndFirstDeposit() public {
        assertEq(vault.name(), "Basket");
        assertEq(vault.symbol(), "BASK");
        assertEq(vault.decimals(), 18);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.owner(), OWNER);
        assertEq(vault.guardian(), GUARDIAN);
        (uint256 preview, uint256 fee) = vault.previewDeposit(address(stocks[0]), 10e18);
        assertEq(fee, 5e18);
        uint256 shares = _deposit(0, 10e18);
        assertEq(shares, 995e18 - 1e15);
        assertEq(preview, shares);
        assertEq(vault.balanceOf(address(0xdEaD)), 1e15);
        assertEq(vault.totalSupply(), 995e18);
        assertEq(vault.managed(address(stocks[0])), 10e18);
        assertEq(vault.navPerShare(), uint256(1_000e18) * 1e18 / 995e18);
        BaskVault.AssetView[] memory a = vault.allAssets();
        assertEq(a.length, 3);
        assertEq(a[0].answer, 100e8);
        assertEq(a[0].minAnswer, 25e8);
        assertEq(a[0].maxAnswer, 400e8);
        assertFalse(a[0].probation);
        assertFalse(a[0].short);
    }

    function testFeeRecipientIsFinalAndNeverCalled() public {
        address feeRecipient = address(new RejectCalls());
        vm.prank(OWNER);
        vault.setFeeRecipient(feeRecipient);
        _deposit(0, 10e18);
        assertEq(vault.balanceOf(feeRecipient), 5e18);
        assertEq(vault.totalSupply(), 1_000e18);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.setFeeRecipient(OTHER);
        uint256 supply = vault.totalSupply();
        _redeem(100e18);
        assertEq(vault.totalSupply(), supply - 99.5e18);
        assertEq(vault.balanceOf(feeRecipient), 5.5e18);
    }

    function testDonationDoesNotAffectSharesOrNAV() public {
        _deposit(0, 1e18);
        (uint256 expected,) = vault.previewDeposit(address(stocks[0]), 1e18);
        uint256 nav = vault.navPerShare();
        stocks[0].mint(address(vault), 1_000_000e18);
        assertEq(vault.navPerShare(), nav);
        assertEq(_deposit(0, 1e18), expected);
        assertEq(vault.managed(address(stocks[0])), 2e18);
    }

    function testGenesisAndOpeningDelay() public {
        _emptyVault(2);
        _status(BaskVault.Reason.Genesis, address(0), 0);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidInput.selector);
        vault.finalizeGenesis();
        _addGenesis();
        vm.prank(OWNER);
        vault.finalizeGenesis();
        _status(BaskVault.Reason.OpeningDelay, address(0), 0);
        vm.warp(MONDAY + 72 hours - 1);
        _status(BaskVault.Reason.OpeningDelay, address(0), 0);
        vm.warp(MONDAY + 72 hours);
        _refresh();
        _deposit(0, 1e18);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidInput.selector);
        vault.finalizeGenesis();
    }

    function testMarketBoundariesAllDays() public {
        uint256 midnight = MONDAY / 1 days * 1 days;
        for (uint256 day; day < 7; ++day) {
            vm.warp(midnight + day * 1 days + 55799);
            assertFalse(vault.marketOpen());
            vm.warp(midnight + day * 1 days + 55800);
            assertEq(vault.marketOpen(), day < 5);
            vm.warp(midnight + day * 1 days + 70199);
            assertEq(vault.marketOpen(), day < 5);
            vm.warp(midnight + day * 1 days + 70200);
            assertFalse(vault.marketOpen());
        }
        _status(BaskVault.Reason.MarketClosed, address(0), 0);
    }

    function testMarketFreshnessAndPriceBoundaries() public {
        feeds[0].set(100e8, vm.getBlockTimestamp() - 4 hours - 1);
        _status(BaskVault.Reason.MarketStale, address(0), 0);
        feeds[0].set(100e8, vm.getBlockTimestamp() - 4 hours);
        _deposit(0, 1e18);
        feeds[0].set(401e8, vm.getBlockTimestamp());
        _status(BaskVault.Reason.InvalidPrice, address(stocks[0]), 0);
        feeds[0].set(25e8, vm.getBlockTimestamp());
        _deposit(0, 1e18);
        feeds[0].set(400e8, vm.getBlockTimestamp());
        _deposit(0, 1e18);
        feeds[0].set(24e8, vm.getBlockTimestamp());
        _status(BaskVault.Reason.InvalidPrice, address(stocks[0]), 0);
        feeds[0].set(0, vm.getBlockTimestamp());
        _status(BaskVault.Reason.InvalidPrice, address(stocks[0]), 0);
        feeds[0].set(-1, vm.getBlockTimestamp());
        _status(BaskVault.Reason.InvalidPrice, address(stocks[0]), 0);
        feeds[0].set(100e8, vm.getBlockTimestamp() + 1);
        _status(BaskVault.Reason.MarketStale, address(0), 0);
    }

    function testManagedPriceStalenessAndOraclePause() public {
        _emptyVault(4);
        vm.prank(OWNER);
        vault.finalizeGenesis();
        vm.warp(MONDAY + 3 days);
        _refresh();
        _deposit(0, 1e18);
        feeds[0].set(100e8, vm.getBlockTimestamp() - 26 hours);
        _deposit(1, 1e18);
        feeds[0].set(100e8, vm.getBlockTimestamp() - 26 hours - 1);
        _status(BaskVault.Reason.InvalidPrice, address(stocks[0]), 1);
        feeds[0].set(100e8, vm.getBlockTimestamp() + 1);
        _status(BaskVault.Reason.InvalidPrice, address(stocks[0]), 1);
        feeds[0].set(100e8, vm.getBlockTimestamp());
        stocks[0].configure(18, true, false);
        _status(BaskVault.Reason.InvalidPrice, address(stocks[0]), 1);
        stocks[0].configure(18, false, true);
        _status(BaskVault.Reason.InvalidPrice, address(stocks[0]), 1);
        stocks[0].configure(18, false, false);
        feeds[0].configure(8, address(1), true);
        _status(BaskVault.Reason.InvalidPrice, address(stocks[0]), 1);
    }

    function testUnreadableEmptyAssetAlsoBlocksDeposit() public {
        stocks[2].modes(0, 4);
        _status(BaskVault.Reason.Unreadable, address(stocks[2]), 0);
    }

    function testDeadlineReceiverAndMinimumShares() public {
        vm.startPrank(USER);
        vm.expectRevert(BaskVault.DeadlineExpired.selector);
        vault.deposit(address(stocks[0]), 1e18, USER, 0, vm.getBlockTimestamp() - 1);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.deposit(address(stocks[0]), 1e18, address(vault), 0, vm.getBlockTimestamp());
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.deposit(address(stocks[0]), 1e18, address(0), 0, vm.getBlockTimestamp());
        vm.expectRevert(BaskVault.Slippage.selector);
        vault.deposit(address(stocks[0]), 1e18, USER, 100e18, vm.getBlockTimestamp());
        vm.expectRevert(BaskVault.Slippage.selector);
        vault.deposit(address(stocks[0]), 1, USER, 0, vm.getBlockTimestamp());
        vm.stopPrank();
        assertEq(vault.totalSupply(), 0);
    }

    function testExactInRejectsTaxAndLyingTokens() public {
        uint256[5] memory modes = [uint256(2), 4, 5, 7, 8];
        for (uint256 i; i < modes.length; ++i) {
            stocks[0].modes(modes[i], 0);
            vm.expectRevert(abi.encodeWithSelector(BaskVault.TransferFailed.selector, address(stocks[0])));
            _deposit(0, 1e18);
            assertEq(stocks[0].rawBalance(address(vault)), 0);
        }
        stocks[0].modes(3, 0);
        _deposit(0, 1e18);
    }

    function testNAVAndConcentrationCaps() public {
        _deposit(0, 250e18);
        vm.expectRevert(
            abi.encodeWithSelector(BaskVault.DepositUnavailable.selector, BaskVault.Reason.AssetCap, address(stocks[0]))
        );
        _deposit(0, 1e18);
        vm.prank(OWNER);
        vault.lowerNAVCap(25_099e18);
        vm.expectRevert(
            abi.encodeWithSelector(BaskVault.DepositUnavailable.selector, BaskVault.Reason.NAVCap, address(stocks[1]))
        );
        _deposit(1, 1e18);
        vm.prank(OWNER);
        vault.lowerNAVCap(0);
        _redeem(1e18);
    }

    function testGlobalBucketAndLinearDecay() public {
        _emptyVault(5);
        vm.prank(OWNER);
        vault.finalizeGenesis();
        vm.warp(MONDAY + 3 days);
        _refresh();
        for (uint256 i; i < 4; ++i) {
            _deposit(i, 250e18);
        }
        assertEq(vault.bucket(), 100_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                BaskVault.DepositUnavailable.selector, BaskVault.Reason.BucketCap, address(stocks[4])
            )
        );
        _deposit(4, 1e18);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _deposit(4, 1e18);
        assertEq(vault.bucket(), 100_000e18 - uint256(100_000e18) / 24 + 100e18);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        assertEq(vault.decayedBucket(), 0);
    }

    function testFuzzFirstDepositRounding(uint96 input, bool feesSet) public {
        uint256 amount = bound(uint256(input), 1e14, 250e18);
        if (feesSet) {
            vm.prank(OWNER);
            vault.setFeeRecipient(OTHER);
        }
        uint256 gross = amount * 100;
        uint256 fee = (gross + 199) / 200;
        uint256 shares = _deposit(0, amount);
        assertEq(shares, gross - fee - 1e15);
        assertEq(vault.totalSupply(), feesSet ? gross : gross - fee);
        assertEq(vault.balanceOf(OTHER), feesSet ? fee : 0);
    }
}
