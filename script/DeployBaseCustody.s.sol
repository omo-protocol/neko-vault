// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {VaultV2Factory} from "../src/VaultV2Factory.sol";
import {UniversalAdapterEscrowFactory} from "../src/adapters/UniversalAdapterEscrowFactory.sol";
import {BaseCoreFactory} from "../src/factories/BaseCoreFactory.sol";
import {BaseExecFactory} from "../src/factories/BaseExecFactory.sol";

/// @notice One-shot script that deploys:
///           1. VaultV2Factory + UniversalAdapterEscrowFactory
///           2. BaseCoreFactory (phase 1) + BaseExecFactory (phase 2)
///           3. coreFactory.deployCore(...) → vault / sleeve / valuer / agent
///           4. execFactory.deployExec(...) → module / gateway / oftSender
///
///         Env vars:
///           PRIVATE_KEY               — deployer
///           USDC_ADDRESS              — asset (e.g. Base Sepolia USDC 0x036C...)
///           OWNER                     — final owner for vault / sleeve / module / gateway / oftSender
///           VALUER_OWNER              — final owner for valuer (typically adapter's Base EOA)
///           STRATEGY_ID               — bytes32
///           SIGNER1, SIGNER2          — two gateway quorum signers (threshold = 2)
contract DeployBaseCustody is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address owner = vm.envAddress("OWNER");
        address valuerOwner = vm.envOr("VALUER_OWNER", owner);
        bytes32 strategyId = vm.envOr("STRATEGY_ID", keccak256(abi.encode(owner, usdc, "neko-v1")));
        address signer1 = vm.envAddress("SIGNER1");
        address signer2 = vm.envAddress("SIGNER2");

        vm.startBroadcast(deployerPk);

        VaultV2Factory vf = new VaultV2Factory();
        UniversalAdapterEscrowFactory af = new UniversalAdapterEscrowFactory();

        BaseCoreFactory coreFactory = new BaseCoreFactory(address(vf), address(af));
        BaseExecFactory execFactory = new BaseExecFactory();

        BaseCoreFactory.CoreDeployment memory core = coreFactory.deployCore(
            BaseCoreFactory.CoreParams({
                vaultOwner: owner,
                valuerOwner: valuerOwner,
                asset: usdc,
                salt: keccak256(abi.encode(owner, block.chainid, strategyId)),
                strategyId: strategyId,
                strategyDailyLimit: 1_000_000e6
            })
        );

        address[] memory sigs = new address[](2);
        sigs[0] = signer1;
        sigs[1] = signer2;

        BaseExecFactory.ExecDeployment memory exec = execFactory.deployExec(
            BaseExecFactory.ExecParams({
                vaultOwner: owner,
                asset: usdc,
                vault: core.vault,
                sleeve: core.sleeve,
                gatewaySigners: sigs,
                gatewayThreshold: 2,
                capPmTopUp: 1_000_000e6,
                capHlTopUp: 1_000_000e6,
                capRefillReserve: 10_000_000e6,
                dailyCap: 2_000_000e6,
                gatewayName: "NekoBaseGateway",
                gatewayVersion: "1"
            })
        );

        vm.stopBroadcast();

        console.log("=== Base Custody Stack Deployed ===");
        console.log("VaultV2Factory:      ", address(vf));
        console.log("AdapterFactory:      ", address(af));
        console.log("BaseCoreFactory:     ", address(coreFactory));
        console.log("BaseExecFactory:     ", address(execFactory));
        console.log("");
        console.log("Vault:               ", core.vault);
        console.log("Sleeve:              ", core.sleeve);
        console.log("Valuer:              ", core.valuer);
        console.log("Strategy agent:      ", core.strategyAgent);
        console.log("Module:              ", exec.module);
        console.log("Gateway:             ", exec.gateway);
        console.log("OFT sender:          ", exec.oftSender);
    }
}
