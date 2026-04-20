// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {ArchetypeFactory} from "../src/factories/ArchetypeFactory.sol";
import {MultiLegController} from "../src/controllers/cross_venue/MultiLegController.sol";
import {
    LegConfig,
    ML_VENUE_HL_SPOT,
    ML_VENUE_HL_PERP,
    REF_LEG_SENTINEL
} from "../src/controllers/cross_venue/MultiLegTypes.sol";
import {MarginMode} from "../src/controllers/cross_venue/SharedVenueTypes.sol";

/// @notice HL-only delta-neutral clone (long spot UETH + short perp ETH) sized for ~$20 USDC E2E.
///         Sidesteps the Polymarket geoblock we hit in prior demos by staying fully on HL.
contract CreateHlDnClone is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address factory = vm.envAddress("FACTORY");
        address owner = vm.envAddress("OWNER");
        address baseVault = vm.envAddress("BASE_VAULT");
        address baseAsset = vm.envAddress("BASE_ASSET");
        string memory adapterUrl = vm.envString("ADAPTER_URL");
        bytes32 strategyId = vm.envBytes32("STRATEGY_ID");

        uint256 fundWei = vm.envOr("SCHEDULE_FUND", uint256(0));
        uint32 tickFreq = uint32(vm.envOr("TICK_FREQ", uint256(100)));
        uint32 valuationFreq = uint32(vm.envOr("VALUATION_FREQ", uint256(600)));
        // Scheduler hard constraint: numCalls × frequency ≤ 10_000 blocks (~58min). Max out
        // the per-batch budget so each `fundAndSchedule` call buys the full ~58min runtime.
        // For autonomy past 58min, operator (or off-chain keeper) re-calls fundAndSchedule.
        uint32 tickNumCalls = uint32(vm.envOr("TICK_NUM_CALLS", uint256(99)));       // 99 × 100 = 9900 blocks
        uint32 valuationNumCalls = uint32(vm.envOr("VALUATION_NUM_CALLS", uint256(16))); // 16 × 600 = 9600 blocks
        uint32 gasLimit = uint32(vm.envOr("SCHEDULE_GAS", uint256(500_000)));
        uint256 maxFeePerGas = vm.envOr("SCHEDULE_MAX_FEE", uint256(1_000_000_000));
        uint32 lockBlocks = uint32(vm.envOr("SCHEDULE_LOCK", uint256(50_000)));

        // Spot ref: HL spot uses "SPOT:TICKER" market refs — hand-computed in the adapter.
        // Default to UETH (0.01 UETH ≈ $20 at current prices, matches the recovered amount).
        bytes32 spotRef = vm.envOr("SPOT_MARKET_REF", keccak256(bytes("SPOT:UETH")));
        bytes32 perpRef = vm.envOr("PERP_MARKET_REF", keccak256(bytes("ETH")));

        // Sized for HL $10 venue minimum — legs trade $10-$15 notional per cycle.
        LegConfig[] memory legs = new LegConfig[](2);
        legs[0] = LegConfig({
            venue: ML_VENUE_HL_SPOT,
            marketRef: spotRef,
            weightBps: int16(10000),             // long 100% of cycle on spot
            maxAbsWeightBps: 10000,
            referenceLegIndex: REF_LEG_SENTINEL, // reference leg
            betaBps: int16(0),
            driftToleranceBps: 0,
            maxSlippageBps: 100,                 // HL spot is thinner than perp
            bufferTargetUsd: 15_000_000,         // $15 — room for $10+ order + slippage
            bufferMinUsd:    5_000_000,          // top up when under $5
            destinationRef: keccak256("dest:hl:spot"), // adapter routes to HyperCore SPOT dex
            marginMode: MarginMode.Isolated
        });
        legs[1] = LegConfig({
            venue: ML_VENUE_HL_PERP,
            marketRef: perpRef,
            weightBps: int16(10000),             // short 100% against spot
            maxAbsWeightBps: 10000,
            referenceLegIndex: 0,
            betaBps: int16(-10000),              // β = −1.0 yields SHORT perp for LONG spot
            driftToleranceBps: 500,              // 5% drift trigger
            maxSlippageBps: 50,
            bufferTargetUsd: 15_000_000,
            bufferMinUsd:    5_000_000,
            destinationRef: keccak256("dest:hl:perp"), // adapter routes to HyperCore PERP dex
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
            bufferStalenessSeconds: 120_000,     // 2min in MILLISECONDS — short enough that a tick
            minCycleNotionalUsd:  10_000_000,    // $10 — clears HL venue minimum
            maxCycleNotionalUsd:  15_000_000,    // $15 — keeps cycles sub-$20 so $50 deposit runs ~3 cycles
            envelopeTtlSeconds: 3600,
            kellySigner: address(0),
            reserveDestinationRef: keccak256("dest:refill")
        });

        bytes32 salt = keccak256(abi.encode(owner, strategyId, "hl-dn"));

        vm.startBroadcast(deployerPk);
        address clone = ArchetypeFactory(factory).createMultiLeg(p, salt);
        if (fundWei > 0) {
            MultiLegController(payable(clone)).fundAndSchedule{value: fundWei}(
                tickFreq, valuationFreq, tickNumCalls, valuationNumCalls, gasLimit, maxFeePerGas, lockBlocks
            );
        }
        vm.stopBroadcast();

        console.log("=== HL DN clone created ===");
        console.log("Clone:       ", clone);
        console.log("Owner:       ", owner);
        console.log("Base vault:  ", baseVault);
        console.log("Adapter:     ", adapterUrl);
        console.log("Spot market: UETH (long)");
        console.log("Perp market: ETH   (short)");
        console.log("Buffers: $5 each, top up at $1. Cycle: $0.50 - $4.");
    }
}
