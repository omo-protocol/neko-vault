// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {StrategyVaultFactory} from "../src/factories/StrategyVaultFactory.sol";

/// @notice User-side demo — one tx deploys a full isolated Base stack for the PT-USDai demo.
contract DeployUserStack is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address vaultOwner = vm.envAddress("VAULT_OWNER");
        address valuerOwner = vm.envAddress("VALUER_OWNER");
        address gatewaySigner = vm.envAddress("GATEWAY_SIGNER");
        address stackFactory = vm.envAddress("STACK_FACTORY");
        address usdc = vm.envAddress("USDC");
        address cctpTokenMessenger = vm.envAddress("CCTP_TOKEN_MESSENGER");
        bytes32 strategyId = vm.envBytes32("STRATEGY_ID");
        bytes32 salt = vm.envOr("SALT", keccak256("neko-pt-usdai-jun26-stack"));

        address[] memory signers = new address[](1);
        signers[0] = gatewaySigner;

        StrategyVaultFactory.DeployParams memory p = StrategyVaultFactory.DeployParams({
            vaultOwner: vaultOwner,
            valuerOwner: valuerOwner,
            asset: usdc,
            salt: salt,
            strategyId: strategyId,
            strategyDailyLimit: 1_000_000e6,
            cctpTokenMessenger: cctpTokenMessenger,
            gatewaySigners: signers,
            gatewayThreshold: 1,
            capPmTopUp: 0,
            capHlTopUp: 10_000e6,
            capRefillReserve: 10_000e6,
            dailyCap: 20_000e6,
            gatewayName: "NekoBaseGateway",
            gatewayVersion: "1"
        });

        vm.startBroadcast(pk);
        StrategyVaultFactory.Deployment memory d = StrategyVaultFactory(stackFactory).deployStack(p);
        vm.stopBroadcast();

        console.log("=== User stack deployed ===");
        console.log("vault:        ", d.vault);
        console.log("sleeve:       ", d.sleeve);
        console.log("valuer:       ", d.valuer);
        console.log("strategyAgent:", d.strategyAgent);
        console.log("module:       ", d.module);
        console.log("gateway:      ", d.gateway);
        console.log("cctpSender:   ", d.cctpSender);
        console.log("strategyId:");
        console.logBytes32(strategyId);
    }
}
