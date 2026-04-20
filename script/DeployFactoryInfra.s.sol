// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {VaultV2Factory} from "../src/VaultV2Factory.sol";
import {UniversalAdapterEscrowFactory} from "../src/adapters/UniversalAdapterEscrowFactory.sol";
import {BaseCoreFactory} from "../src/factories/BaseCoreFactory.sol";
import {BaseExecFactory} from "../src/factories/BaseExecFactory.sol";
import {StrategyVaultFactory} from "../src/factories/StrategyVaultFactory.sol";

/// @notice One-shot deploy of the operator-side factory infrastructure — five contracts that
///         let any user spin up an isolated vault stack in one tx via StrategyVaultFactory.
///
///         Run once per chain. After this, users / frontends only ever touch
///         StrategyVaultFactory + ArchetypeFactory (on Ritual).
contract DeployFactoryInfra is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        VaultV2Factory vaultFactory = new VaultV2Factory();
        UniversalAdapterEscrowFactory adapterFactory = new UniversalAdapterEscrowFactory();
        BaseCoreFactory coreFactory = new BaseCoreFactory(address(vaultFactory), address(adapterFactory));
        BaseExecFactory execFactory = new BaseExecFactory();
        StrategyVaultFactory stackFactory = new StrategyVaultFactory(address(coreFactory), address(execFactory));

        vm.stopBroadcast();

        console.log("=== Factory infrastructure deployed ===");
        console.log("VaultV2Factory:               ", address(vaultFactory));
        console.log("UniversalAdapterEscrowFactory:", address(adapterFactory));
        console.log("BaseCoreFactory:              ", address(coreFactory));
        console.log("BaseExecFactory:              ", address(execFactory));
        console.log("   moduleImpl:                ", execFactory.moduleImpl());
        console.log("   gatewayImpl:               ", execFactory.gatewayImpl());
        console.log("   cctpSenderImpl:            ", execFactory.cctpSenderImpl());
        console.log("StrategyVaultFactory:         ", address(stackFactory));
        console.log("");
        console.log("Users call stackFactory.deployStack(params) for a full isolated stack.");
    }
}
