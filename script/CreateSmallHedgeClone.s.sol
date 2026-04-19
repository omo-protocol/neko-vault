// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {ArchetypeFactory} from "../src/factories/ArchetypeFactory.sol";
import {MultiLegController} from "../src/controllers/cross_venue/MultiLegController.sol";
import {LegConfig, ML_VENUE_PM, ML_VENUE_HL_PERP, REF_LEG_SENTINEL} from "../src/controllers/cross_venue/MultiLegTypes.sol";
import {MarginMode} from "../src/controllers/cross_venue/SharedVenueTypes.sol";

/// @notice Demo-sized PM-long + HL-perp-short hedge clone for ~$20 USDC E2E testing.
///
///         Sizing:
///           Per-venue buffer target = $5  (room for $4 trade + $1 fees/slippage)
///           Per-venue buffer min    = $1  (top up when below)
///           Cycle min notional      = $0.50
///           Cycle max notional      = $4  (each cycle: $4 PM long + $4 HL short hedge)
///
///         Auto-scheduled with the same cadence as the v6 demo. The clone self-extends as long
///         as RitualWallet has gas budget.
contract CreateSmallHedgeClone is Script {
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
        uint32 tickNumCalls = uint32(vm.envOr("TICK_NUM_CALLS", uint256(100)));
        uint32 valuationNumCalls = uint32(vm.envOr("VALUATION_NUM_CALLS", uint256(16)));
        uint32 gasLimit = uint32(vm.envOr("SCHEDULE_GAS", uint256(500_000)));
        uint256 maxFeePerGas = vm.envOr("SCHEDULE_MAX_FEE", uint256(1_000_000_000));
        uint32 lockBlocks = uint32(vm.envOr("SCHEDULE_LOCK", uint256(20_000)));

        LegConfig[] memory legs = new LegConfig[](2);
        legs[0] = LegConfig({
            venue: ML_VENUE_PM,
            marketRef: pmMarketRef,
            weightBps: int16(5000),
            maxAbsWeightBps: 10000,
            referenceLegIndex: REF_LEG_SENTINEL,
            betaBps: int16(0),
            driftToleranceBps: 0,
            maxSlippageBps: 100,
            bufferTargetUsd: 5_000_000,
            bufferMinUsd:    1_000_000,
            destinationRef: keccak256("dest:pm"),
            marginMode: MarginMode.Isolated
        });
        legs[1] = LegConfig({
            venue: ML_VENUE_HL_PERP,
            marketRef: keccak256("ETH"),
            weightBps: int16(10000),     // full hedge of leg 0, β sign carries direction
            maxAbsWeightBps: 10000,
            referenceLegIndex: 0,
            betaBps: int16(10000),       // β = +1.0
            driftToleranceBps: 500,       // 5% drift
            maxSlippageBps: 50,
            bufferTargetUsd: 5_000_000,
            bufferMinUsd:    1_000_000,
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
            bufferStalenessSeconds: 3600,
            minCycleNotionalUsd:   500_000,    // $0.50 — small enough for $20 demo
            maxCycleNotionalUsd:  4_000_000,   // $4 — leaves headroom in $5 buffers
            envelopeTtlSeconds: 3600,
            kellySigner: address(0),
            reserveDestinationRef: keccak256("dest:refill")
        });

        bytes32 salt = keccak256(abi.encode(owner, strategyId, "small"));

        vm.startBroadcast(deployerPk);
        address clone = ArchetypeFactory(factory).createMultiLeg(p, salt);
        if (fundWei > 0) {
            MultiLegController(payable(clone)).fundAndSchedule{value: fundWei}(
                tickFreq, valuationFreq, tickNumCalls, valuationNumCalls, gasLimit, maxFeePerGas, lockBlocks
            );
        }
        vm.stopBroadcast();

        console.log("=== Small hedge clone created ===");
        console.log("Clone:        ", clone);
        console.log("Owner:        ", owner);
        console.log("Base vault:   ", baseVault);
        console.log("Adapter:      ", adapterUrl);
        console.log("Buffers:      $5 each leg, top up at $1");
        console.log("Cycle range:  $0.50 - $4.00");
        console.log("Sized for:    ~$20 deposit");
    }
}
