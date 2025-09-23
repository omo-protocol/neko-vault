// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {UniversalValuerOffchain} from "../src/valuers/UniversalValuerOffchain.sol";
import {UniversalEscrowAdapter} from "../src/adapters/UniversalEscrowAdapter.sol";
import {IUniversalValuerOffchain} from "../src/adapters/interfaces/IUniversalValuerOffchain.sol";

/**
 * @title DeployUniversalValuerOffchain
 * @notice Deploy and configure the off-chain valuation system
 * @dev This script:
 *      1. Deploys UniversalValuerOffchain
 *      2. Configures authorized signers
 *      3. Sets up strategy configurations
 *      4. Optionally deploys new adapter with off-chain valuer
 */
contract DeployUniversalValuerOffchain is Script {

    struct DeploymentConfig {
        address owner;
        address asset;
        address vault;
        address escrow;
        address[] signers;
        uint256[] signerWeights;
        uint256 requiredWeight;
        bool deployNewAdapter;
    }

    struct StrategyConfig {
        bytes32 id;
        uint256 minUpdateInterval;
        uint256 maxStaleness;
        uint256 pushThreshold;
        uint256 minConfidence;
    }

    // Deployed contracts
    UniversalValuerOffchain public valuer;
    UniversalEscrowAdapter public adapter;

    // Strategy IDs
    bytes32 constant PT_KHYPE_LOOP = keccak256("PT_KHYPE_LOOP");
    bytes32 constant VNEKO_VF = keccak256("VNEKO_VF");
    bytes32 constant VNEKO_LENDING = keccak256("VNEKO_LENDING");

    /**
     * @notice Main deployment function
     */
    function run() external {
        DeploymentConfig memory config = _loadConfig();

        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        require(deployerPrivateKey != 0, "PRIVATE_KEY not set");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy UniversalValuerOffchain
        console.log("Deploying UniversalValuerOffchain...");
        valuer = new UniversalValuerOffchain(config.owner, config.asset);
        console.log("UniversalValuerOffchain deployed at:", address(valuer));

        // 2. Configure signers
        _configureSigners(config);

        // 3. Configure strategies
        _configureStrategies();

        // 4. Optionally deploy new adapter
        if (config.deployNewAdapter) {
            _deployAdapter(config);
        }

        vm.stopBroadcast();

        // Log post-deployment instructions
        _logPostDeploymentInstructions(config);
    }

    /**
     * @notice Configure authorized signers
     */
    function _configureSigners(DeploymentConfig memory config) internal {
        console.log("Configuring signers...");

        for (uint256 i = 0; i < config.signers.length; i++) {
            valuer.configureSigner(
                config.signers[i],
                true,
                config.signerWeights[i]
            );
            console.log("  Configured signer:", config.signers[i], "with weight:", config.signerWeights[i]);
        }

        // Set required weight for multi-sig
        valuer.setRequiredWeight(config.requiredWeight);
        console.log("  Required weight set to:", config.requiredWeight);
    }

    /**
     * @notice Configure strategy parameters
     */
    function _configureStrategies() internal {
        console.log("Configuring strategies...");

        // PT-kHYPE Loop Strategy
        valuer.configureStrategy(
            PT_KHYPE_LOOP,
            5 minutes,      // min update interval
            1 hours,        // max staleness
            500,            // 5% push threshold
            90              // 90% min confidence
        );
        console.log("  Configured PT_KHYPE_LOOP strategy");

        // vNeko Volatility Farming
        valuer.configureStrategy(
            VNEKO_VF,
            10 minutes,     // min update interval
            2 hours,        // max staleness
            300,            // 3% push threshold
            85              // 85% min confidence
        );
        console.log("  Configured VNEKO_VF strategy");

        // vNeko Lending
        valuer.configureStrategy(
            VNEKO_LENDING,
            15 minutes,     // min update interval
            4 hours,        // max staleness
            200,            // 2% push threshold
            95              // 95% min confidence
        );
        console.log("  Configured VNEKO_LENDING strategy");
    }

    /**
     * @notice Deploy new adapter with off-chain valuer
     */
    function _deployAdapter(DeploymentConfig memory config) internal {
        console.log("Deploying new UniversalEscrowAdapter with off-chain valuer...");

        adapter = new UniversalEscrowAdapter(
            config.vault,
            config.escrow,
            address(valuer),
            true  // Use off-chain valuer
        );

        console.log("New adapter deployed at:", address(adapter));
    }

    /**
     * @notice Load configuration from environment
     */
    function _loadConfig() internal view returns (DeploymentConfig memory config) {
        config.owner = vm.envOr("OWNER", address(0));
        config.asset = vm.envOr("ASSET", address(0));
        config.vault = vm.envOr("VAULT", address(0));
        config.escrow = vm.envOr("ESCROW", address(0));

        // Parse signers (comma-separated in env)
        string memory signersStr = vm.envOr("SIGNERS", string(""));
        if (bytes(signersStr).length > 0) {
            // For simplicity, expecting single signer in this example
            // In production, would parse comma-separated list
            config.signers = new address[](1);
            config.signers[0] = vm.envAddress("SIGNER_1");

            config.signerWeights = new uint256[](1);
            config.signerWeights[0] = 1;
        }

        config.requiredWeight = vm.envOr("REQUIRED_WEIGHT", uint256(1));
        config.deployNewAdapter = vm.envOr("DEPLOY_ADAPTER", false);

        // Validate config
        require(config.owner != address(0), "OWNER not set");
        require(config.asset != address(0), "ASSET not set");
    }

    /**
     * @notice Log post-deployment instructions
     */
    function _logPostDeploymentInstructions(DeploymentConfig memory config) internal pure {
        console.log("\n=== POST-DEPLOYMENT INSTRUCTIONS ===");
        console.log("\n1. Start the off-chain keeper service:");
        console.log("   - Update keeper_config.json with deployed valuer address");
        console.log("   - Configure keeper private key (different from signers)");
        console.log("   - Run: python3 OffchainValuationKeeper.py");

        console.log("\n2. If using existing adapter:");
        console.log("   - Submit timelock to update adapter's valuer address");
        console.log("   - Wait for timelock delay");
        console.log("   - Execute update");

        console.log("\n3. Test the system:");
        console.log("   - Request an update: valuer.requestUpdate(strategyId)");
        console.log("   - Monitor keeper logs for update execution");
        console.log("   - Verify value: valuer.getValue(strategyId)");

        console.log("\n4. Emergency procedures:");
        console.log("   - Enable emergency mode: valuer.setEmergencyMode(true)");
        console.log("   - Force update: valuer.emergencyUpdate(strategyId, value)");
        console.log("   - Set fallback values: valuer.setFallbackValue(strategyId, value)");

        console.log("\n5. Multi-sig setup (if applicable):");
        console.log("   - Add additional signers: valuer.configureSigner(signer, true, weight)");
        console.log("   - Update required weight: valuer.setRequiredWeight(totalWeight)");
    }

    /**
     * @notice Add a new signer to existing deployment
     */
    function addSigner(address signer, uint256 weight) external {
        address valuerAddress = vm.envAddress("VALUER_ADDRESS");
        require(valuerAddress != address(0), "VALUER_ADDRESS not set");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        UniversalValuerOffchain existingValuer = UniversalValuerOffchain(valuerAddress);
        existingValuer.configureSigner(signer, true, weight);

        console.log("Added signer:", signer, "with weight:", weight);

        vm.stopBroadcast();
    }

    /**
     * @notice Update strategy configuration
     */
    function updateStrategy(
        bytes32 strategyId,
        uint256 minUpdateInterval,
        uint256 maxStaleness,
        uint256 pushThreshold,
        uint256 minConfidence
    ) external {
        address valuerAddress = vm.envAddress("VALUER_ADDRESS");
        require(valuerAddress != address(0), "VALUER_ADDRESS not set");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        UniversalValuerOffchain existingValuer = UniversalValuerOffchain(valuerAddress);
        existingValuer.configureStrategy(
            strategyId,
            minUpdateInterval,
            maxStaleness,
            pushThreshold,
            minConfidence
        );

        console.log("Updated strategy:", vm.toString(strategyId));

        vm.stopBroadcast();
    }

    /**
     * @notice Migrate from on-chain to off-chain valuer
     */
    function migrate() external {
        DeploymentConfig memory config = _loadConfig();

        require(config.vault != address(0), "VAULT not set");
        require(config.escrow != address(0), "ESCROW not set");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        console.log("=== MIGRATION PROCESS ===");

        // 1. Deploy off-chain valuer
        console.log("Step 1: Deploying UniversalValuerOffchain...");
        valuer = new UniversalValuerOffchain(config.owner, config.asset);
        console.log("  Deployed at:", address(valuer));

        // 2. Configure it
        _configureSigners(config);
        _configureStrategies();

        // 3. Deploy new adapter
        console.log("Step 2: Deploying new adapter with off-chain valuer...");
        adapter = new UniversalEscrowAdapter(
            config.vault,
            config.escrow,
            address(valuer),
            true
        );
        console.log("  New adapter at:", address(adapter));

        console.log("\nStep 3: Manual steps required:");
        console.log("  a. Submit timelock to add new adapter to vault");
        console.log("  b. Wait for timelock delay");
        console.log("  c. Execute addAdapter");
        console.log("  d. Migrate allocations from old to new adapter");
        console.log("  e. Remove old adapter");

        vm.stopBroadcast();
    }
}