// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BasketTestBase, BaskVault, StockMock, FeedMock} from "./Base.t.sol";

contract LocalDeploymentProbe {
    function deploy(address owner, address guardian) external returns (BaskVault) {
        return new BaskVault(owner, guardian);
    }
}

contract GovernanceTest is BasketTestBase {
    function testConstructorAndEmptyDeployment() public {
        LocalDeploymentProbe probe = new LocalDeploymentProbe();
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        probe.deploy(address(0), GUARDIAN);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        probe.deploy(OWNER, address(0));
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        probe.deploy(OWNER, OWNER);
        vm.etch(vault.STOCK_FACTORY(), hex"fe");
        BaskVault v = probe.deploy(OWNER, GUARDIAN);
        assertEq(v.assetCount(), 0);
        assertEq(v.totalSupply(), 0);
        assertEq(v.feeRecipient(), address(0));
        assertEq(v.NAV_CAP(), 1_000_000e18);
        assertLe(address(v).code.length, 24_000);
    }

    function testRuntimeMatchesProtectedOpcodeAndSizeChecks() public view {
        bytes memory code = address(vault).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_000);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }

    function testTwoStepOwnershipAndNoRenounce() public {
        vm.prank(USER);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.transferOwnership(USER);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.transferOwnership(address(0));
        vm.prank(OWNER);
        vault.transferOwnership(OTHER);
        assertEq(vault.owner(), OWNER);
        vm.prank(USER);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.acceptOwnership();
        vm.prank(OTHER);
        vault.acceptOwnership();
        assertEq(vault.owner(), OTHER);
        assertEq(vault.pendingOwner(), address(0));
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.pauseDeposits();
    }

    function testRolesCannotTakeAssetsOrMintOrBlockExits() public {
        _deposit(0, 10e18);
        address token = address(stocks[0]);
        vm.startPrank(GUARDIAN);
        vault.pauseDeposits();
        vault.closeAsset(token);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.unpauseDeposits();
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.setFeeRecipient(GUARDIAN);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.lowerNAVCap(0);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.proposeGuardian(USER);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.proposeFeed(token, address(feeds[0]));
        vm.stopPrank();
        vm.startPrank(OWNER);
        vault.lowerNAVCap(0);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.payLeg(token, OWNER, 1e18);
        (bool mintOK,) = address(vault).call(abi.encodeWithSignature("mint(address,uint256)", OWNER, 1e18));
        assertFalse(mintOK);
        (bool rescueOK,) = address(vault).call(abi.encodeWithSignature("rescue(address,uint256)", token, 1e18));
        assertFalse(rescueOK);
        vm.stopPrank();
        _status(BaskVault.Reason.Paused, address(0), 0);
        feeds[0].configure(8, address(0), true);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        _redeem(vault.balanceOf(USER));
        assertGt(stocks[0].rawBalance(USER), 1_000_000e18 - 10e18);
    }

    function testPauseAndCloseStatus() public {
        vm.prank(USER);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.pauseDeposits();
        vm.prank(GUARDIAN);
        vault.pauseDeposits();
        _status(BaskVault.Reason.Paused, address(0), 0);
        vm.prank(OWNER);
        vault.unpauseDeposits();
        vm.prank(GUARDIAN);
        vault.closeAsset(address(stocks[0]));
        _status(BaskVault.Reason.Closed, address(stocks[0]), 0);
        (BaskVault.Reason r, address fault) = vault.depositStatus(OTHER);
        assertEq(uint256(r), uint256(BaskVault.Reason.NotListed));
        assertEq(fault, OTHER);
    }

    function testListingChecksAndAtomicBatch() public {
        _emptyVault(0);
        (StockMock a, FeedMock f) = _create();
        address[] memory tokens = new address[](2);
        address[] memory fs = new address[](2);
        tokens[0] = address(a);
        tokens[1] = address(a);
        fs[0] = address(f);
        fs[1] = address(f);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidAsset.selector, address(a)));
        vault.proposeAssets(tokens, fs);
        assertEq(vault.assetCount(), 0);
        a.configure(6, false, false);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidAsset.selector, address(a)));
        vault.proposeAsset(address(a), address(f));
        a.configure(18, false, false);
        factory.set(a.uid(), OTHER);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidAsset.selector, address(a)));
        vault.proposeAsset(address(a), address(f));
        factory.set(a.uid(), address(a));
        f.configure(18, address(1), false);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidFeed.selector, address(f)));
        vault.proposeAsset(address(a), address(f));
        f.configure(8, address(0), false);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidFeed.selector, address(f)));
        vault.proposeAsset(address(a), address(f));
        f.configure(8, address(1), false);
        f.set(0, vm.getBlockTimestamp());
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidFeed.selector, address(f)));
        vault.proposeAsset(address(a), address(f));
        f.set(100e8, vm.getBlockTimestamp());
        (StockMock b, FeedMock g) = _create();
        tokens[1] = address(b);
        fs[1] = address(g);
        vm.prank(OWNER);
        uint256[] memory ids = vault.proposeAssets(tokens, fs);
        assertEq(ids[0], 0);
        assertEq(ids[1], 0);
        assertEq(vault.assetCount(), 2);
        (StockMock c,) = _create();
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidFeed.selector, address(f)));
        vault.proposeAsset(address(c), address(f));
    }

    function testListingRechecksAtExecutionAndProbationCap() public {
        (StockMock a, FeedMock f) = _create();
        vm.prank(OWNER);
        uint256 id = vault.proposeAsset(address(a), address(f));
        assertEq(vault.assetCount(), 3);
        vm.expectRevert(BaskVault.ProposalNotReady.selector);
        vault.executeProposal(id);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        factory.set(a.uid(), OTHER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidAsset.selector, address(a)));
        vault.executeProposal(id);
        factory.set(a.uid(), address(a));
        f.configure(8, address(0), false);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidFeed.selector, address(f)));
        vault.executeProposal(id);
        f.configure(8, address(1), false);
        f.set(120e8, vm.getBlockTimestamp());
        vm.prank(USER);
        vault.executeProposal(id);
        BaskVault.AssetView[] memory all = vault.allAssets();
        assertTrue(all[3].probation);
        assertEq(all[3].minAnswer, 30e8);
        assertEq(all[3].maxAnswer, 480e8);
        _refresh();
        _deposit(3, 50e18);
        vm.expectRevert(
            abi.encodeWithSelector(BaskVault.DepositUnavailable.selector, BaskVault.Reason.AssetCap, address(a))
        );
        _deposit(3, 1e18);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        _refresh();
        _deposit(3, 1e18);
        all = vault.allAssets();
        assertFalse(all[3].probation);
        vm.expectRevert(BaskVault.ProposalUnavailable.selector);
        vault.executeProposal(id);
    }

    function testFeedChecksTwiceAndSharedChangeCooldown() public {
        FeedMock replacement = new FeedMock();
        replacement.set(401e8, vm.getBlockTimestamp());
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidFeed.selector, address(replacement)));
        vault.proposeFeed(address(stocks[0]), address(replacement));
        replacement.set(100e8, vm.getBlockTimestamp());
        vm.prank(OWNER);
        uint256 feedId = vault.proposeFeed(address(stocks[0]), address(replacement));
        (StockMock stock, FeedMock feed) = _create();
        vm.prank(OWNER);
        uint256 listId = vault.proposeAsset(address(stock), address(feed));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        replacement.set(401e8, vm.getBlockTimestamp());
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidFeed.selector, address(replacement)));
        vault.executeProposal(feedId);
        replacement.set(100e8, vm.getBlockTimestamp());
        vault.executeProposal(feedId);
        assertEq(vault.feedAsset(address(feeds[0])), address(0));
        assertEq(vault.feedAsset(address(replacement)), address(stocks[0]));
        vm.expectRevert(BaskVault.ChangeCooldown.selector);
        vault.executeProposal(listId);
        vm.warp(vm.getBlockTimestamp() + 24 hours - 1);
        vm.expectRevert(BaskVault.ChangeCooldown.selector);
        vault.executeProposal(listId);
        vm.warp(vm.getBlockTimestamp() + 1);
        vault.executeProposal(listId);
    }

    function testBandUsesExecutionAnswerAndStrictFreshness() public {
        vm.prank(OWNER);
        uint256 id = vault.proposeBand(address(stocks[0]));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        feeds[0].set(500e8, vm.getBlockTimestamp() - 26 hours);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidFeed.selector, address(feeds[0])));
        vault.executeProposal(id);
        feeds[0].set(500e8, vm.getBlockTimestamp() - 26 hours + 1);
        vault.executeProposal(id);
        BaskVault.AssetView[] memory all = vault.allAssets();
        assertEq(all[0].minAnswer, 125e8);
        assertEq(all[0].maxAnswer, 2000e8);
    }

    function testReopenCancelledByLaterCloseIncludingSameTimestamp() public {
        address token = address(stocks[0]);
        vm.prank(OWNER);
        vault.closeAsset(token);
        vm.prank(OWNER);
        uint256 id = vault.proposeReopen(token);
        vm.prank(GUARDIAN);
        vault.closeAsset(token);
        (uint256[] memory pending,) = vault.pendingProposals();
        assertEq(pending.length, 0);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.expectRevert(BaskVault.ProposalUnavailable.selector);
        vault.executeProposal(id);
        vm.prank(OWNER);
        id = vault.proposeReopen(token);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vault.executeProposal(id);
        BaskVault.AssetView[] memory all = vault.allAssets();
        assertTrue(all[0].open);
    }

    function testCancellationGuardianReplacementAndExpiry() public {
        vm.prank(OWNER);
        uint256 id = vault.proposeGuardian(OTHER);
        vm.prank(GUARDIAN);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.cancelProposal(id);
        vm.prank(USER);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.cancelProposal(id);
        vm.warp(vm.getBlockTimestamp() + 7 days - 1);
        vm.expectRevert(BaskVault.ProposalNotReady.selector);
        vault.executeProposal(id);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(USER);
        vault.executeProposal(id);
        assertEq(vault.guardian(), OTHER);
        vm.prank(OWNER);
        id = vault.proposeNAVCap(2_000_000e18);
        vm.prank(OTHER);
        vault.cancelProposal(id);
        vm.expectRevert(BaskVault.ProposalUnavailable.selector);
        vault.executeProposal(id);
        vm.prank(OWNER);
        id = vault.proposeNAVCap(2_000_000e18);
        vm.warp(vm.getBlockTimestamp() + 14 days);
        vm.expectRevert(BaskVault.ProposalUnavailable.selector);
        vault.executeProposal(id);
        (uint256[] memory pending,) = vault.pendingProposals();
        assertEq(pending.length, 0);
        vm.prank(OWNER);
        id = vault.proposeGuardian(USER);
        vm.prank(OWNER);
        vault.cancelProposal(id);
    }

    function testNAVCapMaximumAndDelayedRaise() public {
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidInput.selector);
        vault.proposeNAVCap(10_000_000_000e18 + 1);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidInput.selector);
        vault.lowerNAVCap(2_000_000e18);
        vm.prank(OWNER);
        uint256 id = vault.proposeNAVCap(10_000_000_000e18);
        assertEq(vault.NAV_CAP(), 1_000_000e18);
        (uint256[] memory ids, BaskVault.Proposal[] memory entries) = vault.pendingProposals();
        assertEq(ids[0], id);
        assertEq(entries[0].value, 10_000_000_000e18);
        vm.warp(vm.getBlockTimestamp() + 14 days - 1);
        vault.executeProposal(id);
        assertEq(vault.NAV_CAP(), 10_000_000_000e18);
    }

    function testGuardianCannotBecomeOwnerThroughPendingHandover() public {
        vm.prank(OWNER);
        vault.transferOwnership(OTHER);
        vm.prank(OWNER);
        uint256 id = vault.proposeGuardian(OTHER);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vault.executeProposal(id);
        vm.prank(OTHER);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.acceptOwnership();
    }

    function testAssetLimit64() public {
        _emptyVault(64);
        assertEq(vault.assetCount(), 64);
        (StockMock stock, FeedMock feed) = _create();
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidAsset.selector, address(stock)));
        vault.proposeAsset(address(stock), address(feed));
    }
}
