// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BasketTestBase, BaskVault, StockMock, FeedMock} from "./Base.t.sol";
import {BasketHandler} from "./handlers/BasketHandler.sol";

abstract contract StatefulAccountingBase is BasketTestBase {
    BasketHandler internal handler;

    function _start(bool feeRecipientSet) internal {
        super.setUp();
        StockMock[3] memory tokens = [stocks[0], stocks[1], stocks[2]];
        FeedMock[3] memory prices = [feeds[0], feeds[1], feeds[2]];
        handler = new BasketHandler(vault, tokens, prices);
        if (feeRecipientSet) handler.setFees();
        for (uint256 i; i < 3; ++i) {
            handler.deposit(i, i, i, 5e18);
        }

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.redeem.selector;
        selectors[2] = handler.claim.selector;
        selectors[3] = handler.transferShares.selector;
        selectors[4] = handler.donate.selector;
        selectors[5] = handler.issuerBurn.selector;
        selectors[6] = handler.changeIssuerState.selector;
        selectors[7] = handler.lossAction.selector;
        selectors[8] = handler.pause.selector;
        selectors[9] = handler.setFees.selector;
        selectors[10] = handler.advanceTime.selector;
        selectors[11] = handler.recoverMarket.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function _assertAccounting() internal view {
        uint256 shares = vault.balanceOf(address(0xdEaD));
        for (uint256 j; j < 4; ++j) {
            shares += vault.balanceOf(handler.actors(j));
        }
        assertEq(shares, vault.totalSupply(), "shares appeared outside tracked holders");
        assertEq(vault.balanceOf(address(0xdEaD)), 1e15, "initial locked shares changed");
        for (uint256 i; i < 3; ++i) {
            address token = address(stocks[i]);
            uint256 debt;
            for (uint256 j; j < 4; ++j) {
                debt += vault.owed(handler.actors(j), token);
            }
            assertEq(debt, vault.totalOwed(token), "aggregate debt differs from user debts");
            assertEq(
                stocks[i].rawBalance(address(vault)) + handler.paid(i) + handler.issuerBurned(i),
                handler.deposited(i) + handler.donated(i),
                "physical Stock Token conservation failed"
            );
            assertEq(
                vault.managed(token) + debt + handler.paid(i) + handler.losses(i),
                handler.deposited(i),
                "managed/deferred/paid/lost accounting does not conserve deposits"
            );
        }
    }

    /// @dev Every actor can exit after each random sequence, even while deposits are paused.
    function afterInvariant() public {
        handler.pause(true, true);
        for (uint256 j; j < 4; ++j) {
            handler.redeem(j, 0, true);
        }
        _assertAccounting();
        handler.recoverMarket();
        for (uint256 i; i < 3; ++i) {
            for (uint256 j; j < 4; ++j) {
                handler.claim(j, i, j);
            }
        }
        _assertAccounting();
    }

    function testHandlerExercisesDeferredPaymentLossAndRecovery() public {
        handler.changeIssuerState(0, 1, false, false);
        handler.redeem(0, 100e18, false);
        assertGt(vault.totalOwed(address(stocks[0])), 0);
        handler.claim(0, 0, 1); // Failure must leave the claim intact.
        handler.recoverMarket();
        handler.claim(0, 0, 1);
        assertGt(handler.successfulClaims(), 0);
        handler.issuerBurn(1, 1e18);
        handler.lossAction(1, false);
        handler.advanceTime(7 days);
        handler.lossAction(1, true);
        assertEq(handler.losses(1), 1e18);
        handler.recoverMarket();
        handler.deposit(2, 1, 2, 1e18);
        assertEq(handler.successfulDeposits(), 4);
        handler.pause(true, true);
        handler.deposit(2, 1, 2, 1e18);
        assertEq(handler.rejectedDeposits(), 1);
        _assertAccounting();
        afterInvariant();
    }
}

contract StatefulInitiallyUnsetFeesTest is StatefulAccountingBase {
    function setUp() public override {
        _start(false);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 128
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_SupplyDebtAndIndependentTokenFlowsAgree() public view {
        _assertAccounting();
    }
}

contract StatefulSetFeesTest is StatefulAccountingBase {
    function setUp() public override {
        _start(true);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 128
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_SupplyDebtAndIndependentTokenFlowsAgree() public view {
        _assertAccounting();
    }
}
