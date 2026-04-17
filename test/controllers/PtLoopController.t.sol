// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {
    PtLoopController,
    PtLoopConfig,
    PtBufferSnapshot,
    PtFundingState,
    PtTradingState
} from "../../src/controllers/cross_venue/PtLoopController.sol";
import {Side, ExecStatus, NormalizedExecutionReceipt, FundingReceipt} from "../../src/controllers/cross_venue/SharedVenueTypes.sol";
import {CrossVenueCommandLib} from "../../src/base/CrossVenueCommandLib.sol";
import {RitualPrecompiles} from "../../src/interfaces/ritual/IRitualPrecompiles.sol";

contract PtLoopControllerTest is Test {
    PtLoopController template;
    PtLoopController controller;

    address owner = address(0xA11CE);
    address manager = address(0xBEEF);
    address baseVault = address(0xBA5E);
    address baseAsset = address(0x1DC);
    address executor = address(0xE2EC);

    bytes32 constant STRATEGY_ID = keccak256("pt-loop-demo");

    function setUp() public {
        template = new PtLoopController();
        controller = PtLoopController(payable(Clones.clone(address(template))));

        PtLoopConfig memory c = PtLoopConfig({
            marketRef: keccak256("pt-eeth-mar26"),
            maxSlippageBps: 30,
            maxLoops: 3,
            loopNotionalUsd: 2_000e6,
            bufferTargetUsd: 10_000e6,
            bufferMinUsd: 1_000e6,
            destinationRef: keccak256("pt-rail"),
            bufferStalenessSeconds: 1 hours,
            envelopeTtlSeconds: 1 hours
        });

        PtLoopController.InitParams memory p = PtLoopController.InitParams({
            owner: owner,
            vaultManager: manager,
            baseVault: baseVault,
            baseAsset: baseAsset,
            strategyId: STRATEGY_ID,
            adapterUrl: "https://adapter.example/api",
            executor: executor,
            cfg: c,
            topUpCommandType: CrossVenueCommandLib.CommandType.TOPUP_HL_BUFFER
        });
        controller.initialize(p);
        vm.etch(RitualPrecompiles.LONG_RUNNING_HTTP, hex"00");
    }

    function _seedBuffer(uint256 amt) internal {
        bytes memory body = abi.encode(PtBufferSnapshot({bufferUsd: amt, timestamp: block.timestamp}));
        string[] memory emptyArr = new string[](0);
        bytes memory envelope = abi.encode(uint16(200), emptyArr, emptyArr, body, "");
        bytes32 expectedJobId = keccak256(abi.encodePacked(STRATEGY_ID, "pt-buffer", block.number));

        vm.prank(owner);
        controller.tick(0);
        assertEq(controller.pendingBufferSyncJobId(), expectedJobId, "buffer sync not submitted");

        vm.prank(RitualPrecompiles.ASYNC_DELIVERY);
        controller.onBufferSyncResult(expectedJobId, envelope);
    }

    function _receipt(ExecStatus status, uint256 filledNotional, bytes32 cycleId)
        internal
        pure
        returns (bytes memory envelope)
    {
        NormalizedExecutionReceipt memory r = NormalizedExecutionReceipt({
            cycleId: cycleId,
            venue: bytes32(0),
            status: status,
            filledNotionalUsd: filledNotional,
            filledBaseQty: 0,
            avgPriceE18: 1e18,
            externalOrderId: bytes32(uint256(1)),
            externalAccountRef: bytes32(0),
            terminal: true,
            rawPayloadHash: keccak256("raw")
        });
        bytes memory body = abi.encode(r);
        string[] memory emptyArr = new string[](0);
        envelope = abi.encode(uint16(200), emptyArr, emptyArr, body, "");
    }

    function testInitDefaults() public view {
        assertEq(uint256(controller.fundingState()), uint256(PtFundingState.STALE));
        assertEq(uint256(controller.tradingState()), uint256(PtTradingState.IDLE));
    }

    function testLowBufferEmitsTopUp() public {
        vm.recordLogs();
        _seedBuffer(100);
        assertEq(uint256(controller.fundingState()), uint256(PtFundingState.TOPUP_PENDING));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig =
            keccak256("CommandReady(bytes32,uint8,address,address,uint256,bytes32,bytes32,uint256,uint256,bytes32)");
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                found = true;
                // Command type is topUpCommandType (TOPUP_HL_BUFFER per setUp).
                assertEq(uint256(logs[i].topics[2]), uint256(CrossVenueCommandLib.CommandType.TOPUP_HL_BUFFER));
            }
        }
        assertTrue(found);
    }

    function testFullLoopCycle() public {
        _seedBuffer(9_000e6);
        assertEq(uint256(controller.fundingState()), uint256(PtFundingState.OK));

        vm.prank(owner);
        controller.requestCycle();
        assertEq(uint256(controller.tradingState()), uint256(PtTradingState.ITER_PENDING));
        assertEq(controller.currentIteration(), 0);
        bytes32 cid = controller.currentCycleId();

        // 3 iterations, each fills 2000.
        for (uint16 iter; iter < 3; iter++) {
            bytes32 job = controller.pendingIterJobId();
            bytes memory rc = _receipt(ExecStatus.Filled, 2_000e6, cid);
            vm.prank(RitualPrecompiles.ASYNC_DELIVERY);
            controller.onIterationResult(job, rc);
        }
        assertEq(uint256(controller.tradingState()), uint256(PtTradingState.VALUATION_PENDING));
        assertEq(controller.currentCycleFilledTotalUsd(), 6_000e6);
    }

    function testFirstIterFailureAborts() public {
        _seedBuffer(9_000e6);
        vm.prank(owner);
        controller.requestCycle();
        bytes32 job = controller.pendingIterJobId();
        bytes32 cid = controller.currentCycleId();
        bytes memory fail = _receipt(ExecStatus.Failed, 0, cid);
        vm.prank(RitualPrecompiles.ASYNC_DELIVERY);
        controller.onIterationResult(job, fail);
        assertEq(uint256(controller.tradingState()), uint256(PtTradingState.ITER_FAILED));
    }

    function testMidLoopFailureMarksRecovery() public {
        _seedBuffer(9_000e6);
        vm.prank(owner);
        controller.requestCycle();
        bytes32 cid = controller.currentCycleId();

        // Iter 0 ok.
        bytes32 job0 = controller.pendingIterJobId();
        bytes memory rc0 = _receipt(ExecStatus.Filled, 2_000e6, cid);
        vm.prank(RitualPrecompiles.ASYNC_DELIVERY);
        controller.onIterationResult(job0, rc0);

        // Iter 1 fails.
        bytes32 job1 = controller.pendingIterJobId();
        bytes memory fail = _receipt(ExecStatus.Failed, 0, cid);
        vm.prank(RitualPrecompiles.ASYNC_DELIVERY);
        controller.onIterationResult(job1, fail);

        assertEq(uint256(controller.tradingState()), uint256(PtTradingState.RECOVERY_REQUIRED));
    }

    function testPauseBlocksTick() public {
        _seedBuffer(9_000e6);
        vm.prank(owner);
        controller.pauseTrading();
        vm.prank(RitualPrecompiles.SCHEDULER);
        controller.tick(0);
        assertEq(uint256(controller.tradingState()), uint256(PtTradingState.PAUSED));
    }

    function testOnlyAsyncDeliveryCanCallback() public {
        vm.expectRevert(PtLoopController.NotAsyncDelivery.selector);
        controller.onIterationResult(bytes32(0), bytes(""));
        vm.expectRevert(PtLoopController.NotAsyncDelivery.selector);
        controller.onBufferSyncResult(bytes32(0), bytes(""));
        vm.expectRevert(PtLoopController.NotAsyncDelivery.selector);
        controller.onValuationSync(bytes(""));
    }

    function testCannotReinitClone() public {
        PtLoopController.InitParams memory p;
        vm.expectRevert(PtLoopController.AlreadyInitialized.selector);
        controller.initialize(p);
    }

    function testInvalidTopUpCommandRejected() public {
        // PAUSE is not a valid top-up command.
        PtLoopController fresh = PtLoopController(payable(Clones.clone(address(template))));
        PtLoopConfig memory c = PtLoopConfig({
            marketRef: bytes32(uint256(1)),
            maxSlippageBps: 30,
            maxLoops: 3,
            loopNotionalUsd: 1,
            bufferTargetUsd: 10,
            bufferMinUsd: 1,
            destinationRef: bytes32(uint256(2)),
            bufferStalenessSeconds: 1 hours,
            envelopeTtlSeconds: 1 hours
        });
        PtLoopController.InitParams memory p = PtLoopController.InitParams({
            owner: owner,
            vaultManager: manager,
            baseVault: baseVault,
            baseAsset: baseAsset,
            strategyId: keccak256("bad"),
            adapterUrl: "x",
            executor: executor,
            cfg: c,
            topUpCommandType: CrossVenueCommandLib.CommandType.PAUSE
        });
        vm.expectRevert(PtLoopController.InvalidConfig.selector);
        fresh.initialize(p);
    }
}
