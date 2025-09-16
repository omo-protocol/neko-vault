// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "forge-std/console.sol";

contract VerifyVaultV2 is Script {
    address constant VAULT_V2_ADDRESS = 0x6427F104D2Ee54a395c61E55FaC5CD02d60F2dEF;
    address constant VAULT_OWNER = 0x95e7EeA16ddbdb8F8aA8b4ec4B23df2067E9A413;
    address constant VAULT_ASSET = 0x5555555555555555555555555555555555555555; // WHYPE

    function run() external {
        console.log("=== VaultV2 Contract Verification ===");
        console.log("Contract Address:", VAULT_V2_ADDRESS);
        console.log("Owner:", VAULT_OWNER);
        console.log("Asset (WHYPE):", VAULT_ASSET);
        
        console.log("\nVerifying VaultV2 contract on HyperEVMScan...");
        
        // The forge verify command will be run via bash with the constructor arguments
        console.log("Constructor arguments:");
        console.log("  _owner:", VAULT_OWNER);
        console.log("  _asset:", VAULT_ASSET);
        
        console.log("\nVerification command to run:");
        console.log("forge verify-contract");
        console.log("  --chain-id 999");
        console.log("  --num-of-optimizations 100000");
        console.log("  --watch");
        console.log("  --constructor-args $(cast abi-encode 'constructor(address,address)' 0x95e7EeA16ddbdb8F8aA8b4ec4B23df2067E9A413 0x5555555555555555555555555555555555555555)");
        console.log("  --etherscan-api-key $ETHERSCAN_API_KEY");
        console.log("  --verifier-url https://api.hyperevmscan.io/api");
        console.log("  --compiler-version 0.8.28");
        console.log("  0x6427F104D2Ee54a395c61E55FaC5CD02d60F2dEF");
        console.log("  src/VaultV2.sol:VaultV2");
    }
}