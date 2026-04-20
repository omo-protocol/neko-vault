// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {ArchetypeFactory} from "../src/factories/ArchetypeFactory.sol";
import {MultiLegController} from "../src/controllers/cross_venue/MultiLegController.sol";
import {LegConfig, MarginMode, ML_VENUE_HL_SPOT, ML_VENUE_HL_PERP, REF_LEG_SENTINEL} from "../src/controllers/cross_venue/MultiLegTypes.sol";

/// @notice Demo MultiLeg clone — 2-leg HL delta-neutral on ETH (long spot + short perp).
///
///         Env vars:
///           PRIVATE_KEY      — deployer / owner
///           FACTORY          — ArchetypeFactory on Ritual
///           BASE_VAULT       — VaultV2 on Base
///           ADAPTER_URL      — adapter HTTPS endpoint
///           STRATEGY_ID      — bytes32 strategy id (must match sleeve's registered strategy)
contract CreateMultiLegClone is Script {
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address factory = vm.envAddress("FACTORY");
        address baseVault = vm.envAddress("BASE_VAULT");
        string memory adapterUrl = vm.envString("ADAPTER_URL");
        bytes32 strategyId = vm.envBytes32("STRATEGY_ID");
        address owner = vm.addr(pk);

        bytes32 ethMarket = keccak256("ETH-USD");

        // Leg 0: long HL spot ETH (reference, w=+100%, β ignored)
        // Leg 1: short HL perp ETH (hedge, w=-100%, β=+100% → hedge sizes 1:1 with spot)
        LegConfig[] memory legs = new LegConfig[](2);
        legs[0] = LegConfig({
            venue: ML_VENUE_HL_SPOT,
            marketRef: ethMarket,
            weightBps: int16(10_000),
            maxAbsWeightBps: 0,
            referenceLegIndex: REF_LEG_SENTINEL,
            betaBps: int16(0),
            driftToleranceBps: 0,
            maxSlippageBps: 100,
            bufferTargetUsd: 15_000_000,
            bufferMinUsd: 5_000_000,
            destinationRef: keccak256("dest:hl:spot"),
            marginMode: MarginMode.Cross
        });
        legs[1] = LegConfig({
            venue: ML_VENUE_HL_PERP,
            marketRef: ethMarket,
            weightBps: int16(-10_000),
            maxAbsWeightBps: 0,
            referenceLegIndex: 0,
            betaBps: int16(10_000),
            driftToleranceBps: 1_000,
            maxSlippageBps: 100,
            bufferTargetUsd: 15_000_000,
            bufferMinUsd: 5_000_000,
            destinationRef: keccak256("dest:hl:perp"),
            marginMode: MarginMode.Cross
        });

        MultiLegController.InitParams memory p = MultiLegController.InitParams({
            owner: owner,
            vaultManager: owner,
            baseVault: baseVault,
            baseAsset: BASE_USDC,
            strategyId: strategyId,
            adapterUrl: adapterUrl,
            executor: address(0),
            legs: legs,
            bufferStalenessSeconds: 120_000,
            minCycleNotionalUsd: 10_000_000,
            maxCycleNotionalUsd: 1_000_000_000,
            envelopeTtlSeconds: 3600,
            kellySigner: address(0),
            reserveDestinationRef: keccak256("dest:refill")
        });

        bytes32 salt = keccak256(abi.encode(owner, strategyId, "multileg-eth-dn-v2"));

        vm.startBroadcast(pk);
        address clone = ArchetypeFactory(factory).createMultiLeg(p, salt);
        vm.stopBroadcast();

        console.log("=== MultiLeg clone created ===");
        console.log("Clone:       ", clone);
        console.log("Owner:       ", owner);
        console.log("Base vault:  ", baseVault);
        console.log("Next: bootstrap secrets, fundAndSchedule, seed USDC deposit");
    }
}
