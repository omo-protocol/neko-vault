// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MultiLegController} from "../../src/controllers/cross_venue/MultiLegController.sol";
import {
    LegConfig,
    LegBufferSnapshot,
    OffchainKellyWeights,
    MultiLegFundingState,
    MultiLegTradingState,
    MAX_LEGS
} from "../../src/controllers/cross_venue/MultiLegTypes.sol";
import {CrossVenueCommandLib as CL} from "../../src/base/CrossVenueCommandLib.sol";
import {Side, MarginMode, ExecStatus, NormalizedExecutionReceipt, FundingReceipt} from "../../src/controllers/cross_venue/SharedVenueTypes.sol";
import {CrossVenueCommandLib} from "../../src/base/CrossVenueCommandLib.sol";
import {RitualPrecompiles} from "../../src/interfaces/ritual/IRitualPrecompiles.sol";

contract MultiLegControllerTest is Test {
    MultiLegController template;
    MultiLegController controller;

    address owner = address(0xA11CE);
    address manager = address(0xBEEF);
    address baseVault = address(0xBA5E);
    address baseAsset = address(0x1DC);
    address executor = address(0xE2EC);
    uint256 kellyPk = 0xABCDEF;
    address kellySigner;

    bytes32 constant STRATEGY_ID = keccak256("multi-leg-demo");

    function setUp() public {
        kellySigner = vm.addr(kellyPk);
        template = new MultiLegController();
        controller = MultiLegController(payable(Clones.clone(address(template))));

        LegConfig[] memory ls = new LegConfig[](3);
        ls[0] = LegConfig({
            venue: keccak256("POLYMARKET"),
            marketRef: keccak256("pm:market"),
            weightBps: int16(4000),
            maxAbsWeightBps: 0,
            sizeFromPrevFill: false,
            maxSlippageBps: 50,
            bufferTargetUsd: 10_000e6,
            bufferMinUsd: 1_000e6,
            destinationRef: keccak256("pm-rail"),
            marginMode: MarginMode.Isolated
        });
        ls[1] = LegConfig({
            venue: keccak256("HYPERLIQUID-PERP"),
            marketRef: keccak256("hl:ETH"),
            weightBps: int16(-10_000),
            maxAbsWeightBps: 0,
            sizeFromPrevFill: true,
            maxSlippageBps: 30,
            bufferTargetUsd: 10_000e6,
            bufferMinUsd: 1_000e6,
            destinationRef: keccak256("hl-rail"),
            marginMode: MarginMode.Isolated
        });
        ls[2] = LegConfig({
            venue: keccak256("HYPERLIQUID-PERP"),
            marketRef: keccak256("hl:BTC"),
            weightBps: int16(6000),
            maxAbsWeightBps: 0,
            sizeFromPrevFill: false,
            maxSlippageBps: 30,
            bufferTargetUsd: 10_000e6,
            bufferMinUsd: 1_000e6,
            destinationRef: keccak256("hl-rail-2"),
            marginMode: MarginMode.Isolated
        });

        MultiLegController.InitParams memory p = MultiLegController.InitParams({
            owner: owner,
            vaultManager: manager,
            baseVault: baseVault,
            baseAsset: baseAsset,
            strategyId: STRATEGY_ID,
            adapterUrl: "https://adapter.example/api",
            executor: executor,
            legs: ls,
            bufferStalenessSeconds: 1 hours,
            minCycleNotionalUsd: 100e6,
            maxCycleNotionalUsd: 10_000e6,
            envelopeTtlSeconds: 1 hours,
            kellySigner: kellySigner,
            reserveDestinationRef: keccak256("reserve")
        });
        controller.initialize(p);

        vm.etch(RitualPrecompiles.LONG_RUNNING_HTTP, hex"00");
    }

    function _seedAllBuffers(uint256[] memory amounts) internal {
        LegBufferSnapshot[] memory snaps = new LegBufferSnapshot[](amounts.length);
        for (uint256 i; i < amounts.length; i++) {
            snaps[i] = LegBufferSnapshot({bufferUsd: amounts[i], timestamp: block.timestamp});
        }
        bytes memory body = abi.encode(snaps);
        string[] memory emptyArr = new string[](0);
        bytes memory envelope = abi.encode(uint16(200), emptyArr, emptyArr, body, "");
        bytes32 expectedJobId = keccak256(abi.encodePacked(STRATEGY_ID, "ml-buffer", block.number));

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

    function testLegCountAndDefaultState() public view {
        assertEq(controller.legCount(), 3);
        assertEq(uint256(controller.fundingState()), uint256(MultiLegFundingState.STALE));
        assertEq(uint256(controller.tradingState()), uint256(MultiLegTradingState.IDLE));
    }

    function testLowFirstLegBufferEmitsPmTopUp() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 100; // below min
        amounts[1] = 5_000e6;
        amounts[2] = 5_000e6;
        vm.recordLogs();
        _seedAllBuffers(amounts);
        assertEq(uint256(controller.fundingState()), uint256(MultiLegFundingState.TOPUP_PENDING));
        assertEq(controller.pendingTopUpLegIndex(), 0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig =
            keccak256("CommandReady(bytes32,uint8,address,address,uint256,bytes32,bytes32,uint256,uint256,bytes32)");
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                found = true;
                assertEq(uint256(logs[i].topics[2]), uint256(CrossVenueCommandLib.CommandType.TOPUP_PM_BUFFER));
            }
        }
        assertTrue(found, "CommandReady missing");
    }

    function testThirdLegLowEmitsHlTopUp() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 5_000e6;
        amounts[1] = 5_000e6;
        amounts[2] = 100; // leg 2 (HL) is low
        vm.recordLogs();
        _seedAllBuffers(amounts);
        assertEq(uint256(controller.fundingState()), uint256(MultiLegFundingState.TOPUP_PENDING));
        assertEq(controller.pendingTopUpLegIndex(), 2);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig =
            keccak256("CommandReady(bytes32,uint8,address,address,uint256,bytes32,bytes32,uint256,uint256,bytes32)");
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                found = true;
                assertEq(uint256(logs[i].topics[2]), uint256(CrossVenueCommandLib.CommandType.TOPUP_HL_BUFFER));
            }
        }
        assertTrue(found);
    }

    function testSequentialLegExecution() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 5_000e6;
        amounts[1] = 5_000e6;
        amounts[2] = 5_000e6;
        _seedAllBuffers(amounts);
        assertEq(uint256(controller.fundingState()), uint256(MultiLegFundingState.OK));

        vm.prank(owner);
        controller.requestCycle();
        assertEq(uint256(controller.tradingState()), uint256(MultiLegTradingState.LEG_PENDING));
        assertEq(controller.currentLegIndex(), 0);

        bytes32 cid = controller.currentCycleId();

        // Leg 0 fills 2000.
        bytes32 job0 = controller.pendingLegJobId();
        bytes memory rc0 = _receipt(ExecStatus.Filled, 2_000e6, cid);
        vm.prank(RitualPrecompiles.ASYNC_DELIVERY);
        controller.onLegResult(job0, rc0);
        assertEq(controller.currentLegIndex(), 1);

        // Leg 1 (sizeFromPrevFill=true, weight 100%) → notional = 2000 × 10000/10000 = 2000.
        bytes32 job1 = controller.pendingLegJobId();
        bytes memory rc1 = _receipt(ExecStatus.Filled, 2_000e6, cid);
        vm.prank(RitualPrecompiles.ASYNC_DELIVERY);
        controller.onLegResult(job1, rc1);
        assertEq(controller.currentLegIndex(), 2);

        // Leg 2.
        bytes32 job2 = controller.pendingLegJobId();
        bytes memory rc2 = _receipt(ExecStatus.Filled, 3_000e6, cid);
        vm.prank(RitualPrecompiles.ASYNC_DELIVERY);
        controller.onLegResult(job2, rc2);
        assertEq(uint256(controller.tradingState()), uint256(MultiLegTradingState.VALUATION_PENDING));
    }

    function testFirstLegFailureAborts() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 5_000e6;
        amounts[1] = 5_000e6;
        amounts[2] = 5_000e6;
        _seedAllBuffers(amounts);
        vm.prank(owner);
        controller.requestCycle();
        bytes32 job = controller.pendingLegJobId();
        bytes32 cid = controller.currentCycleId();
        bytes memory failRc = _receipt(ExecStatus.Failed, 0, cid);
        vm.prank(RitualPrecompiles.ASYNC_DELIVERY);
        controller.onLegResult(job, failRc);
        assertEq(uint256(controller.tradingState()), uint256(MultiLegTradingState.LEG_FAILED));
    }

    function testMidCycleFailureMarksUnhedged() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 5_000e6;
        amounts[1] = 5_000e6;
        amounts[2] = 5_000e6;
        _seedAllBuffers(amounts);
        vm.prank(owner);
        controller.requestCycle();
        bytes32 cid = controller.currentCycleId();

        // Leg 0 fills.
        bytes32 job0 = controller.pendingLegJobId();
        bytes memory rc0 = _receipt(ExecStatus.Filled, 1_000e6, cid);
        vm.prank(RitualPrecompiles.ASYNC_DELIVERY);
        controller.onLegResult(job0, rc0);

        // Leg 1 fails.
        bytes32 job1 = controller.pendingLegJobId();
        bytes memory rc1 = _receipt(ExecStatus.Failed, 0, cid);
        vm.prank(RitualPrecompiles.ASYNC_DELIVERY);
        controller.onLegResult(job1, rc1);

        assertEq(uint256(controller.tradingState()), uint256(MultiLegTradingState.UNHEDGED));
    }

    function testKellyOverridesStaticWeights() public {
        int16[MAX_LEGS] memory targets;
        targets[0] = int16(2000);
        targets[1] = int16(-8000); // override short hedge magnitude
        targets[2] = int16(4000);
        OffchainKellyWeights memory w = OffchainKellyWeights({
            targetWeightBps: targets,
            totalTargetNotional: 5_000e6,
            validUntil: block.timestamp + 1 hours,
            nonce: keccak256("kelly-1")
        });
        bytes32 digest = keccak256(
            abi.encode(STRATEGY_ID, w.targetWeightBps, w.totalTargetNotional, w.validUntil, w.nonce, block.chainid, address(controller))
        );
        bytes32 prefixed = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(kellyPk, prefixed);
        bytes memory sig = abi.encodePacked(r, s, v);
        controller.submitKellyWeights(w, sig);

        assertEq(controller.effectiveWeightBps(0), int16(2000));
        assertEq(controller.effectiveCycleNotional(), 5_000e6);
    }

    function testKellyExpiredFallsBackToStatic() public {
        int16[MAX_LEGS] memory targets;
        targets[0] = int16(1000);
        OffchainKellyWeights memory w = OffchainKellyWeights({
            targetWeightBps: targets,
            totalTargetNotional: 5_000e6,
            validUntil: block.timestamp + 1 hours,
            nonce: keccak256("kelly-stale")
        });
        bytes32 digest = keccak256(
            abi.encode(STRATEGY_ID, w.targetWeightBps, w.totalTargetNotional, w.validUntil, w.nonce, block.chainid, address(controller))
        );
        bytes32 prefixed = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(kellyPk, prefixed);
        controller.submitKellyWeights(w, abi.encodePacked(r, s, v));

        vm.warp(block.timestamp + 2 hours);
        // Now expired → fallback to static 4000.
        assertEq(controller.effectiveWeightBps(0), int16(4000));
        assertEq(controller.effectiveCycleNotional(), 10_000e6);
    }

    function testKellyBadSignerReverts() public {
        int16[MAX_LEGS] memory targets;
        OffchainKellyWeights memory w = OffchainKellyWeights({
            targetWeightBps: targets,
            totalTargetNotional: 1,
            validUntil: block.timestamp + 1 hours,
            nonce: keccak256("bad")
        });
        bytes32 digest = keccak256(
            abi.encode(STRATEGY_ID, w.targetWeightBps, w.totalTargetNotional, w.validUntil, w.nonce, block.chainid, address(controller))
        );
        bytes32 prefixed = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(0xB00B), prefixed);
        vm.expectRevert(MultiLegController.KellyInvalidSignature.selector);
        controller.submitKellyWeights(w, abi.encodePacked(r, s, v));
    }

    function testKellyNonceReusedReverts() public {
        int16[MAX_LEGS] memory targets;
        targets[0] = int16(1);
        OffchainKellyWeights memory w = OffchainKellyWeights({
            targetWeightBps: targets,
            totalTargetNotional: 1,
            validUntil: block.timestamp + 1 hours,
            nonce: keccak256("reuse")
        });
        bytes32 digest = keccak256(
            abi.encode(STRATEGY_ID, w.targetWeightBps, w.totalTargetNotional, w.validUntil, w.nonce, block.chainid, address(controller))
        );
        bytes32 prefixed = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(kellyPk, prefixed);
        bytes memory sig = abi.encodePacked(r, s, v);
        controller.submitKellyWeights(w, sig);
        vm.expectRevert(MultiLegController.KellyNonceReused.selector);
        controller.submitKellyWeights(w, sig);
    }

    function testMixedLegsWithDifferentCommandTypes() public {
        // Build a clone with 3 legs: leg 0 PM, leg 1 HL, leg 2 HL (different destination).
        // Seed buffers so leg 2 is below min. Expect CommandReady(TOPUP_HL_BUFFER) for leg 2's destinationRef.
        MultiLegController c = MultiLegController(payable(Clones.clone(address(template))));
        // Mixed: PM long + HL perp short (hedge) + HL spot long (separate exposure).
        LegConfig[] memory ls = new LegConfig[](3);
        ls[0] = LegConfig({
            venue: keccak256("POLYMARKET"), marketRef: keccak256("pm-x"),
            weightBps: int16(3000), maxAbsWeightBps: 0, sizeFromPrevFill: false, maxSlippageBps: 50,
            bufferTargetUsd: 10_000e6, bufferMinUsd: 1_000e6, destinationRef: keccak256("pm-rail"),
            marginMode: MarginMode.Isolated
        });
        ls[1] = LegConfig({
            venue: keccak256("HYPERLIQUID-PERP"), marketRef: keccak256("hl-eth-perp"),
            weightBps: int16(-10_000), maxAbsWeightBps: 0, sizeFromPrevFill: true, maxSlippageBps: 30,
            bufferTargetUsd: 10_000e6, bufferMinUsd: 1_000e6, destinationRef: keccak256("hl-rail-perp"),
            marginMode: MarginMode.Isolated
        });
        ls[2] = LegConfig({
            venue: keccak256("HYPERLIQUID-SPOT"), marketRef: keccak256("hl-btc-spot"),
            weightBps: int16(4000), maxAbsWeightBps: 0, sizeFromPrevFill: false, maxSlippageBps: 30,
            bufferTargetUsd: 10_000e6, bufferMinUsd: 1_000e6, destinationRef: keccak256("hl-rail-spot"),
            marginMode: MarginMode.Isolated
        });
        MultiLegController.InitParams memory p = MultiLegController.InitParams({
            owner: owner, vaultManager: manager, baseVault: baseVault, baseAsset: baseAsset,
            strategyId: keccak256("mixed-mlh"), adapterUrl: "https://a", executor: executor,
            legs: ls, bufferStalenessSeconds: 1 hours, minCycleNotionalUsd: 100e6, maxCycleNotionalUsd: 10_000e6,
            envelopeTtlSeconds: 1 hours, kellySigner: address(0), reserveDestinationRef: keccak256("reserve")
        });
        c.initialize(p);

        // Seed buffers: leg 0 and 1 OK, leg 2 below min.
        LegBufferSnapshot[] memory snaps = new LegBufferSnapshot[](3);
        snaps[0] = LegBufferSnapshot({bufferUsd: 5_000e6, timestamp: block.timestamp});
        snaps[1] = LegBufferSnapshot({bufferUsd: 5_000e6, timestamp: block.timestamp});
        snaps[2] = LegBufferSnapshot({bufferUsd: 100, timestamp: block.timestamp});
        bytes memory body = abi.encode(snaps);
        string[] memory emptyArr = new string[](0);
        bytes memory envelope = abi.encode(uint16(200), emptyArr, emptyArr, body, "");

        bytes32 jobId = keccak256(abi.encodePacked(keccak256("mixed-mlh"), "ml-buffer", block.number));
        vm.prank(owner);
        c.tick(0);
        vm.recordLogs();
        vm.prank(RitualPrecompiles.ASYNC_DELIVERY);
        c.onBufferSyncResult(jobId, envelope);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256(
            "CommandReady(bytes32,uint8,address,address,uint256,bytes32,bytes32,uint256,uint256,bytes32)"
        );
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                found = true;
                // Leg 2's command type is TOPUP_HL_BUFFER.
                assertEq(uint256(logs[i].topics[2]), uint256(CL.CommandType.TOPUP_HL_BUFFER));
            }
        }
        assertTrue(found);
        assertEq(c.pendingTopUpLegIndex(), 2);
    }

    function testValuationSyncStoresBaseStateAndAutoUnwinds() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 5_000e6;
        amounts[1] = 5_000e6;
        amounts[2] = 5_000e6;
        _seedAllBuffers(amounts);

        // Operator enables auto-unwind: trigger when Base reserve < 1_000e6, refill to 3_000e6.
        vm.prank(owner);
        controller.setAutoUnwindThresholds(1_000e6, 3_000e6);

        // Trigger syncValuation as scheduler.
        vm.prank(RitualPrecompiles.SCHEDULER);
        controller.syncValuation(0);
        bytes32 valJob = controller.pendingValuationJobId();
        assertTrue(valJob != bytes32(0));

        // Adapter reports: NAV=10_000e6, Base reserve=500e6 (low), push succeeded on Base.
        bytes memory body = abi.encode(uint256(10_000e6), uint256(500e6), keccak256("btx"), true);
        string[] memory emptyArr = new string[](0);
        bytes memory envelope = abi.encode(uint16(200), emptyArr, emptyArr, body, "");
        vm.prank(RitualPrecompiles.ASYNC_DELIVERY);
        controller.onValuationSync(envelope);

        assertEq(controller.lastNavUsd(), 10_000e6);
        assertEq(controller.lastBaseReserveUsd(), 500e6);
        assertTrue(controller.lastValuationTimestamp() > 0);

        // Now next scheduler tick should auto-trigger unwind since reserve 500 < min 1000.
        vm.recordLogs();
        vm.prank(RitualPrecompiles.SCHEDULER);
        controller.tick(0);

        assertEq(uint256(controller.tradingState()), uint256(MultiLegTradingState.UNWIND_PENDING));
        assertEq(controller.pendingUnwindTargetUsd(), 3_000e6);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("AutoUnwindTriggered(bytes32,uint256,uint256)");
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) found = true;
        }
        assertTrue(found, "AutoUnwindTriggered not emitted");
    }

    function testClearRecoveryRejectsUnhedged() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 5_000e6;
        amounts[1] = 5_000e6;
        amounts[2] = 5_000e6;
        _seedAllBuffers(amounts);
        vm.prank(owner);
        controller.requestCycle();
        bytes32 cid = controller.currentCycleId();

        // Leg 0 fills, leg 1 fails → UNHEDGED.
        bytes32 job0 = controller.pendingLegJobId();
        vm.prank(RitualPrecompiles.ASYNC_DELIVERY);
        controller.onLegResult(job0, _receipt(ExecStatus.Filled, 1_000e6, cid));
        bytes32 job1 = controller.pendingLegJobId();
        vm.prank(RitualPrecompiles.ASYNC_DELIVERY);
        controller.onLegResult(job1, _receipt(ExecStatus.Failed, 0, cid));
        assertEq(uint256(controller.tradingState()), uint256(MultiLegTradingState.UNHEDGED));

        // UNHEDGED has open positions — clearRecovery must reject.
        vm.prank(owner);
        vm.expectRevert(MultiLegController.InvalidState.selector);
        controller.clearRecovery();

        // But operator CAN requestUnwind from UNHEDGED.
        vm.prank(owner);
        controller.requestUnwind(1_000e6);
        assertEq(uint256(controller.tradingState()), uint256(MultiLegTradingState.UNWIND_PENDING));
    }

    function testForceClearPendingUnsticks() public {
        // Force buffer sync pending, then forceClear to allow retry.
        vm.prank(RitualPrecompiles.SCHEDULER);
        controller.tick(0);
        assertTrue(controller.pendingBufferSyncJobId() != bytes32(0));

        vm.prank(owner);
        controller.forceClearPending(false, true, false, false, false);
        assertEq(controller.pendingBufferSyncJobId(), bytes32(0));
    }

    function testUnwindEmitsRefillReserve() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 5_000e6;
        amounts[1] = 5_000e6;
        amounts[2] = 5_000e6;
        _seedAllBuffers(amounts);

        vm.prank(owner);
        controller.requestUnwind(3_000e6);
        assertEq(uint256(controller.tradingState()), uint256(MultiLegTradingState.UNWIND_PENDING));
        bytes32 job = controller.pendingUnwindJobId();
        assertTrue(job != bytes32(0));

        // Adapter reports 2500e6 realized (after venue close + fees).
        bytes memory body = abi.encode(uint256(2_500e6));
        string[] memory emptyArr = new string[](0);
        bytes memory envelope = abi.encode(uint16(200), emptyArr, emptyArr, body, "");

        vm.recordLogs();
        vm.prank(RitualPrecompiles.ASYNC_DELIVERY);
        controller.onUnwindResult(job, envelope);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256(
            "CommandReady(bytes32,uint8,address,address,uint256,bytes32,bytes32,uint256,uint256,bytes32)"
        );
        bool foundRefill;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                uint8 cmdType = uint8(uint256(logs[i].topics[2]));
                if (cmdType == uint8(CrossVenueCommandLib.CommandType.REFILL_RESERVE)) foundRefill = true;
            }
        }
        assertTrue(foundRefill, "REFILL_RESERVE CommandReady not emitted");
        assertEq(uint256(controller.tradingState()), uint256(MultiLegTradingState.IDLE));
    }

    function testStaticWeightOverCapReverts() public {
        MultiLegController c = MultiLegController(payable(Clones.clone(address(template))));
        LegConfig[] memory ls = new LegConfig[](1);
        ls[0] = LegConfig({
            venue: keccak256("POLYMARKET"),
            marketRef: keccak256("m"),
            weightBps: int16(6000),
            maxAbsWeightBps: 5000, // cap
            sizeFromPrevFill: false,
            maxSlippageBps: 50,
            bufferTargetUsd: 10e6,
            bufferMinUsd: 1e6,
            destinationRef: keccak256("d"),
            marginMode: MarginMode.Isolated
        });
        MultiLegController.InitParams memory p = MultiLegController.InitParams({
            owner: owner, vaultManager: manager, baseVault: baseVault, baseAsset: baseAsset,
            strategyId: keccak256("cap-test"), adapterUrl: "x", executor: executor,
            legs: ls, bufferStalenessSeconds: 1 hours, minCycleNotionalUsd: 1, maxCycleNotionalUsd: 100,
            envelopeTtlSeconds: 1 hours, kellySigner: address(0), reserveDestinationRef: keccak256("r")
        });
        vm.expectRevert(MultiLegController.WeightExceedsCap.selector);
        c.initialize(p);
    }

    function testKellyClampsToLegCap() public {
        // controller has static weight 4000 for leg 0, default cap 0 (no cap) set in setUp.
        // Reinit a clone with cap=5000 on leg 0, then submit Kelly weight of 9000 → should clamp to 5000.
        MultiLegController c = MultiLegController(payable(Clones.clone(address(template))));
        LegConfig[] memory ls = new LegConfig[](1);
        ls[0] = LegConfig({
            venue: keccak256("POLYMARKET"),
            marketRef: keccak256("m"),
            weightBps: int16(3000),
            maxAbsWeightBps: 5000,
            sizeFromPrevFill: false,
            maxSlippageBps: 50,
            bufferTargetUsd: 10e6,
            bufferMinUsd: 1e6,
            destinationRef: keccak256("d"),
            marginMode: MarginMode.Isolated
        });
        MultiLegController.InitParams memory p = MultiLegController.InitParams({
            owner: owner, vaultManager: manager, baseVault: baseVault, baseAsset: baseAsset,
            strategyId: keccak256("clamp-test"), adapterUrl: "x", executor: executor,
            legs: ls, bufferStalenessSeconds: 1 hours, minCycleNotionalUsd: 1, maxCycleNotionalUsd: 100,
            envelopeTtlSeconds: 1 hours, kellySigner: kellySigner, reserveDestinationRef: keccak256("r")
        });
        c.initialize(p);

        int16[MAX_LEGS] memory targets;
        targets[0] = int16(9000); // over cap
        OffchainKellyWeights memory w = OffchainKellyWeights({
            targetWeightBps: targets,
            totalTargetNotional: 50,
            validUntil: block.timestamp + 1 hours,
            nonce: keccak256("clamp")
        });
        bytes32 digest = keccak256(
            abi.encode(keccak256("clamp-test"), w.targetWeightBps, w.totalTargetNotional, w.validUntil, w.nonce, block.chainid, address(c))
        );
        bytes32 prefixed = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(kellyPk, prefixed);
        c.submitKellyWeights(w, abi.encodePacked(r, s, v));

        // Effective weight clamped to +5000 (cap), not 9000.
        assertEq(c.effectiveWeightBps(0), int16(5000));
    }

    function testRejectsUnsupportedVenue() public {
        MultiLegController c = MultiLegController(payable(Clones.clone(address(template))));
        LegConfig[] memory ls = new LegConfig[](1);
        ls[0] = LegConfig({
            venue: keccak256("UNISWAP-V3"), // not one of the three allowed
            marketRef: keccak256("m"),
            weightBps: int16(1000),
            maxAbsWeightBps: 0,
            sizeFromPrevFill: false,
            maxSlippageBps: 50,
            bufferTargetUsd: 10e6,
            bufferMinUsd: 1e6,
            destinationRef: keccak256("x"),
            marginMode: MarginMode.Isolated
        });
        MultiLegController.InitParams memory p = MultiLegController.InitParams({
            owner: owner, vaultManager: manager, baseVault: baseVault, baseAsset: baseAsset,
            strategyId: keccak256("bad-venue"), adapterUrl: "x", executor: executor,
            legs: ls, bufferStalenessSeconds: 1 hours, minCycleNotionalUsd: 1, maxCycleNotionalUsd: 100,
            envelopeTtlSeconds: 1 hours, kellySigner: address(0), reserveDestinationRef: keccak256("reserve")
        });
        vm.expectRevert(MultiLegController.UnsupportedVenue.selector);
        c.initialize(p);
    }

    function testSpotLegMustBePositiveWeight() public {
        MultiLegController c = MultiLegController(payable(Clones.clone(address(template))));
        LegConfig[] memory ls = new LegConfig[](1);
        // Spot leg with negative weight — must revert.
        ls[0] = LegConfig({
            venue: keccak256("HYPERLIQUID-SPOT"),
            marketRef: keccak256("hl-btc-spot"),
            weightBps: int16(-5000),
            maxAbsWeightBps: 0,
            sizeFromPrevFill: false,
            maxSlippageBps: 30,
            bufferTargetUsd: 10e6,
            bufferMinUsd: 1e6,
            destinationRef: keccak256("hl-rail-spot"),
            marginMode: MarginMode.Isolated
        });
        MultiLegController.InitParams memory p = MultiLegController.InitParams({
            owner: owner, vaultManager: manager, baseVault: baseVault, baseAsset: baseAsset,
            strategyId: keccak256("bad-spot"), adapterUrl: "x", executor: executor,
            legs: ls, bufferStalenessSeconds: 1 hours, minCycleNotionalUsd: 1, maxCycleNotionalUsd: 100,
            envelopeTtlSeconds: 1 hours, kellySigner: address(0), reserveDestinationRef: keccak256("reserve")
        });
        vm.expectRevert(MultiLegController.SpotRequiresPositiveWeight.selector);
        c.initialize(p);
    }

    function testCloneIsolationPerStrategy() public {
        MultiLegController other = MultiLegController(payable(Clones.clone(address(template))));
        LegConfig[] memory ls = new LegConfig[](1);
        ls[0] = LegConfig({
            venue: keccak256("POLYMARKET"),
            marketRef: keccak256("x"),
            weightBps: int16(10_000),
            maxAbsWeightBps: 0,
            sizeFromPrevFill: false,
            maxSlippageBps: 50,
            bufferTargetUsd: 10e6,
            bufferMinUsd: 1e6,
            destinationRef: keccak256("d"),
            marginMode: MarginMode.Isolated
        });
        MultiLegController.InitParams memory p = MultiLegController.InitParams({
            owner: owner,
            vaultManager: manager,
            baseVault: baseVault,
            baseAsset: baseAsset,
            strategyId: keccak256("other"),
            adapterUrl: "https://other",
            executor: executor,
            legs: ls,
            bufferStalenessSeconds: 1 hours,
            minCycleNotionalUsd: 1,
            maxCycleNotionalUsd: 100,
            envelopeTtlSeconds: 1 hours,
            kellySigner: address(0),
            reserveDestinationRef: keccak256("reserve-other")
        });
        other.initialize(p);
        assertEq(other.legCount(), 1);
        assertEq(controller.legCount(), 3); // unchanged
        assertEq(other.adapterUrl(), "https://other");
        assertEq(controller.legCount(), 3);
    }
}
