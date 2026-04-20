// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {ArchetypeFactory} from "../src/factories/ArchetypeFactory.sol";
import {MultiLegController} from "../src/controllers/cross_venue/MultiLegController.sol";
import {LegConfig, ML_VENUE_PM, ML_VENUE_HL_PERP, REF_LEG_SENTINEL} from "../src/controllers/cross_venue/MultiLegTypes.sol";
import {MarginMode} from "../src/controllers/cross_venue/SharedVenueTypes.sol";

/// @notice Creates a MultiLegController clone via ArchetypeFactory and (optionally) auto-schedules
///         `tick()` + `syncValuation()` on the Ritual Scheduler.
///
///         Env vars:
///           PRIVATE_KEY       — strategy owner (must hold enough RITUAL to cover `SCHEDULE_FUND`)
///           FACTORY           — ArchetypeFactory address on Ritual
///           OWNER             — strategy owner / vaultManager
///           BASE_VAULT        — vault address on Base
///           BASE_ASSET        — USDC address on Base
///           ADAPTER_URL       — HTTPS URL of the adapter
///           PM_MARKET_REF     — bytes32 PM tokenId
///           STRATEGY_ID       — bytes32 unique strategy id
///
///         Optional — recurring-call scheduling preferences (set all or none):
///           SCHEDULE_FUND       — RITUAL amount (wei) to deposit into RitualWallet for future ticks.
///                                  If 0 or unset, scheduling step is skipped (caller can run
///                                  fundAndSchedule manually later).
///           TICK_FREQ           — blocks between `tick()` calls (default 100 ≈ 35s @ 350ms blocks)
///           VALUATION_FREQ      — blocks between `syncValuation()` calls (default 600 ≈ 3.5min)
///           TICK_NUM_CALLS      — number of tick executions (default 100; max ≈ 10000/TICK_FREQ)
///           VALUATION_NUM_CALLS — number of valuation executions (default 16; max ≈ 10000/VALUATION_FREQ)
///           SCHEDULE_GAS        — per-call gas (default 500_000)
///           SCHEDULE_MAX_FEE    — maxFeePerGas for scheduled calls (default 1 gwei)
///           SCHEDULE_LOCK       — RitualWallet lock duration in blocks (default 50_000 ≈ 5h)
///
///         Scheduler enforces `numCalls × frequency ≤ 10000 blocks` per schedule. Re-run
///         `fundAndSchedule` later to extend.
contract CreateMultiLegClone is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address factory = vm.envAddress("FACTORY");
        address owner = vm.envAddress("OWNER");
        address baseVault = vm.envAddress("BASE_VAULT");
        address baseAsset = vm.envAddress("BASE_ASSET");
        string memory adapterUrl = vm.envString("ADAPTER_URL");
        bytes32 pmMarketRef = vm.envBytes32("PM_MARKET_REF");
        bytes32 strategyId = vm.envBytes32("STRATEGY_ID");

        uint256 fundWei = vm.envOr("SCHEDULE_FUND", uint256(0));
        uint32 tickFreq = uint32(vm.envOr("TICK_FREQ", uint256(100)));
        uint32 valuationFreq = uint32(vm.envOr("VALUATION_FREQ", uint256(600)));
        // Scheduler hard constraint: numCalls × frequency ≤ 10_000 per batch (~58min).
        uint32 tickNumCalls = uint32(vm.envOr("TICK_NUM_CALLS", uint256(99)));
        uint32 valuationNumCalls = uint32(vm.envOr("VALUATION_NUM_CALLS", uint256(16)));
        uint32 gasLimit = uint32(vm.envOr("SCHEDULE_GAS", uint256(500_000)));
        uint256 maxFeePerGas = vm.envOr("SCHEDULE_MAX_FEE", uint256(1_000_000_000));
        uint32 lockBlocks = uint32(vm.envOr("SCHEDULE_LOCK", uint256(50_000)));

        uint256 pmBufferTarget = vm.envOr("PM_BUFFER_TARGET", uint256(100e6));
        uint256 pmBufferMin = vm.envOr("PM_BUFFER_MIN", uint256(10e6));
        uint256 hlBufferTarget = vm.envOr("HL_BUFFER_TARGET", uint256(100e6));
        uint256 hlBufferMin = vm.envOr("HL_BUFFER_MIN", uint256(10e6));

        // Framework: leg 0 is the reference (PM long — takes the exposure), leg 1 is a hedge
        // against leg 0 with w=1.0 (full hedge) and β=1.0 (same-asset hedge ratio). Operator
        // overrides via env to run partial hedges or cross-instrument betas.
        LegConfig[] memory legs = new LegConfig[](2);
        legs[0] = LegConfig({
            venue: ML_VENUE_PM,
            marketRef: pmMarketRef,
            weightBps: int16(int256(vm.envOr("REF_WEIGHT_BPS", uint256(5000)))),
            maxAbsWeightBps: 10000,
            referenceLegIndex: REF_LEG_SENTINEL,
            betaBps: int16(0),                   // ignored for reference legs
            driftToleranceBps: 0,                // ignored for reference legs
            maxSlippageBps: 50,
            bufferTargetUsd: pmBufferTarget,
            bufferMinUsd: pmBufferMin,
            destinationRef: keccak256("dest:pm"),
            marginMode: MarginMode.Isolated
        });
        legs[1] = LegConfig({
            venue: ML_VENUE_HL_PERP,
            marketRef: vm.envOr("HL_MARKET_REF", keccak256("ETH")),
            weightBps: int16(int256(vm.envOr("HEDGE_WEIGHT_BPS", uint256(10000)))),
            maxAbsWeightBps: 10000,
            referenceLegIndex: 0,
            // HEDGE_BETA_BPS: signed; default +10000 (β=+1.0). For anti-correlated hedges
            // like PM YES vs PM NO set this to -10000 (β=-1.0).
            betaBps: int16(int256(vm.envOr("HEDGE_BETA_BPS", uint256(10000)))),
            // Auto-rebalance when |w_eff - w_target| drifts more than 500 bps (5%) by default.
            driftToleranceBps: uint16(vm.envOr("HEDGE_DRIFT_TOL_BPS", uint256(500))),
            maxSlippageBps: 30,
            bufferTargetUsd: hlBufferTarget,
            bufferMinUsd: hlBufferMin,
            destinationRef: keccak256("dest:hl"),
            marginMode: MarginMode.Isolated
        });

        MultiLegController.InitParams memory p = MultiLegController.InitParams({
            owner: owner,
            vaultManager: owner,
            baseVault: baseVault,
            baseAsset: baseAsset,
            strategyId: strategyId,
            adapterUrl: adapterUrl,
            executor: address(0),
            legs: legs,
            // bufferStalenessSeconds is misleadingly named — Ritual block.timestamp is in MS,
            // so this field is also in ms. 3_600_000 = 1 hour staleness window.
            bufferStalenessSeconds: vm.envOr("BUFFER_STALENESS_MS", uint256(3_600_000)),
            minCycleNotionalUsd: vm.envOr("MIN_CYCLE_NOTIONAL", uint256(1e6)),
            maxCycleNotionalUsd: vm.envOr("MAX_CYCLE_NOTIONAL", uint256(100e6)),
            // envelopeTtlSeconds is in SECONDS — used to compute Base-side deadline (Base
            // block.timestamp is sec). Controller divides Ritual block.timestamp by 1000 first.
            envelopeTtlSeconds: vm.envOr("ENVELOPE_TTL_SEC", uint256(3600)),
            kellySigner: address(0),
            reserveDestinationRef: keccak256("dest:refill")
        });

        bytes32 salt = keccak256(abi.encode(owner, strategyId));

        vm.startBroadcast(deployerPk);
        address clone = ArchetypeFactory(factory).createMultiLeg(p, salt);

        if (fundWei > 0) {
            // fundAndSchedule is payable; msg.value arrives at the clone which deposits it
            // into RitualWallet under the clone's account and schedules both recurring calls.
            MultiLegController(payable(clone)).fundAndSchedule{value: fundWei}(
                tickFreq, valuationFreq, tickNumCalls, valuationNumCalls, gasLimit, maxFeePerGas, lockBlocks
            );
        }
        vm.stopBroadcast();

        console.log("=== MultiLeg clone created ===");
        console.log("Clone:       ", clone);
        console.log("Owner:       ", owner);
        console.log("Base vault:  ", baseVault);
        console.log("Adapter:     ", adapterUrl);
        console.log("Leg count:   2 (PM long + HL perp short hedge)");
        if (fundWei > 0) {
            console.log("Scheduled:   tick every %s blocks, valuation every %s blocks", tickFreq, valuationFreq);
            console.log("Funded:      %s wei -> RitualWallet", fundWei);
        } else {
            console.log("Schedules:   NOT set (SCHEDULE_FUND=0). Call fundAndSchedule manually later.");
        }
    }
}
