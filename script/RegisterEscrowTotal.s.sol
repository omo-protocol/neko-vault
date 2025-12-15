// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

struct Call {
    address target;
    bytes data;
    uint256 value;
}

interface IUniversalAdapterEscrow {
    function updateWhitelist(address target, bytes4 selector, bool allowed, uint256 limit) external;
    function executeStrategy(bytes32 strategyId, Call[] calldata calls) external;
    function owner() external view returns (address);
}

interface IUniversalValuerOffchain {
    function registerEscrowTotal(bytes32 totalId) external;
    function getRegisteredEscrow(bytes32 id) external view returns (address);
}

contract RegisterEscrowTotalScript is Script {
    address constant ESCROW = 0x7F73B9AA1f5a6cE9bBfc8F0c12889b3Cb75174e8;
    address constant VALUER = 0x7f7b37A897EF5331262a9A6a5F60078BcfbF58Cc;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);
        console.log("Escrow:", ESCROW);
        console.log("Valuer:", VALUER);

        // Calculate ESCROW_TOTAL_ID
        bytes32 escrowTotalId = keccak256(abi.encodePacked("ESCROW_TOTAL", ESCROW));
        console.log("ESCROW_TOTAL_ID:");
        console.logBytes32(escrowTotalId);

        // Check current registration
        IUniversalAdapterEscrow escrow = IUniversalAdapterEscrow(ESCROW);

        console.log("Escrow owner:", escrow.owner());
        require(escrow.owner() == deployer, "Deployer is not escrow owner");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Whitelist registerEscrowTotal on valuer
        bytes4 selector = IUniversalValuerOffchain.registerEscrowTotal.selector;
        console.log("Whitelisting selector:");
        console.logBytes4(selector);

        escrow.updateWhitelist(VALUER, selector, true, 0);
        console.log("Whitelisted registerEscrowTotal on valuer");

        // Step 2: Call registerEscrowTotal via executeStrategy
        // Use existing strategy "pt-khype-looper"
        bytes32 strategyId = keccak256(abi.encodePacked("pt-khype-looper"));
        console.log("Using strategyId:");
        console.logBytes32(strategyId);

        bytes memory callData = abi.encodeWithSelector(
            IUniversalValuerOffchain.registerEscrowTotal.selector,
            escrowTotalId
        );

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: VALUER,
            data: callData,
            value: 0
        });

        escrow.executeStrategy(strategyId, calls);
        console.log("Called registerEscrowTotal via executeStrategy");

        // Step 3: Optionally remove whitelist (security: don't leave it open)
        escrow.updateWhitelist(VALUER, selector, false, 0);
        console.log("Removed whitelist for registerEscrowTotal");

        vm.stopBroadcast();

        console.log("SUCCESS: ESCROW_TOTAL registered on valuer");
    }
}
