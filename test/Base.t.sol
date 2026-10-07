// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaskVault} from "../src/BaskVault.sol";
import {StockMock, FeedMock, StockFactoryMock, RejectCalls} from "./mocks/Mocks.sol";

abstract contract BasketTestBase is Test {
    address internal constant OWNER = 0x30B57ECf51D19ABcED7F6f70974e6fBb6f3b9Da3;
    address internal constant GUARDIAN = 0x5ed39AF86f2C00ad99913B5d727bD68f2A904B68;
    address internal constant USER = address(0xBEEF);
    address internal constant OTHER = address(0xCAFE);
    // Monday, 2026-01-05 16:00 UTC.
    uint256 internal constant MONDAY = 1_767_628_800;
    BaskVault internal vault;
    StockFactoryMock internal factory;
    StockMock[] internal stocks;
    FeedMock[] internal feeds;

    function setUp() public virtual {
        vm.chainId(4663);
        vm.warp(MONDAY - 4 days);
        vault = new BaskVault(OWNER, GUARDIAN);
        StockFactoryMock implementation = new StockFactoryMock();
        vm.etch(vault.STOCK_FACTORY(), address(implementation).code);
        factory = StockFactoryMock(vault.STOCK_FACTORY());
        for (uint256 i; i < 3; ++i) {
            _addGenesis();
        }
        vm.prank(OWNER);
        vault.finalizeGenesis();
        vm.warp(MONDAY);
        _refresh();
    }

    function _create() internal returns (StockMock stock, FeedMock feed) {
        stock = new StockMock(bytes32(stocks.length + 1));
        feed = new FeedMock();
        factory.set(stock.uid(), address(stock));
        stocks.push(stock);
        feeds.push(feed);
        stock.mint(USER, 1_000_000e18);
        vm.prank(USER);
        stock.approve(address(vault), type(uint256).max);
    }

    function _addGenesis() internal {
        (StockMock stock, FeedMock feed) = _create();
        vm.prank(OWNER);
        vault.proposeAsset(address(stock), address(feed));
    }

    function _refresh() internal {
        for (uint256 i; i < feeds.length; ++i) {
            feeds[i].set(100e8, vm.getBlockTimestamp());
        }
    }

    function _deposit(uint256 i, uint256 amount) internal returns (uint256) {
        vm.prank(USER);
        return vault.deposit(address(stocks[i]), amount, USER, 0, vm.getBlockTimestamp());
    }

    function _redeem(uint256 shares) internal returns (uint256[] memory) {
        vm.prank(USER);
        return vault.redeem(shares, new uint256[](0), vm.getBlockTimestamp());
    }

    function _status(BaskVault.Reason reason, address fault, uint256 tokenIndex) internal {
        (BaskVault.Reason got, address asset) = vault.depositStatus(address(stocks[tokenIndex]));
        assertEq(uint256(got), uint256(reason));
        assertEq(asset, fault);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.DepositUnavailable.selector, reason, fault));
        _deposit(tokenIndex, 1e18);
    }

    function _emptyVault(uint256 count) internal {
        vault = new BaskVault(OWNER, GUARDIAN);
        delete stocks;
        delete feeds;
        for (uint256 i; i < count; ++i) {
            _addGenesis();
        }
    }
}
