// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BasketTestBase, BaskVault} from "./Base.t.sol";
import {FullMath} from "../src/FullMath.sol";

contract AccountingTest is BasketTestBase {
    function testShareTransfersAndAllowancesDoNotChangeSupply() public {
        _deposit(0, 10e18);
        uint256 supply = vault.totalSupply();
        vm.prank(USER);
        vault.approve(OTHER, 50e18);
        vm.prank(OTHER);
        vault.transferFrom(USER, OTHER, 25e18);
        assertEq(vault.balanceOf(OTHER), 25e18);
        assertEq(vault.allowance(USER, OTHER), 25e18);
        vm.prank(OTHER);
        vm.expectRevert(BaskVault.InsufficientAllowance.selector);
        vault.transferFrom(USER, OTHER, 26e18);
        vm.prank(USER);
        vault.approve(OTHER, type(uint256).max);
        vm.prank(OTHER);
        vault.transferFrom(USER, OTHER, 1e18);
        assertEq(vault.allowance(USER, OTHER), type(uint256).max);
        vm.prank(OTHER);
        vault.transfer(OTHER, 1e18);
        assertEq(vault.balanceOf(OTHER), 26e18);
        vm.prank(OTHER);
        vault.transfer(USER, 26e18);
        vm.prank(USER);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.transfer(address(0), 1);
        vm.prank(OTHER);
        vm.expectRevert(BaskVault.InsufficientShares.selector);
        vault.transfer(USER, 1);
        assertEq(vault.totalSupply(), supply);
    }

    function testFeeRecipientRedeemsOwnSharesWithoutExtraBurn() public {
        vm.prank(OWNER);
        vault.setFeeRecipient(USER);
        _deposit(0, 10e18);
        uint256 shares = vault.balanceOf(USER);
        uint256 fee = (shares + 199) / 200;
        uint256 supply = vault.totalSupply();
        _redeem(shares);
        assertEq(vault.balanceOf(USER), fee);
        assertEq(vault.totalSupply(), supply - shares + fee);
    }

    function testFuzzMultiUserConservation(uint256 seed) public {
        vm.prank(OWNER);
        vault.setFeeRecipient(OTHER);
        for (uint256 i; i < 18; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 index = seed % 3;
            uint256 action = (seed >> 8) % 5;
            if (action < 2 || vault.balanceOf(USER) < 10e18) {
                stocks[index].modes(0, 0);
                _deposit(index, 1e16 + (seed % 1e18));
            } else if (action == 2) {
                uint256 shares = vault.balanceOf(USER) / 17;
                vm.prank(USER);
                vault.transfer(OTHER, shares);
            } else if (action == 3) {
                stocks[index].modes(1, 0);
                _redeem(vault.balanceOf(USER) / 13);
                stocks[index].modes(0, 0);
            } else {
                vm.prank(USER);
                vault.claim(address(stocks[index]), USER);
                uint256 shares = vault.balanceOf(OTHER) / 7;
                vm.prank(OTHER);
                vault.redeem(shares, new uint256[](0), vm.getBlockTimestamp());
            }
            uint256 owned = vault.balanceOf(USER) + vault.balanceOf(OTHER) + vault.balanceOf(address(0xdEaD));
            assertEq(owned, vault.totalSupply());
            for (uint256 j; j < 3; ++j) {
                address token = address(stocks[j]);
                assertEq(stocks[j].rawBalance(address(vault)), vault.managed(token) + vault.totalOwed(token));
                assertEq(vault.totalOwed(token), vault.owed(USER, token) + vault.owed(OTHER, token));
            }
        }
    }

    function testFullPrecisionMathEdges() public pure {
        uint256 max = type(uint256).max;
        assertEq(FullMath.mulDiv(max, max, max), max);
        assertEq(FullMath.mulDiv(uint256(1) << 200, uint256(1) << 100, uint256(1) << 60), uint256(1) << 240);
        assertEq(FullMath.mulDiv(max, 2, 3), max / 3 * 2);
    }

    function testFuzzFullPrecisionIdentity(uint256 x, uint256 y) public pure {
        if (y == 0) y = 1;
        assertEq(FullMath.mulDiv(x, y, y), x);
    }

    function testFuzzMathMatchesSmallProducts(uint128 x, uint128 y, uint128 d) public pure {
        uint256 denominator = d == 0 ? 1 : d;
        assertEq(FullMath.mulDiv(x, y, denominator), uint256(x) * y / denominator);
    }
}
