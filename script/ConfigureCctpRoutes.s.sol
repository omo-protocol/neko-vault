// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {BaseCctpSender} from "../src/base/BaseCctpSender.sol";

/// @notice Post-deploy: configure CCTP routes on BaseCctpSender.
///
///         CCTP V2 domains: Ethereum=0, Avalanche=1, OP=2, Arbitrum=3, Base=6, Polygon=7, HyperEVM=19.
///         Finality thresholds: 1000 = standard, 2000 = fast.
///
///         Env vars:
///           PRIVATE_KEY              — vaultOwner (CCTP sender owner)
///           CCTP_SENDER              — BaseCctpSender address
///
///           PM_DEST_REF              — bytes32 (e.g. keccak256("dest:pm"))
///           PM_DOMAIN                — 7 (Polygon)
///           PM_RECIPIENT             — PM-registered wallet on Polygon (address)
///
///           HL_DEST_REF              — bytes32 (e.g. keccak256("dest:hl"))
///           HL_DOMAIN                — 19 (HyperEVM)
///           HL_RECIPIENT             — HyperEVM address that forwards USDC to HyperCore system addr
///
///         Optional:
///           PM_MAX_FEE, HL_MAX_FEE         (default 0 = standard transfer)
///           PM_FINALITY, HL_FINALITY       (default 1000 = standard; 2000 for CCTP Fast)
///           HL_HOOK_DATA                   (hex bytes; set when routing to HL via Circle's
///                                           CctpForwarder on HyperEVM → HyperCore). Empty = plain
///                                           mint to the mintRecipient address.
contract ConfigureCctpRoutes is Script {
    function run() external {
        uint256 ownerPk = vm.envUint("PRIVATE_KEY");
        BaseCctpSender sender = BaseCctpSender(payable(vm.envAddress("CCTP_SENDER")));

        bytes32 pmDestRef = vm.envBytes32("PM_DEST_REF");
        uint32 pmDomain = uint32(vm.envUint("PM_DOMAIN"));
        address pmRecipient = vm.envAddress("PM_RECIPIENT");
        uint256 pmMaxFee = vm.envOr("PM_MAX_FEE", uint256(0));
        uint32 pmFinality = uint32(vm.envOr("PM_FINALITY", uint256(1000)));

        bytes32 hlDestRef = vm.envBytes32("HL_DEST_REF");
        uint32 hlDomain = uint32(vm.envUint("HL_DOMAIN"));
        address hlRecipient = vm.envAddress("HL_RECIPIENT");
        uint256 hlMaxFee = vm.envOr("HL_MAX_FEE", uint256(0));
        uint32 hlFinality = uint32(vm.envOr("HL_FINALITY", uint256(1000)));
        bytes memory hlHookData = vm.envOr("HL_HOOK_DATA", bytes(""));

        vm.startBroadcast(ownerPk);

        sender.configureRoute(
            pmDestRef,
            BaseCctpSender.Route({
                destinationDomain: pmDomain,
                mintRecipient: bytes32(uint256(uint160(pmRecipient))),
                maxFee: pmMaxFee,
                minFinalityThreshold: pmFinality,
                hookData: bytes(""),
                active: true
            })
        );

        sender.configureRoute(
            hlDestRef,
            BaseCctpSender.Route({
                destinationDomain: hlDomain,
                mintRecipient: bytes32(uint256(uint160(hlRecipient))),
                maxFee: hlMaxFee,
                minFinalityThreshold: hlFinality,
                hookData: hlHookData,
                active: true
            })
        );

        vm.stopBroadcast();

        console.log("PM route configured: destRef=", uint256(pmDestRef));
        console.log("HL route configured: destRef=", uint256(hlDestRef));
    }
}
