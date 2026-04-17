// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {BaseOftSender} from "../src/base/BaseOftSender.sol";

/// @notice Post-deploy: configure OFT routes on BaseOftSender. Run after BaseCustodyFactory.deploy.
///
///         Env vars (required):
///           PRIVATE_KEY            — vaultOwner (OFT sender owner)
///           OFT_SENDER             — address of BaseOftSender
///           USDC_OFT               — USDC OFT adapter on Base
///
///           PM_DEST_REF            — bytes32 (e.g. keccak256("dest:pm-rail"))
///           PM_DST_EID             — Polygon LZ EID (e.g. 30109)
///           PM_RECIPIENT           — operator EOA on Polygon (address)
///
///           HL_DEST_REF            — bytes32
///           HL_DST_EID             — HyperEVM LZ EID (e.g. 30316)
///           HL_COMPOSER            — HyperLiquidComposer address on HyperEVM
///           HL_CORE_RECEIVER       — HyperCore spot account to receive USDC
///
///         Optional:
///           PM_SLIPPAGE_BPS (default 0), HL_SLIPPAGE_BPS (default 0)
///           PM_EXTRA_OPTIONS, HL_EXTRA_OPTIONS (hex-encoded bytes; default empty)
contract ConfigureOftRoutes is Script {
    function run() external {
        uint256 ownerPk = vm.envUint("PRIVATE_KEY");
        BaseOftSender sender = BaseOftSender(payable(vm.envAddress("OFT_SENDER")));
        address oft = vm.envAddress("USDC_OFT");

        // PM route
        bytes32 pmDestRef = vm.envBytes32("PM_DEST_REF");
        uint32 pmDstEid = uint32(vm.envUint("PM_DST_EID"));
        address pmRecipient = vm.envAddress("PM_RECIPIENT");
        uint16 pmSlippage = uint16(vm.envOr("PM_SLIPPAGE_BPS", uint256(0)));
        bytes memory pmExtra = vm.envOr("PM_EXTRA_OPTIONS", bytes(""));

        // HL route
        bytes32 hlDestRef = vm.envBytes32("HL_DEST_REF");
        uint32 hlDstEid = uint32(vm.envUint("HL_DST_EID"));
        address hlComposer = vm.envAddress("HL_COMPOSER");
        address hlCoreReceiver = vm.envAddress("HL_CORE_RECEIVER");
        uint16 hlSlippage = uint16(vm.envOr("HL_SLIPPAGE_BPS", uint256(0)));
        bytes memory hlExtra = vm.envOr("HL_EXTRA_OPTIONS", bytes(""));

        vm.startBroadcast(ownerPk);

        sender.configureRoute(
            pmDestRef,
            BaseOftSender.Route({
                oft: oft,
                dstEid: pmDstEid,
                recipient: bytes32(uint256(uint160(pmRecipient))),
                extraOptions: pmExtra,
                hlCoreReceiver: address(0),
                slippageBps: pmSlippage,
                active: true
            })
        );

        sender.configureRoute(
            hlDestRef,
            BaseOftSender.Route({
                oft: oft,
                dstEid: hlDstEid,
                recipient: bytes32(uint256(uint160(hlComposer))),
                extraOptions: hlExtra,
                hlCoreReceiver: hlCoreReceiver,
                slippageBps: hlSlippage,
                active: true
            })
        );

        vm.stopBroadcast();

        console.log("PM route configured: destRef=", uint256(pmDestRef));
        console.log("HL route configured: destRef=", uint256(hlDestRef));
    }
}
