// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IVaultV2} from "../../src/interfaces/IVaultV2.sol";
import {UniversalAdapterEscrow} from "../../src/adapters/UniversalAdapterEscrow.sol";
import {VaultV2Factory} from "../../src/VaultV2Factory.sol";
import {IUniversalAdapterEscrow} from "../../src/adapters/interfaces/IUniversalAdapterEscrow.sol";
import {UniversalAdapterEscrowFactory} from "../../src/adapters/UniversalAdapterEscrowFactory.sol";
import {DeltaNeutralController} from "../../src/controllers/DeltaNeutralController.sol";
import {PTLoopController} from "../../src/controllers/PTLoopController.sol";
import {CoreWriter} from "../../src/controllers/venue_specific/hyperliquid/CoreWriter.sol";
import {L1Read} from "../../src/controllers/venue_specific/hyperliquid/L1Read.sol";
import {
    HyperliquidLib,
    HyperliquidOpenHedgeRequest,
    HyperliquidCloseHedgeRequest,
    HyperliquidOrderRequest,
    HyperliquidPositionSnapshot,
    HyperliquidUnwindSizing
} from "../../src/controllers/venue_specific/hyperliquid/HyperliquidLib.sol";
import {
    IPendleRouter,
    IPendleStaticQuoter,
    PendleLib,
    PTLoopSwapExactTokenForPtRequest,
    PTLoopSwapExactPtForTokenRequest,
    PTLoopOpenRequest,
    PTLoopCloseRequest
} from "../../src/controllers/venue_specific/pendle/PendleLib.sol";
import {StrategyVaultFactory} from "../../src/factories/StrategyVaultFactory.sol";
import {AsyncWithdrawalQueue} from "../../src/queues/AsyncWithdrawalQueue.sol";
import {AsyncWithdrawalSettlementComposer} from "../../src/ovault/AsyncWithdrawalSettlementComposer.sol";
import {RemotePpsSnapshotStore} from "../../src/ovault/RemotePpsSnapshotStore.sol";
import {VaultTimeLockWrapper} from "../../src/VaultTimeLockWrapper.sol";
import {
    ChainManifest,
    DeltaNeutralAutomationConfig,
    DeltaNeutralKellyConfig,
    DeltaNeutralRebalanceDirection,
    DeltaNeutralKellyRebalanceQuote,
    DeltaNeutralDeploymentParams,
    DeltaNeutralUnwindPlan,
    Deployment,
    PTLoopAutomationConfig,
    PTLoopDeploymentParams,
    PTLoopUnloopQuote,
    PTLoopUnwindPlan,
    SpotSideMode,
    VenueConfig,
    WithdrawalRequest,
    WithdrawalRequestStatus
} from "../../src/strategies/StrategyTypes.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockTarget} from "../mocks/MockTarget.sol";
import {MockValuer} from "../mocks/MockValuer.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

contract StrategyControllersTest is Test {
    bytes32 internal constant HYPERLIQUID_VENUE_ID = keccak256("HYPERLIQUID");
    bytes32 internal constant PENDLE_VENUE_ID = keccak256("PENDLE");
    address internal constant PENDLE_MARKET = address(0xBEEF);
    address internal constant ORACLE_PX_PRECOMPILE = 0x0000000000000000000000000000000000000807;
    address internal constant MARK_PX_PRECOMPILE = 0x0000000000000000000000000000000000000806;
    address internal constant L1_BLOCK_PRECOMPILE = 0x0000000000000000000000000000000000000809;
    address internal constant POSITION2_PRECOMPILE = 0x0000000000000000000000000000000000000813;
    address internal constant SPOT_BALANCE_PRECOMPILE = 0x0000000000000000000000000000000000000801;
    address internal constant WITHDRAWABLE_PRECOMPILE = 0x0000000000000000000000000000000000000803;
    address internal constant ACCOUNT_MARGIN_PRECOMPILE = 0x000000000000000000000000000000000000080F;
    address internal constant SPOT_PX_PRECOMPILE = 0x0000000000000000000000000000000000000808;
    address internal constant PERP_ASSET_INFO_PRECOMPILE = 0x000000000000000000000000000000000000080a;

    event RawAction(address indexed user, bytes data);

    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");

    MockERC20 internal asset;
    MockERC20 internal ptAsset;
    MockValuer internal valuer;
    MockTarget internal protocol;
    MockPendleRouter internal pendleRouter;
    MockAssetOFTView internal assetOFT;
    CoreWriter internal coreWriter;
    L1Read internal l1Read;
    VaultV2Factory internal vaultFactory;
    UniversalAdapterEscrowFactory internal adapterFactory;
    StrategyVaultFactory internal childFactory;

    function setUp() public {
        asset = new MockERC20("USD Coin", "USDC", 6);
        ptAsset = new MockERC20("Pendle PT", "PT", 6);
        valuer = new MockValuer();
        protocol = new MockTarget(address(asset));
        pendleRouter = new MockPendleRouter(address(asset), address(ptAsset));
        assetOFT = new MockAssetOFTView(address(asset), address(this));
        coreWriter = new CoreWriter();
        l1Read = new L1Read();
        vaultFactory = new VaultV2Factory();
        adapterFactory = new UniversalAdapterEscrowFactory();
        childFactory = new StrategyVaultFactory(address(vaultFactory), address(adapterFactory));
    }

    function testDeltaNeutralControllerDefersDepositAllocationUntilPermissionlessSync() public {
        Deployment memory deployment = _deployDeltaNeutral(false);
        DeltaNeutralController controller = DeltaNeutralController(deployment.controller);
        IVaultV2 vault = IVaultV2(deployment.vault);
        _mockCustomHyperliquidReads(deployment.sleeve, 100_000_000, 100_000_000, 0, 0, 0, 1_000_000_000, 100_000_000);

        asset.mint(user, 1_000e6);
        vm.recordLogs();
        vm.startPrank(user);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, user);
        vm.stopPrank();

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes[] memory rawActions = new bytes[](2);
        uint256 found;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].emitter == address(coreWriter)) {
                rawActions[found++] = abi.decode(entries[i].data, (bytes));
                if (found == 2) break;
            }
        }
        assertEq(found, 0);
        assertEq(asset.balanceOf(deployment.sleeve), 1_000e6);

        DeltaNeutralUnwindPlan memory plan = controller.planWithdrawal(200e6, 500e6, 800e6, 800e6, false);
        assertEq(plan.shortfallAssets, 300e6);
        assertEq(plan.spotReductionAssets, 150e6);
        assertEq(plan.hedgeReductionAssets, 150e6);
        assertEq(plan.releaseableAssets, 300e6);
        assertFalse(plan.requiresLayerZero);
        assertTrue(controller.withinDeltaBand(800e6, 790e6));
        assertFalse(controller.withinDeltaBand(800e6, 500e6));

        _mockCustomHyperliquidReads(
            deployment.sleeve, 100_000_000, 100_000_000, -5_000_000, 500_000_000, 0, 100_000_000, 90_000_000
        );
        vm.recordLogs();
        vm.prank(owner);
        assertTrue(controller.sync());
        entries = vm.getRecordedLogs();
        found = 0;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].emitter == address(coreWriter)) {
                found++;
            }
        }
        assertEq(found, 2);
    }

    function testDeltaNeutralControllerQuotesExactUnwindSizesOnchain() public {
        Deployment memory deployment = _deployDeltaNeutral(false);
        DeltaNeutralController controller = DeltaNeutralController(deployment.controller);

        _mockHyperliquidReads(deployment.sleeve);

        HyperliquidUnwindSizing memory sizing = controller.quoteUnwindExecution(200e6, 500e6, 800e6, 800e6, false);

        assertEq(sizing.shortfallAssets, 300e6);
        assertEq(sizing.spotReductionAssets, 150e6);
        assertEq(sizing.hedgeReductionAssets, 150e6);
        assertEq(sizing.spotPx, 100_000_000);
        assertEq(sizing.markPx, 109_500_000);
        assertEq(sizing.spotSizeToSell, 1_500_000);
        assertEq(sizing.perpSizeToClose, 1_369_864);
        assertFalse(sizing.requiresLayerZero);
        assertFalse(sizing.requiresEmergencyExit);
    }

    function testDeltaNeutralVaultCanPriceOnchainWithoutValuer() public {
        Deployment memory deployment = _deployDeltaNeutralWithValuer(false, address(0));
        UniversalAdapterEscrow sleeve = UniversalAdapterEscrow(payable(deployment.sleeve));
        address sink = makeAddr("sink");

        asset.mint(user, 1_000e6);
        vm.startPrank(user);
        asset.approve(address(IVaultV2(deployment.vault)), type(uint256).max);
        IVaultV2(deployment.vault).deposit(1_000e6, user);
        vm.stopPrank();

        vm.prank(deployment.sleeve);
        asset.transfer(sink, 1_000e6);

        _mockCustomHyperliquidReads(
            deployment.sleeve, 100_000_000, 100_000_000, -5_000_000, 5_000_000, 500_000_000, 500_000_000, 100_000_000
        );

        assertEq(sleeve.realAssets(), 1_000e6);
    }

    function testDeltaNeutralValuationUsesMarginAccountEquityNotWithdrawableOnly() public {
        Deployment memory deployment = _deployDeltaNeutralWithValuer(false, address(0));
        UniversalAdapterEscrow sleeve = UniversalAdapterEscrow(payable(deployment.sleeve));
        address sink = makeAddr("sink");

        asset.mint(user, 1_000e6);
        vm.startPrank(user);
        asset.approve(address(IVaultV2(deployment.vault)), type(uint256).max);
        IVaultV2(deployment.vault).deposit(1_000e6, user);
        vm.stopPrank();

        vm.prank(deployment.sleeve);
        asset.transfer(sink, 1_000e6);

        _mockCustomHyperliquidReads(
            deployment.sleeve, 100_000_000, 100_000_000, -5_000_000, 5_000_000, 300_000_000, 500_000_000, 100_000_000
        );

        assertEq(sleeve.realAssets(), 1_000e6);
    }

    function testDeltaNeutralSyncFunctionsAreManagerOnly() public {
        Deployment memory deployment = _deployDeltaNeutral(false);
        DeltaNeutralController controller = DeltaNeutralController(deployment.controller);

        vm.prank(user);
        vm.expectRevert();
        controller.sync();

        vm.prank(user);
        vm.expectRevert();
        controller.syncPPS();
    }

    function testDeltaNeutralControllerKellyOptimizerMatchesKeeperDefaults() public {
        Deployment memory deployment = _deployDeltaNeutral(false);
        DeltaNeutralController controller = DeltaNeutralController(deployment.controller);

        DeltaNeutralKellyRebalanceQuote memory quote = controller.quoteKellyRebalance(68_000e6, 32_000e6);
        assertEq(quote.currentAlphaBps, 6_800);
        assertEq(quote.targetAlphaBps, 6_800);
        assertEq(quote.amountToMoveAssets, 0);
        assertApproxEqAbs(quote.liquidationThresholdWad, 470_588_235_294_117_647, 2);
        assertApproxEqAbs(quote.liquidationProbWad, 1_731_753_840_328, 10_000);
        assertFalse(quote.shouldRebalance);
    }

    function testDeltaNeutralControllerQuotesKellyRebalanceGasEfficiently() public {
        Deployment memory deployment = _deployDeltaNeutral(false);
        DeltaNeutralController controller = DeltaNeutralController(deployment.controller);

        DeltaNeutralKellyRebalanceQuote memory quote = controller.quoteKellyRebalance(80_000e6, 20_000e6);
        assertEq(quote.currentAlphaBps, 8_000);
        assertEq(quote.targetAlphaBps, 7_100);
        assertEq(quote.amountToMoveAssets, 9_000e6);
        assertEq(quote.targetSpotAssets, 71_000e6);
        assertEq(quote.targetHedgeAssets, 29_000e6);
        assertEq(uint8(quote.direction), uint8(DeltaNeutralRebalanceDirection.SpotToPerp));
        assertTrue(quote.passesAsymmetricThreshold);
        assertTrue(quote.shouldRebalance);

        quote = controller.quoteKellyRebalance(50_000e6, 50_000e6);
        assertEq(quote.currentAlphaBps, 5_000);
        assertFalse(quote.passesAsymmetricThreshold);
        assertFalse(quote.shouldRebalance);
    }

    function testTimelockTransferDoesNotBypassLock() public {
        Deployment memory deployment = _deployDeltaNeutral(true);
        VaultTimeLockWrapper wrapper = VaultTimeLockWrapper(deployment.wrapper);
        address receiver = makeAddr("receiver");
        _mockCustomHyperliquidReads(deployment.sleeve, 100_000_000, 100_000_000, 0, 0, 0, 1_000_000_000, 100_000_000);

        asset.mint(user, 1_000e6);
        vm.startPrank(user);
        asset.approve(address(wrapper), type(uint256).max);
        wrapper.deposit(1_000e6);
        wrapper.transfer(receiver, wrapper.balanceOf(user));
        vm.stopPrank();

        vm.prank(receiver);
        vm.expectRevert();
        wrapper.withdraw(100e6, receiver, receiver);

        vm.warp(block.timestamp + wrapper.LOCK_PERIOD());

        vm.prank(receiver);
        wrapper.withdraw(100e6, receiver, receiver);
        assertEq(asset.balanceOf(receiver), 100e6);
    }

    function testTimelockWrapperCanUnwrapToSharesForAsyncQueueFlows() public {
        Deployment memory deployment = _deployDeltaNeutral(true);
        VaultTimeLockWrapper wrapper = VaultTimeLockWrapper(deployment.wrapper);
        IVaultV2 vault = IVaultV2(deployment.vault);
        AsyncWithdrawalQueue queue = AsyncWithdrawalQueue(childFactory.withdrawalQueueOf(deployment.vault));

        _mockCustomHyperliquidReads(deployment.sleeve, 100_000_000, 100_000_000, 0, 0, 0, 1_000_000_000, 100_000_000);

        asset.mint(user, 1_000e6);
        vm.startPrank(user);
        asset.approve(address(wrapper), type(uint256).max);
        wrapper.deposit(1_000e6);
        vm.warp(block.timestamp + wrapper.LOCK_PERIOD());

        uint256 unlockedShares = wrapper.balanceOf(user);
        wrapper.unwrap(unlockedShares, user, user);
        vault.approve(address(queue), unlockedShares);
        uint256 requestId = queue.requestRedeem(unlockedShares / 2, user);
        vm.stopPrank();

        WithdrawalRequest memory request = queue.getRequest(requestId);
        assertEq(vault.balanceOf(user), unlockedShares / 2);
        assertEq(request.owner, user);
        assertEq(request.sharesEscrowed, unlockedShares / 2);
    }

    function testDeltaNeutralSameChainWithdrawUsesAsyncQueue() public {
        Deployment memory deployment = _deployDeltaNeutral(false);
        IVaultV2 vault = IVaultV2(deployment.vault);
        AsyncWithdrawalQueue queue = AsyncWithdrawalQueue(childFactory.withdrawalQueueOf(deployment.vault));
        address sink = makeAddr("sink");

        _mockCustomHyperliquidReads(deployment.sleeve, 100_000_000, 100_000_000, 0, 0, 0, 1_000_000_000, 100_000_000);

        asset.mint(user, 1_000e6);
        vm.startPrank(user);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, user);
        vm.stopPrank();

        vm.prank(deployment.sleeve);
        asset.transfer(sink, 1_000e6);

        _mockCustomHyperliquidReads(
            deployment.sleeve, 100_000_000, 100_000_000, -5_000_000, 500_000_000, 350_000_000, 500_000_000, 90_000_000
        );

        vm.startPrank(user);
        uint256 sharesNeeded = vault.previewWithdraw(700e6);
        vault.approve(address(queue), sharesNeeded);
        vm.recordLogs();
        uint256 requestId = queue.requestWithdraw(700e6, user);
        vm.stopPrank();

        WithdrawalRequest memory request = queue.getRequest(requestId);
        assertEq(uint8(request.status), uint8(WithdrawalRequestStatus.Pending));
        assertEq(request.reservedLocalAssets, 0);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].emitter == address(coreWriter)) found++;
        }
        assertEq(found, 2);

        vm.expectRevert(AsyncWithdrawalQueue.RequestNotClaimable.selector);
        queue.claim(requestId);

        asset.mint(deployment.sleeve, 700e6);
        queue.refreshRequest(requestId);
        queue.claim(requestId);

        assertEq(asset.balanceOf(user), 700e6);
        assertEq(vault.balanceOf(address(queue)), 0);
    }

    function testDeltaNeutralSyncPreservesClaimableWithdrawalReserve() public {
        Deployment memory deployment = _deployDeltaNeutral(false);
        DeltaNeutralController controller = DeltaNeutralController(deployment.controller);
        IVaultV2 vault = IVaultV2(deployment.vault);
        AsyncWithdrawalQueue queue = AsyncWithdrawalQueue(childFactory.withdrawalQueueOf(deployment.vault));

        _mockCustomHyperliquidReads(deployment.sleeve, 100_000_000, 100_000_000, 0, 0, 0, 1_000_000_000, 100_000_000);

        asset.mint(user, 1_000e6);
        vm.startPrank(user);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, user);
        uint256 sharesNeeded = vault.previewWithdraw(700e6);
        vault.approve(address(queue), sharesNeeded);
        uint256 requestId = queue.requestWithdraw(700e6, user);
        vm.stopPrank();

        WithdrawalRequest memory request = queue.getRequest(requestId);
        assertEq(uint8(request.status), uint8(WithdrawalRequestStatus.Claimable));
        assertEq(request.reservedLocalAssets, 700e6);
        assertEq(queue.totalProtectedAssets(), 700e6);

        _mockCustomHyperliquidReads(
            deployment.sleeve, 100_000_000, 100_000_000, -5_000_000, 500_000_000, 0, 100_000_000, 90_000_000
        );

        vm.prank(owner);
        assertTrue(controller.sync());

        queue.claim(requestId);

        assertEq(queue.totalProtectedAssets(), 0);
        assertEq(asset.balanceOf(user), 700e6);
    }

    function testPTLoopAutomatesLoopingAndRejectsDirectUserExitUnwinds() public {
        Deployment memory deployment = _deployPTLoop(false);
        PTLoopController controller = PTLoopController(deployment.controller);
        IVaultV2 vault = IVaultV2(deployment.vault);

        asset.mint(user, 1_000e6);
        vm.startPrank(user);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, user);
        vm.stopPrank();

        assertEq(vault.liquidityAdapter(), deployment.sleeve);
        assertEq(asset.balanceOf(deployment.sleeve), 1_000e6);
        assertEq(ptAsset.balanceOf(deployment.sleeve), 0);

        vm.prank(owner);
        assertTrue(controller.sync());
        assertEq(asset.balanceOf(deployment.sleeve), 150e6);
        assertEq(ptAsset.balanceOf(deployment.sleeve), 807_500_000);

        vm.prank(user);
        vm.expectRevert();
        vault.withdraw(700e6, user, user);

        assertEq(asset.balanceOf(user), 0);
        assertEq(ptAsset.balanceOf(deployment.sleeve), 807_500_000);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(deployment.sleeve), 150e6);
    }

    function testPTLoopVaultCanPriceOnchainWithoutValuer() public {
        Deployment memory deployment = _deployPTLoopWithValuer(false, address(0));
        PTLoopController controller = PTLoopController(deployment.controller);
        UniversalAdapterEscrow sleeve = UniversalAdapterEscrow(payable(deployment.sleeve));
        IVaultV2 vault = IVaultV2(deployment.vault);

        asset.mint(user, 1_000e6);
        vm.startPrank(user);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, user);
        vm.stopPrank();

        assertEq(sleeve.realAssets(), 1_000e6);

        vm.prank(owner);
        assertTrue(controller.sync());
        assertEq(sleeve.realAssets(), 957_500_000);
    }

    function testPTLoopValuationUsesStaticQuoterOutput() public {
        Deployment memory deployment = _deployPTLoopWithValuer(false, address(0));
        PTLoopController controller = PTLoopController(deployment.controller);
        UniversalAdapterEscrow sleeve = UniversalAdapterEscrow(payable(deployment.sleeve));
        IVaultV2 vault = IVaultV2(deployment.vault);

        asset.mint(user, 1_000e6);
        vm.startPrank(user);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, user);
        vm.stopPrank();

        vm.prank(owner);
        assertTrue(controller.sync());

        pendleRouter.setStaticRedeemBps(9_000);
        assertEq(sleeve.realAssets(), 876_750_000);
    }

    function testSyncPPSRefreshesCachedValuationFromOnchainState() public {
        Deployment memory deployment = _deployPTLoopWithValuer(false, address(0));
        PTLoopController controller = PTLoopController(deployment.controller);
        UniversalAdapterEscrow sleeve = UniversalAdapterEscrow(payable(deployment.sleeve));
        IVaultV2 vault = IVaultV2(deployment.vault);

        asset.mint(user, 1_000e6);
        vm.startPrank(user);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, user);
        vm.stopPrank();

        vm.prank(owner);
        uint256 cachedAssets = controller.syncPPS();

        assertEq(cachedAssets, 1_000e6);
        (uint256 value,, bool isStale) = sleeve.getCachedValuation();
        assertEq(value, 1_000e6);
        assertFalse(isStale);
    }

    function testCrossChainWithdrawalQueueEscrowsSharesAndClaimsAfterSettlement() public {
        Deployment memory deployment = _deployPTLoop(true);
        PTLoopController controller = PTLoopController(deployment.controller);
        IVaultV2 vault = IVaultV2(deployment.vault);
        AsyncWithdrawalQueue queue = AsyncWithdrawalQueue(childFactory.withdrawalQueueOf(deployment.vault));
        AsyncWithdrawalSettlementComposer composer =
            AsyncWithdrawalSettlementComposer(childFactory.withdrawalSettlementComposerOf(deployment.vault));
        UniversalAdapterEscrow sleeve = UniversalAdapterEscrow(payable(deployment.sleeve));

        asset.mint(user, 1_000e6);
        vm.startPrank(user);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, user);
        vm.stopPrank();

        vm.prank(owner);
        assertTrue(controller.sync());

        uint256 externalBefore = sleeve.externalDeposits(deployment.strategyId);

        vm.startPrank(user);
        uint256 sharesNeeded = vault.previewWithdraw(700e6);
        vault.approve(address(queue), sharesNeeded);
        uint256 requestId = queue.requestWithdraw(700e6, user);
        vm.stopPrank();

        WithdrawalRequest memory request = queue.getRequest(requestId);
        assertEq(uint8(request.status), uint8(WithdrawalRequestStatus.Pending));
        assertEq(request.reservedLocalAssets, 150e6);
        assertEq(vault.balanceOf(address(queue)), sharesNeeded);

        vm.expectRevert(AsyncWithdrawalQueue.RequestNotClaimable.selector);
        queue.claim(requestId);

        asset.mint(address(composer), 700e6);
        bytes memory message = OFTComposeMsgCodec.encode(
            1, 30_102, 700e6, abi.encodePacked(bytes32(uint256(uint160(address(this)))), abi.encode(requestId))
        );

        composer.lzCompose(address(assetOFT), bytes32("remote-fill"), message, address(0), "");

        request = queue.getRequest(requestId);
        assertEq(uint8(request.status), uint8(WithdrawalRequestStatus.Claimable));
        assertEq(request.assetsFunded, 700e6);
        assertEq(asset.balanceOf(deployment.sleeve), 850e6);
        assertLt(sleeve.externalDeposits(deployment.strategyId), externalBefore);

        queue.claim(requestId);

        assertEq(vault.balanceOf(address(queue)), 0);
        assertEq(asset.balanceOf(user), 700e6);
    }

    function testPTLoopSyncPreservesProtectedSettlementLiquidity() public {
        Deployment memory deployment = _deployPTLoop(true);
        PTLoopController controller = PTLoopController(deployment.controller);
        IVaultV2 vault = IVaultV2(deployment.vault);
        AsyncWithdrawalQueue queue = AsyncWithdrawalQueue(childFactory.withdrawalQueueOf(deployment.vault));
        AsyncWithdrawalSettlementComposer composer =
            AsyncWithdrawalSettlementComposer(childFactory.withdrawalSettlementComposerOf(deployment.vault));

        asset.mint(user, 1_000e6);
        vm.startPrank(user);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, user);
        vm.stopPrank();

        vm.prank(owner);
        assertTrue(controller.sync());

        vm.startPrank(user);
        uint256 sharesNeeded = vault.previewWithdraw(700e6);
        vault.approve(address(queue), sharesNeeded);
        uint256 requestId = queue.requestWithdraw(700e6, user);
        vm.stopPrank();

        assertEq(queue.totalProtectedAssets(), 150e6);

        asset.mint(address(composer), 700e6);
        bytes memory message = OFTComposeMsgCodec.encode(
            1, 30_102, 700e6, abi.encodePacked(bytes32(uint256(uint160(address(this)))), abi.encode(requestId))
        );
        composer.lzCompose(address(assetOFT), bytes32("remote-fill-2"), message, address(0), "");

        assertEq(queue.totalProtectedAssets(), 850e6);

        vm.prank(owner);
        assertFalse(controller.sync());

        queue.claim(requestId);

        assertEq(queue.totalProtectedAssets(), 0);
        assertEq(asset.balanceOf(user), 700e6);
    }

    function testCrossChainPpsSnapshotPropagatesToHomeSyncPps() public {
        Deployment memory deployment = _deployPTLoopWithValuer(true, address(0));
        PTLoopController controller = PTLoopController(deployment.controller);
        UniversalAdapterEscrow sleeve = UniversalAdapterEscrow(payable(deployment.sleeve));
        IVaultV2 vault = IVaultV2(deployment.vault);
        RemotePpsSnapshotStore store = RemotePpsSnapshotStore(childFactory.remotePpsSnapshotStoreOf(deployment.vault));
        address remoteReporter = makeAddr("remoteReporter");

        asset.mint(user, 1_000e6);
        vm.startPrank(user);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, user);
        vm.stopPrank();

        vm.prank(owner);
        assertTrue(controller.sync());

        vm.prank(owner);
        store.setPeer(30_102, bytes32(uint256(uint160(remoteReporter))));

        store.lzReceive(
            Origin({srcEid: 30_102, sender: bytes32(uint256(uint160(remoteReporter))), nonce: 1}),
            bytes32("pps"),
            abi.encode(uint256(300e6), uint64(block.timestamp)),
            address(0),
            ""
        );

        vm.prank(owner);
        uint256 cachedAssets = controller.syncPPS();

        assertEq(cachedAssets, 1_257_500_000);
        assertEq(sleeve.realAssets(), 1_257_500_000);
    }

    function testCrossChainSettlementComposerStoresRecoverablePendingSettlement() public {
        Deployment memory deployment = _deployPTLoop(true);
        AsyncWithdrawalSettlementComposer composer =
            AsyncWithdrawalSettlementComposer(childFactory.withdrawalSettlementComposerOf(deployment.vault));

        asset.mint(address(composer), 700e6);
        bytes32 guid = bytes32("bad-request");
        bytes memory message = OFTComposeMsgCodec.encode(
            1, 30_102, 700e6, abi.encodePacked(bytes32(uint256(uint160(address(this)))), abi.encode(999))
        );

        composer.lzCompose(address(assetOFT), guid, message, address(0), "");

        (uint256 requestId, uint256 amountReceived) = composer.pendingSettlements(guid);
        assertEq(requestId, 999);
        assertEq(amountReceived, 700e6);

        vm.prank(owner);
        composer.recoverPendingSettlement(guid, user);

        (, amountReceived) = composer.pendingSettlements(guid);
        assertEq(amountReceived, 0);
        assertEq(asset.balanceOf(user), 700e6);
    }

    function testCrossChainSettlementComposerStoresUndecodablePayloadForRecovery() public {
        Deployment memory deployment = _deployPTLoop(true);
        AsyncWithdrawalSettlementComposer composer =
            AsyncWithdrawalSettlementComposer(childFactory.withdrawalSettlementComposerOf(deployment.vault));

        asset.mint(address(composer), 700e6);
        bytes32 guid = bytes32("decode-fail");
        bytes memory message =
            OFTComposeMsgCodec.encode(1, 30_102, 700e6, abi.encodePacked(bytes32(uint256(uint160(address(this)))), hex"1234"));

        composer.lzCompose(address(assetOFT), guid, message, address(0), "");

        (uint256 requestId, uint256 amountReceived) = composer.pendingSettlements(guid);
        assertEq(requestId, 0);
        assertEq(amountReceived, 700e6);

        vm.prank(owner);
        composer.recoverPendingSettlement(guid, user);

        (, amountReceived) = composer.pendingSettlements(guid);
        assertEq(amountReceived, 0);
        assertEq(asset.balanceOf(user), 700e6);
    }

    function testAsyncWithdrawalQueueRechecksFifoOnClaim() public {
        Deployment memory deployment = _deployPTLoop(true);
        PTLoopController controller = PTLoopController(deployment.controller);
        IVaultV2 vault = IVaultV2(deployment.vault);
        AsyncWithdrawalQueue queue = AsyncWithdrawalQueue(childFactory.withdrawalQueueOf(deployment.vault));

        asset.mint(user, 1_000e6);
        vm.startPrank(user);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, user);
        vm.stopPrank();

        vm.prank(owner);
        assertTrue(controller.sync());

        vm.startPrank(user);
        uint256 firstShares = vault.previewWithdraw(700e6);
        vault.approve(address(queue), type(uint256).max);
        uint256 firstRequestId = queue.requestWithdraw(700e6, user);
        vm.stopPrank();

        asset.mint(deployment.sleeve, 100e6);

        vm.startPrank(user);
        uint256 secondShares = vault.previewWithdraw(100e6);
        uint256 secondRequestId = queue.requestWithdraw(100e6, user);
        vm.stopPrank();

        WithdrawalRequest memory firstRequest = queue.getRequest(firstRequestId);
        WithdrawalRequest memory secondRequest = queue.getRequest(secondRequestId);
        assertEq(firstRequest.sharesEscrowed, firstShares);
        assertEq(secondRequest.sharesEscrowed, secondShares);
        assertEq(uint8(secondRequest.status), uint8(WithdrawalRequestStatus.Claimable));

        vm.expectRevert(AsyncWithdrawalQueue.RequestNotClaimable.selector);
        queue.claim(secondRequestId);
    }

    function testRemotePpsSnapshotStoreRejectsOutOfOrderSnapshotsAndClearsOnPeerChange() public {
        Deployment memory deployment = _deployPTLoopWithValuer(true, address(0));
        RemotePpsSnapshotStore store = RemotePpsSnapshotStore(childFactory.remotePpsSnapshotStoreOf(deployment.vault));
        address remoteReporter = makeAddr("remoteReporter");
        address newRemoteReporter = makeAddr("newRemoteReporter");
        uint64 firstTimestamp = uint64(block.timestamp);

        vm.prank(owner);
        store.setPeer(30_102, bytes32(uint256(uint160(remoteReporter))));

        store.lzReceive(
            Origin({srcEid: 30_102, sender: bytes32(uint256(uint160(remoteReporter))), nonce: 1}),
            bytes32("pps-1"),
            abi.encode(uint256(300e6), firstTimestamp),
            address(0),
            ""
        );

        vm.expectRevert(
            abi.encodeWithSelector(RemotePpsSnapshotStore.StaleSnapshotTimestamp.selector, 30_102, firstTimestamp - 1, firstTimestamp)
        );
        store.lzReceive(
            Origin({srcEid: 30_102, sender: bytes32(uint256(uint160(remoteReporter))), nonce: 2}),
            bytes32("pps-2"),
            abi.encode(uint256(200e6), firstTimestamp - 1),
            address(0),
            ""
        );

        vm.prank(owner);
        store.setPeer(30_102, bytes32(uint256(uint160(newRemoteReporter))));

        (uint256 assetsStored, uint64 snapshotTimestamp, uint64 receivedAt, uint64 nonce) = store.snapshots(30_102);
        assertEq(assetsStored, 0);
        assertEq(snapshotTimestamp, 0);
        assertEq(receivedAt, 0);
        assertEq(nonce, 0);
    }

    function testPTLoopControllerSupportsCrossChainPlanning() public {
        Deployment memory deployment = _deployPTLoop(true);
        PTLoopController controller = PTLoopController(deployment.controller);

        PTLoopUnwindPlan memory plan = controller.planWithdrawal(100e6, 600e6, 200e6, 200e6);
        assertEq(plan.shortfallAssets, 500e6);
        assertEq(plan.localReductionAssets, 200e6);
        assertEq(plan.remoteReductionAssets, 200e6);
        assertEq(plan.releaseableAssets, 400e6);
        assertEq(plan.unmetAssets, 100e6);
        assertTrue(plan.requiresLayerZero);
        assertTrue(plan.requiresEmergencyExit);

        assertTrue(controller.withinUnwindSlippage(1_000e6, 950e6));
        assertFalse(controller.withinUnwindSlippage(1_000e6, 900e6));
        assertEq(controller.remoteChainCount(), 1);
    }

    function _deployDeltaNeutral(bool enableTimelock) internal returns (Deployment memory) {
        return _deployDeltaNeutralWithValuer(enableTimelock, address(valuer));
    }

    function _deployDeltaNeutralWithValuer(bool enableTimelock, address valuerAddress)
        internal
        returns (Deployment memory)
    {
        DeltaNeutralDeploymentParams memory params = DeltaNeutralDeploymentParams({
            owner: owner,
            vaultManager: owner,
            curator: owner,
            enableTimelock: enableTimelock,
            enableOmnichainVault: false,
            asset: address(asset),
            valuer: valuerAddress,
            name: "Delta Neutral Vault",
            symbol: "ldn",
            strategyIdData: bytes("hyperliquid-dn"),
            spotSideMode: SpotSideMode.Hold,
            targetReserveBps: 2_000,
            maxDeltaBps: 250,
            kellyConfig: _defaultKellyConfig(),
            automationConfig: _defaultDeltaAutomationConfig(),
            absoluteCap: 1_000_000e6,
            relativeCap: 1e18,
            salt: bytes32("delta"),
            useOffchainValuer: false,
            venueConfig: VenueConfig({
                venueId: HYPERLIQUID_VENUE_ID,
                venue: address(coreWriter),
                helper: address(l1Read),
                usesLayerZero: false
            }),
            chainManifests: _homeManifest()
        });

        return childFactory.createDeltaNeutralVault(params);
    }

    function _defaultKellyConfig() internal pure returns (DeltaNeutralKellyConfig memory) {
        return DeltaNeutralKellyConfig({
            spotYieldWad: 20_400_000_000_000_000,
            marginYieldWad: 43_300_000_000_000_000,
            baseFundingRateWad: 105_000_000_000_000_000,
            ethVolatilityWad: 600_000_000_000_000_000,
            liquidationLossWad: 950_000_000_000_000_000,
            rebalanceThresholdWad: 50_000_000_000_000_000,
            minBenefitWad: 100_000_000_000_000,
            shortTakerFeeWad: 350_000_000_000_000,
            entrySlippageWad: 1_000_000_000_000_000,
            exitSlippageWad: 1_000_000_000_000_000,
            shortSlippageWad: 500_000_000_000_000,
            bridgeSlippageWad: 1_000_000_000_000_000,
            sizeImpactThresholdAssets: 50_000e6,
            sizeImpactMultiplierWad: 1_500_000_000_000_000_000,
            bridgeFeeAssets: 5e6,
            gasSpotActionAssets: 2e6,
            gasShortActionAssets: 500_000,
            timeHorizonDays: 7,
            fundingDivisor: 2,
            asymmetricRebalanceThresholdBps: 7_500
        });
    }

    function _defaultDeltaAutomationConfig() internal pure returns (DeltaNeutralAutomationConfig memory) {
        return DeltaNeutralAutomationConfig({
            spotAssetIndex: 1,
            perpAssetIndex: 7,
            spotPriceIndex: 1,
            perpDexIndex: 3,
            spotToken: 100,
            spotTokenDecimals: 6,
            encodedTif: 2,
            hyperCoreVault: address(0),
            maxOrderSlippageBps: 500,
            maxOracleDivergenceBps: 1_000,
            maxMarginUsageBps: 8_000
        });
    }

    function _defaultPTAutomationConfig() internal pure returns (PTLoopAutomationConfig memory) {
        return PTLoopAutomationConfig({maxEntrySlippageBps: 600});
    }

    function _deployPTLoop(bool usesLayerZero) internal returns (Deployment memory) {
        return _deployPTLoopWithValuer(usesLayerZero, address(valuer));
    }

    function _deployPTLoopWithValuer(bool usesLayerZero, address valuerAddress) internal returns (Deployment memory) {
        PTLoopDeploymentParams memory params = PTLoopDeploymentParams({
            owner: owner,
            vaultManager: owner,
            curator: owner,
            enableTimelock: false,
            enableOmnichainVault: false,
            asset: address(asset),
            market: PENDLE_MARKET,
            ptToken: address(ptAsset),
            valuer: valuerAddress,
            name: "PT Loop Vault",
            symbol: "lpt",
            strategyIdData: bytes("pendle-loop"),
            targetReserveBps: 1_500,
            maxUnwindSlippageBps: 600,
            automationConfig: _defaultPTAutomationConfig(),
            absoluteCap: 1_000_000e6,
            relativeCap: 1e18,
            salt: bytes32("pt-loop"),
            useOffchainValuer: false,
            venueConfig: VenueConfig({
                venueId: PENDLE_VENUE_ID,
                venue: address(pendleRouter),
                helper: address(pendleRouter),
                usesLayerZero: usesLayerZero
            }),
            chainManifests: usesLayerZero ? _homeAndRemoteManifest() : _homeManifest()
        });

        return childFactory.createPTLoopVault(params);
    }

    function _homeManifest() internal view returns (ChainManifest[] memory manifests) {
        manifests = new ChainManifest[](1);
        manifests[0] = ChainManifest({
            chainId: block.chainid,
            lzEid: 30_184,
            sleeve: address(0),
            assetOFT: address(assetOFT),
            shareOFT: address(0),
            isHomeChain: true
        });
    }

    function _homeAndRemoteManifest() internal view returns (ChainManifest[] memory manifests) {
        manifests = new ChainManifest[](2);
        manifests[0] = ChainManifest({
            chainId: block.chainid,
            lzEid: 30_184,
            sleeve: address(0),
            assetOFT: address(assetOFT),
            shareOFT: address(0),
            isHomeChain: true
        });
        manifests[1] = ChainManifest({
            chainId: 56,
            lzEid: 30_102,
            sleeve: address(0xBEEF),
            assetOFT: address(0xCAFE),
            shareOFT: address(0),
            isHomeChain: false
        });
    }

    function _venueConfig(bytes32 venueId, address venue, bool usesLayerZero)
        internal
        pure
        returns (VenueConfig memory)
    {
        return VenueConfig({venueId: venueId, venue: venue, helper: address(0), usesLayerZero: usesLayerZero});
    }

    function _mockHyperliquidReads(address account) internal {
        _mockCustomHyperliquidReads(
            account, 110_000_000, 109_500_000, -25_000_000, 500_000_000, 200_000_000, 300_000_000, 125_000_000
        );
    }

    function _mockCustomHyperliquidReads(
        address account,
        uint64 oraclePx,
        uint64 markPx,
        int64 shortSize,
        uint64 spotTotal,
        uint64 withdrawable,
        int64 accountValue,
        uint64 marginUsed
    ) internal {
        vm.mockCall(ORACLE_PX_PRECOMPILE, abi.encode(uint32(7)), abi.encode(oraclePx));
        vm.mockCall(MARK_PX_PRECOMPILE, abi.encode(uint32(7)), abi.encode(markPx));
        vm.mockCall(SPOT_PX_PRECOMPILE, abi.encode(uint32(1)), abi.encode(uint64(100_000_000)));
        vm.mockCall(L1_BLOCK_PRECOMPILE, abi.encode(), abi.encode(uint64(12_345)));
        vm.mockCall(
            PERP_ASSET_INFO_PRECOMPILE,
            abi.encode(uint32(7)),
            abi.encode(
                L1Read.PerpAssetInfo({
                    coin: "BTC",
                    marginTableId: 1,
                    szDecimals: 6,
                    maxLeverage: 10,
                    onlyIsolated: false
                })
            )
        );
        vm.mockCall(
            POSITION2_PRECOMPILE,
            abi.encode(account, uint32(7)),
            abi.encode(
                L1Read.Position({
                    szi: shortSize,
                    entryNtl: 250_000_000,
                    isolatedRawUsd: 0,
                    leverage: 3,
                    isIsolated: false
                })
            )
        );
        vm.mockCall(
            SPOT_BALANCE_PRECOMPILE,
            abi.encode(account, uint64(100)),
            abi.encode(L1Read.SpotBalance({total: spotTotal, hold: 0, entryNtl: spotTotal}))
        );
        vm.mockCall(
            WITHDRAWABLE_PRECOMPILE, abi.encode(account), abi.encode(L1Read.Withdrawable({withdrawable: withdrawable}))
        );
        vm.mockCall(
            ACCOUNT_MARGIN_PRECOMPILE,
            abi.encode(uint32(3), account),
            abi.encode(
                L1Read.AccountMarginSummary({
                    accountValue: accountValue,
                    marginUsed: marginUsed,
                    ntlPos: uint64(shortSize < 0 ? uint64(-shortSize) * markPx / 1e6 : 0),
                    rawUsd: accountValue - int64(marginUsed)
                })
            )
        );
    }

    function _cloid(bytes32 strategyId, uint128 salt) internal pure returns (uint128) {
        return uint128(uint256(keccak256(abi.encodePacked(strategyId, salt))));
    }
}

contract MockPendleRouter is IPendleRouter, IPendleStaticQuoter {
    MockERC20 public immutable asset;
    MockERC20 public immutable pt;
    uint256 public staticRedeemBps = 10_000;

    constructor(address asset_, address pt_) {
        asset = MockERC20(asset_);
        pt = MockERC20(pt_);
    }

    function setStaticRedeemBps(uint256 newStaticRedeemBps) external {
        staticRedeemBps = newStaticRedeemBps;
    }

    function swapExactTokenForPt(
        address receiver,
        address,
        uint256 minPtOut,
        ApproxParams calldata,
        TokenInput calldata input,
        LimitOrderData calldata
    ) external returns (uint256 netPtOut, uint256 netSyFee, uint256 netSyInterm) {
        asset.transferFrom(msg.sender, address(this), input.netTokenIn);

        netPtOut = input.netTokenIn * 95 / 100;
        require(netPtOut >= minPtOut, "insufficient pt out");

        pt.mint(receiver, netPtOut);
        netSyFee = 0;
        netSyInterm = 0;
    }

    function swapExactPtForToken(
        address receiver,
        address,
        uint256 exactPtIn,
        TokenOutput calldata output,
        LimitOrderData calldata
    ) external returns (uint256 netTokenOut, uint256 netSyFee, uint256 netSyInterm) {
        pt.transferFrom(msg.sender, address(this), exactPtIn);
        pt.burn(address(this), exactPtIn);

        netTokenOut = exactPtIn;
        require(netTokenOut >= output.minTokenOut, "insufficient token out");

        asset.mint(receiver, netTokenOut);
        netSyFee = 0;
        netSyInterm = 0;
    }

    function getPtToAssetRate(address) external pure returns (uint256) {
        return 1e18;
    }

    function swapExactPtForTokenStatic(address, uint256 exactPtIn, address)
        external
        view
        returns (
            uint256 netTokenOut,
            uint256 netSyToRedeem,
            uint256 netSyFee,
            uint256 priceImpact,
            uint256 exchangeRateAfter
        )
    {
        netTokenOut = exactPtIn * staticRedeemBps / 10_000;
        netSyToRedeem = 0;
        netSyFee = 0;
        priceImpact = 0;
        exchangeRateAfter = 1e18;
    }
}

contract MockAssetOFTView {
    address internal immutable _token;
    address internal immutable _endpoint;

    constructor(address token_, address endpoint_) {
        _token = token_;
        _endpoint = endpoint_;
    }

    function token() external view returns (address) {
        return _token;
    }

    function endpoint() external view returns (address) {
        return _endpoint;
    }
}
