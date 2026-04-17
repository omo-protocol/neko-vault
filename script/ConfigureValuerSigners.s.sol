// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {UniversalValuerOffchain} from "../src/valuers/UniversalValuerOffchain.sol";

/// @notice Post-deploy: register signers on UniversalValuerOffchain. Run as valuerOwner.
///
///         Env vars (required):
///           PRIVATE_KEY         — valuerOwner (e.g. adapter's Base EOA)
///           VALUER              — UniversalValuerOffchain address
///           SIGNER_ADDRESS      — the signer EOA to authorize (typically the adapter's dKMS EOA itself)
///           SIGNER_WEIGHT       — signer's weight (e.g. 1)
///           REQUIRED_WEIGHT     — threshold required to accept a value update (e.g. 1 for single-sig)
contract ConfigureValuerSigners is Script {
    function run() external {
        uint256 ownerPk = vm.envUint("PRIVATE_KEY");
        UniversalValuerOffchain valuer = UniversalValuerOffchain(vm.envAddress("VALUER"));
        address signer = vm.envAddress("SIGNER_ADDRESS");
        uint256 weight = vm.envUint("SIGNER_WEIGHT");
        uint256 required = vm.envUint("REQUIRED_WEIGHT");

        vm.startBroadcast(ownerPk);
        valuer.initiateSignerChange(signer, true, weight);
        valuer.setRequiredWeight(required);
        vm.stopBroadcast();

        console.log("Valuer signer configured:", signer);
        console.log("  weight:         ", weight);
        console.log("  requiredWeight: ", required);
    }
}
