// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/valuers/UniversalValuerOffchain.sol";

contract DeployValuer is Script {
    // address asset = 0xfD739d4e423301CE9385c1fb8850539D657C296D; // KHYPE
    // bytes32 constant STRATEGY_ID = keccak256("pt-khype-looper"); // pt-khype-looper
    address asset = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14; // WETH
    bytes32 constant STRATEGY_ID = keccak256("hype-stack-vault"); //  HYPE STACK Vault

    function run() public {
        // Load private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        UniversalValuerOffchain valuer = new UniversalValuerOffchain(deployer, asset);
        console.log("Valuer deployed:", address(valuer));

        // Configure valuer
        valuer.initiateSignerChange(deployer, true, 100);
        valuer.setRequiredWeight(90); // 90% of required weight

        valuer.configureStrategy(
            STRATEGY_ID,
            300,        // minUpdateInterval: 5 minutes
            3600,       // maxStaleness: 1 hour
            500,        // pushThreshold: 5% change triggers update
            90          // minConfidence: 90% (must be >= defaultConfidenceThreshold)
        );

        // Set price change bounds (50% max change)
        valuer.setPriceChangeBounds(STRATEGY_ID, 5000);

        vm.stopBroadcast();

        console.log("\n=================================================");
        console.log("    VALUER DEPLOYMENT COMPLETE!");
        console.log("=================================================");
        console.log("Valuer deployed:", address(valuer));
        console.log("\n[SUCCESS] Valuer deployed!");
    }
}