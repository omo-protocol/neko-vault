// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {PtLoopExecutor} from "../src/executors/PtLoopExecutor.sol";
import {PtLoopFactory} from "../src/executors/PtLoopFactory.sol";

/// @notice Deploys the PtLoopExecutor impl + PtLoopFactory on a target execution chain.
///         Run once per chain the operator wants to support (Arb, OP, ETH, ...).
///
///         Env vars:
///           PRIVATE_KEY      - deployer PK (funded with native gas on target chain)
///           USDC             - native USDC address on target chain
///           PENDLE_ROUTER    - Pendle router V4 address (usually 0x8888…8946 cross-chain)
///           FLASH_VAULT      - flash-loan provider (Balancer V2 Vault recommended)
///
///         Output: prints the impl + factory addresses. Add the factory address to the
///         adapter's chain registry (`adapter/src/chains/pt-loop-chains.ts` — either edit the
///         file or set `PT_LOOP_FACTORY_<CHAIN>` env var).
contract DeployPtLoopExecutor is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address usdc = vm.envAddress("USDC");
        address pendleRouter = vm.envAddress("PENDLE_ROUTER");
        address flashVault = vm.envAddress("FLASH_VAULT");

        vm.startBroadcast(deployerPk);
        PtLoopExecutor impl = new PtLoopExecutor();
        PtLoopFactory factory = new PtLoopFactory(address(impl), usdc, pendleRouter, flashVault);
        vm.stopBroadcast();

        console.log("=== PT Loop deployment ===");
        console.log("Chain ID:      ", block.chainid);
        console.log("Executor impl: ", address(impl));
        console.log("Factory:       ", address(factory));
        console.log("USDC:          ", usdc);
        console.log("Pendle router: ", pendleRouter);
        console.log("Flash vault:   ", flashVault);
        console.log("");
        console.log("Add to adapter env:");
        console.log("  PT_LOOP_FACTORY_<CHAIN>=", address(factory));
    }
}
