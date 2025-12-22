// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/gates/EmergencyGateWithRoles.sol";

/**
 * @title DeployGate
 * @notice Deploys the EmergencyGateWithRoles contract
 *
 * Usage:
 *   PRIVATE_KEY=0x... VAULT=0x... OWNER=0x... MODE=0 forge script script/DeployGate.s.sol --rpc-url <RPC_URL> --broadcast -v
 *
 * Modes:
 *   0 = NORMAL            (all operations allowed)
 *   1 = DEPOSITS_PAUSED   (deposits blocked, withdrawals allowed)
 *   2 = WITHDRAWALS_PAUSED (withdrawals blocked, deposits allowed)
 *   3 = EMERGENCY         (all operations blocked)
 */
contract DeployGate is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address vault = 0xe2d5dDeB54153152DD01e98045cC412115c92F15;
        address owner = vm.addr(deployerPrivateKey);
        uint8 mode = 0;

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
