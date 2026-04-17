// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {HyperLiquidComposer} from "@layerzerolabs/hyperliquid-composer/contracts/HyperLiquidComposer.sol";

/// @notice Deploys LayerZero's vendored `HyperLiquidComposer` on HyperEVM. This is the destination
///         contract for Base → HyperEVM OFT sends; it decodes the 64-byte compose message
///         (`abi.encode(minMsgValue, hlCoreReceiver)`) and spot-sends USDC to the specified
///         HyperCore account via the SpotSend precompile.
///
///         After deploy, use the returned address as the `recipient` in `BaseOftSender.configureRoute`
///         for the HL route. Populate `hlCoreReceiver` on the route with the HyperCore account
///         that should receive the funds.
///
///         Env vars (required):
///           PRIVATE_KEY       — deployer
///           OFT_USDC          — USDC OFT adapter on HyperEVM
///           HL_CORE_INDEX     — HyperCore asset index for USDC (uint64, from HL docs)
///           HL_DECIMAL_DIFF   — int8 EVM↔Core decimal delta (e.g. 0 when both are 6-decimal)
contract DeployHyperLiquidComposer is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address oft = vm.envAddress("OFT_USDC");
        uint64 coreIndex = uint64(vm.envUint("HL_CORE_INDEX"));
        int8 decimalDiff = int8(uint8(vm.envUint("HL_DECIMAL_DIFF")));

        vm.startBroadcast(deployerPk);
        HyperLiquidComposer composer = new HyperLiquidComposer(oft, coreIndex, decimalDiff);
        vm.stopBroadcast();

        console.log("=== HyperLiquidComposer deployed on HyperEVM ===");
        console.log("Composer:      ", address(composer));
        console.log("OFT:           ", oft);
        console.log("CoreIndex:     ", uint256(coreIndex));
        console.log("DecimalDiff:   ", int256(decimalDiff));
        console.log("");
        console.log("Next on Base:");
        console.log("  oftSender.configureRoute(HL_DEST_REF, Route({");
        console.log("    oft: <base-side USDC OFT>,");
        console.log("    dstEid: <HyperEVM EID>,");
        console.log("    recipient: bytes32(uint256(uint160(<this composer>))),");
        console.log("    extraOptions: <LZ compose options with gas>,");
        console.log("    hlCoreReceiver: <HL Core account>,");
        console.log("    active: true");
        console.log("  }))");
    }
}
