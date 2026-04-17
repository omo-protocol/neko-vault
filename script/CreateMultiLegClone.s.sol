// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {ArchetypeFactory} from "../src/factories/ArchetypeFactory.sol";
import {MultiLegController} from "../src/controllers/cross_venue/MultiLegController.sol";
import {LegConfig, ML_VENUE_PM, ML_VENUE_HL_PERP} from "../src/controllers/cross_venue/MultiLegTypes.sol";
import {MarginMode} from "../src/controllers/cross_venue/SharedVenueTypes.sol";

/// @notice Creates a MultiLegController clone via ArchetypeFactory. Testnet demo defaults:
///         leg 0 = POLYMARKET long (weightBps=+5000), leg 1 = HL perp short (-10000, sizeFromPrevFill=true).
///         `executor` is a placeholder — owner updates via setExecutor once a TEE is assigned.
///         Secrets (ECIES-encrypted venue keys) are set post-deploy via `setSecrets(blobs, sigs)`.
///
///         Env vars:
///           PRIVATE_KEY     — deployer
///           FACTORY         — ArchetypeFactory address on Ritual
///           OWNER           — strategy owner / vaultManager
///           BASE_VAULT      — vault address on Base
///           BASE_ASSET      — USDC address on Base
///           ADAPTER_URL     — HTTPS URL of the adapter
///           PM_MARKET_REF   — bytes32 PM tokenId
///           STRATEGY_ID     — bytes32 unique strategy id
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

        LegConfig[] memory legs = new LegConfig[](2);
        legs[0] = LegConfig({
            venue: ML_VENUE_PM,
            marketRef: pmMarketRef,
            weightBps: int16(5000), // +50% long YES
            maxAbsWeightBps: 10000,
            sizeFromPrevFill: false,
            maxSlippageBps: 50,
            bufferTargetUsd: 100e6,
            bufferMinUsd: 10e6,
            destinationRef: keccak256("dest:pm"),
            marginMode: MarginMode.Isolated
        });
        legs[1] = LegConfig({
            venue: ML_VENUE_HL_PERP,
            marketRef: keccak256("ETH"),
            weightBps: int16(-10000), // -100% of PM fill → short hedge
            maxAbsWeightBps: 10000,
            sizeFromPrevFill: true,
            maxSlippageBps: 30,
            bufferTargetUsd: 100e6,
            bufferMinUsd: 10e6,
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
            executor: address(0), // placeholder — update via setExecutor once TEE is assigned
            legs: legs,
            bufferStalenessSeconds: 3600,
            minCycleNotionalUsd: 1e6,
            maxCycleNotionalUsd: 100e6,
            envelopeTtlSeconds: 3600,
            kellySigner: address(0),
            reserveDestinationRef: keccak256("dest:refill")
        });

        bytes32 salt = keccak256(abi.encode(owner, strategyId));

        vm.startBroadcast(deployerPk);
        address clone = ArchetypeFactory(factory).createMultiLeg(p, salt);
        vm.stopBroadcast();

        console.log("=== MultiLeg clone created ===");
        console.log("Clone:      ", clone);
        console.log("Owner:      ", owner);
        console.log("Base vault: ", baseVault);
        console.log("Adapter:    ", adapterUrl);
        console.log("Leg count:  2 (PM long + HL perp short hedge)");
    }
}
