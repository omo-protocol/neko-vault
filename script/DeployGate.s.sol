// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/gates/EmergencyGateWithRoles.sol";

/**
 * @title DeployGate
 * @notice Deploys the EmergencyGateWithRoles contract
 *
 * Usage:
 *   PRIVATE_KEY=0x... VAULT=0x... OWNER=0x... MODE=2 forge script script/DeployGate.s.sol --rpc-url <RPC_URL> --broadcast -v
 *
 * Modes:
 *   0 = INACTIVE
 *   1 = DEPOSIT_ONLY
 *   2 = WITHDRAWAL_ONLY
 *   3 = EMERGENCY (all blocked)
 */
contract DeployGate is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address vault = vm.envAddress("VAULT");
        address owner = vm.envAddress("OWNER");
        uint8 mode = uint8(vm.envUint("MODE"));

        console.log("Deploying EmergencyGateWithRoles");
        console.log("Vault:", vault);
        console.log("Owner:", owner);
        console.log("Mode:", mode);

        vm.startBroadcast(deployerPrivateKey);

        EmergencyGateWithRoles gate = new EmergencyGateWithRoles(
            vault,
            owner,
            EmergencyGateWithRoles.Mode(mode)
        );
        console.log("EmergencyGateWithRoles deployed:", address(gate));

        vm.stopBroadcast();
    }
}
