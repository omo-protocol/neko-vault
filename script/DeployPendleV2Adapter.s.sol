// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PendleV2Adapter} from "../src/adapters/PendleV2Adapter.sol";
import {VaultV2} from "../src/VaultV2.sol";

/**
 * @title DeployPendleV2Adapter
 * @notice Deploy PendleV2Adapter and integrate with VaultV2
 * @dev Based on INSTRUCTIONS.md workflow for custom adapters
 */
contract DeployPendleV2Adapter is Script {
    
    struct PendleConfig {
        address vault;
        address pendleRouter;    // Pendle Router V3 address
        address pOracle;        // Pendle PT Oracle address  
        address syOracle;       // Pendle SY Oracle address
        address curator;        // For timelock submissions
        uint256 timelockDelay;  // Timelock delay in seconds
    }

    struct DeploymentResult {
        address adapter;
        bytes32[] ids;          // Risk IDs returned by adapter
        uint256 timelockValidAt; // When timelock can be executed
    }

    /**
     * @notice Deploy PendleV2Adapter for a vault
     */
    function run() external returns (DeploymentResult memory result) {
        PendleConfig memory config = _loadPendleConfig();
        _validateConfig(config);
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy PendleV2Adapter
        PendleV2Adapter adapter = new PendleV2Adapter(
            config.vault,
            config.pendleRouter,
            config.pOracle,
            config.syOracle
        );
        
        result.adapter = address(adapter);
        console.log("[SUCCESS] PendleV2Adapter deployed at:", result.adapter);
        console.log("  Vault:", config.vault);
        console.log("  Pendle Router:", config.pendleRouter);
        console.log("  PT Oracle:", config.pOracle);
        console.log("  SY Oracle:", config.syOracle);

        vm.stopBroadcast();
        
        // 2. Log integration steps
        _logIntegrationSteps(config, result);
        
        return result;
    }

    /**
     * @notice Deploy adapter only (separate from integration)
     */
    function deployAdapter(
        address vault,
        address pendleRouter, 
        address pOracle,
        address syOracle
    ) external returns (address adapter) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        adapter = address(new PendleV2Adapter(vault, pendleRouter, pOracle, syOracle));
        console.log("[SUCCESS] PendleV2Adapter deployed at:", adapter);

        vm.stopBroadcast();
        return adapter;
    }

    /**
     * @notice Submit timelock to add PendleV2Adapter to vault (as Curator)
     */
    function submitAddAdapterTimelock(address adapter) external returns (uint256 validAt) {
        PendleConfig memory config = _loadPendleConfig();
        require(config.vault != address(0), "VAULT_ADDRESS not set");
        require(adapter != address(0), "Invalid adapter address");
        
        uint256 curatorPrivateKey = vm.envUint("CURATOR_PRIVATE_KEY");
        vm.startBroadcast(curatorPrivateKey);

        VaultV2 vault = VaultV2(config.vault);
        
        // Submit timelock for addAdapter
        bytes memory data = abi.encodeWithSelector(vault.addAdapter.selector, adapter);
        vault.submit(data);
        
        validAt = block.timestamp + config.timelockDelay;
        
        console.log("[SUCCESS] Submitted timelock to add PendleV2Adapter");
        console.log("  Adapter:", adapter);
        console.log("  Valid at:", validAt);
        console.log("  Wait", config.timelockDelay, "seconds before executing");

        vm.stopBroadcast();
        return validAt;
    }

    /**
     * @notice Execute the addAdapter timelock (after delay)
     */
    function executeAddAdapter(address adapter) external {
        PendleConfig memory config = _loadPendleConfig();
        require(config.vault != address(0), "VAULT_ADDRESS not set");
        
        uint256 executorPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(executorPrivateKey);

        VaultV2 vault = VaultV2(config.vault);
        
        // Execute addAdapter (timelock checked automatically)
        vault.addAdapter(adapter);
        
        console.log("[SUCCESS] Executed addAdapter timelock");
        console.log("  Adapter:", adapter);
        console.log("  Adapter is now enabled in vault");

        vm.stopBroadcast();
    }

    /**
     * @notice Submit timelock to set caps for Pendle markets/PTs
     */
    function submitSetCapsTimelock(
        bytes32[] calldata ids, 
        uint256[] calldata caps
    ) external {
        PendleConfig memory config = _loadPendleConfig();
        require(config.vault != address(0), "VAULT_ADDRESS not set");
        require(ids.length == caps.length, "Array length mismatch");
        
        uint256 curatorPrivateKey = vm.envUint("CURATOR_PRIVATE_KEY");
        vm.startBroadcast(curatorPrivateKey);

        VaultV2 vault = VaultV2(config.vault);
        
        // Submit timelock for each cap individually
        for (uint256 i = 0; i < ids.length; i++) {
            bytes memory idData = abi.encode(ids[i]);
            bytes memory data = abi.encodeWithSelector(vault.increaseAbsoluteCap.selector, idData, caps[i]);
            vault.submit(data);
            
            console.log("[SUCCESS] Submitted cap timelock for ID:", vm.toString(ids[i]));
            console.log("  Cap:", caps[i]);
        }
        
        console.log("Wait", config.timelockDelay, "seconds before executing caps");

        vm.stopBroadcast();
    }

    /**
     * @notice Get adapter risk IDs for cap configuration
     */
    function getAdapterIds(address adapter, address market) external view returns (bytes32[] memory ids) {
        require(adapter != address(0), "Invalid adapter address");
        require(market != address(0), "Invalid market address");
        
        PendleV2Adapter pendleAdapter = PendleV2Adapter(adapter);
        ids = pendleAdapter.ids(market);
        
        console.log("Adapter IDs for market:", market);
        for (uint256 i = 0; i < ids.length; i++) {
            console.log("  ID", i, ":", vm.toString(ids[i]));
        }
        
        return ids;
    }

    /**
     * @notice Test allocation to Pendle market (as Allocator)
     */
    function testAllocation(
        address adapter,
        address market,
        uint256 assets,
        bytes calldata pendleCallData
    ) external returns (bytes32[] memory ids, int256 change) {
        PendleConfig memory config = _loadPendleConfig();
        require(config.vault != address(0), "VAULT_ADDRESS not set");
        
        uint256 allocatorPrivateKey = vm.envUint("ALLOCATOR_PRIVATE_KEY");
        vm.startBroadcast(allocatorPrivateKey);

        VaultV2 vault = VaultV2(config.vault);
        
        // Allocate to Pendle via adapter
        vault.allocate(adapter, pendleCallData, assets);
        
        console.log("[SUCCESS] Allocated", assets, "assets to Pendle market");
        console.log("  Market:", market);
        console.log("  Adapter:", adapter);

        vm.stopBroadcast();
        
        // Get the IDs and check real assets
        PendleV2Adapter pendleAdapter = PendleV2Adapter(adapter);
        ids = pendleAdapter.ids(market);
        uint256 realAssets = pendleAdapter.realAssets();
        
        console.log("Real assets in adapter:", realAssets);
        
        return (ids, int256(assets)); // Simplified return
    }

    /**
     * @notice Load Pendle configuration from environment
     */
    function _loadPendleConfig() internal view returns (PendleConfig memory config) {
        config.vault = vm.envOr("VAULT_ADDRESS", address(0));
        config.pendleRouter = vm.envOr("PENDLE_ROUTER", address(0));
        config.pOracle = vm.envOr("PENDLE_PT_ORACLE", address(0));
        config.syOracle = vm.envOr("PENDLE_SY_ORACLE", address(0));
        config.curator = vm.envOr("VAULT_CURATOR", address(0));
        config.timelockDelay = vm.envOr("TIMELOCK_DELAY", uint256(1 days));
    }

    /**
     * @notice Validate required configuration
     */
    function _validateConfig(PendleConfig memory config) internal pure {
        require(config.vault != address(0), "VAULT_ADDRESS required");
        require(config.pendleRouter != address(0), "PENDLE_ROUTER required");
        require(config.pOracle != address(0), "PENDLE_PT_ORACLE required");
        require(config.syOracle != address(0), "PENDLE_SY_ORACLE required");
    }

    /**
     * @notice Log post-deployment integration steps
     */
    function _logIntegrationSteps(PendleConfig memory config, DeploymentResult memory result) internal pure {
        console.log("\n=== PENDLE INTEGRATION STEPS ===");
        console.log("\n1. Add Adapter to Vault (as Curator):");
        console.log("   forge script script/DeployPendleV2Adapter.s.sol --sig 'submitAddAdapterTimelock(address)' --rpc-url $RPC_URL --broadcast");
        console.log("   Wait for timelock delay, then:");
        console.log("   forge script script/DeployPendleV2Adapter.s.sol --sig 'executeAddAdapter(address)' --rpc-url $RPC_URL --broadcast");
        
        console.log("\n2. Configure Caps for Pendle Markets (as Curator):");
        console.log("   - Get adapter IDs: getAdapterIds(adapter, market)");
        console.log("   - Submit cap timelocks: submitSetCapsTimelock(ids[], caps[])");
        console.log("   - Execute cap timelocks after delay");
        
        console.log("\n3. Test Allocation (as Allocator):");
        console.log("   - Prepare Pendle call data (e.g., swapExactTokenForPt)");
        console.log("   - Call: testAllocation(adapter, market, assets, callData)");
        console.log("   - Verify: adapter.realAssets() and vault.totalAssets()");
        
        console.log("\n4. Monitor & Manage:");
        console.log("   - Monitor PT price via PT Oracle");
        console.log("   - Rebalance allocations via deallocate/allocate");
        console.log("   - Use forceDeallocate for emergency exits");
        
        console.log("\n[WARNING] Test on testnet first!");
        console.log("[INFO] Adapter:", result.adapter);
    }
}