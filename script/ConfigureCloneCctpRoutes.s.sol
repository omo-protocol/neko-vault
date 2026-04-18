// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {BaseCctpSender} from "../src/base/BaseCctpSender.sol";

/// @notice Per-vault CCTP route configuration. Run once per clone after `execFactory.deployExec`.
///         Each vault owns its own BaseCctpSender (one-per-clone, not shared), so the routes
///         here only affect this caller's vault. Called by the vaultOwner.
///
///         CCTP V2 domains: Base=6, Polygon=7, HyperEVM=19.
///
///         Env vars:
///           PRIVATE_KEY   — vault owner (sender owner)
///           CCTP_SENDER   — this vault's BaseCctpSender
///           PM_WALLET     — this user's Polymarket API wallet address on Polygon
///           HL_WALLET     — this user's HL trading wallet address on HyperEVM
///
///         Optional:
///           PM_MAX_FEE    (default 0 = standard transfer)
///           HL_MAX_FEE    (default 0 = standard transfer)
///           PM_FINALITY   (default 1000 = standard; 2000 = fast)
///           HL_FINALITY   (default 1000 = standard; 2000 = fast)
contract ConfigureCloneCctpRoutes is Script {
    function run() external {
        uint256 ownerPk = vm.envUint("PRIVATE_KEY");
        BaseCctpSender sender = BaseCctpSender(payable(vm.envAddress("CCTP_SENDER")));
        address pmWallet = vm.envAddress("PM_WALLET");
        address hlWallet = vm.envAddress("HL_WALLET");
        uint256 pmMaxFee = vm.envOr("PM_MAX_FEE", uint256(0));
        uint256 hlMaxFee = vm.envOr("HL_MAX_FEE", uint256(0));
        uint32 pmFinality = uint32(vm.envOr("PM_FINALITY", uint256(1000)));
        uint32 hlFinality = uint32(vm.envOr("HL_FINALITY", uint256(1000)));

        bytes32 pmDestRef = keccak256("dest:pm");
        bytes32 hlDestRef = keccak256("dest:hl");

        vm.startBroadcast(ownerPk);

        sender.configureRoute(
            pmDestRef,
            BaseCctpSender.Route({
                destinationDomain: 7,
                mintRecipient: bytes32(uint256(uint160(pmWallet))),
                maxFee: pmMaxFee,
                minFinalityThreshold: pmFinality,
                hookData: bytes(""),
                active: true
            })
        );

        sender.configureRoute(
            hlDestRef,
            BaseCctpSender.Route({
                destinationDomain: 19,
                mintRecipient: bytes32(uint256(uint160(hlWallet))),
                maxFee: hlMaxFee,
                minFinalityThreshold: hlFinality,
                hookData: bytes(""),
                active: true
            })
        );

        vm.stopBroadcast();

        console.log("Clone CCTP routes configured on:", address(sender));
        console.log("PM route (domain 7) -> %s", pmWallet);
        console.log("HL route (domain 19) -> %s", hlWallet);
    }
}
