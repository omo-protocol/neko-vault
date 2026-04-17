// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";

/// @notice Sends native ETH (for LZ messaging fees) to BaseOftSender.
///
///         Env vars:
///           PRIVATE_KEY — sender
///           OFT_SENDER  — BaseOftSender address
///           AMOUNT_WEI  — native amount to send
contract FundOftSender is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address payable sender = payable(vm.envAddress("OFT_SENDER"));
        uint256 amount = vm.envUint("AMOUNT_WEI");

        vm.startBroadcast(pk);
        (bool ok,) = sender.call{value: amount}("");
        require(ok, "native transfer failed");
        vm.stopBroadcast();

        console.log("Funded BaseOftSender with", amount, "wei");
    }
}
