// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/adapters/UniversalAdapterEscrow.sol";

/**
 * @title ConfigureWhitelists
 * @notice Configure function whitelists for PT-kHYPE strategy
 */
contract ConfigureWhitelists is Script {
    UniversalAdapterEscrow adapter = UniversalAdapterEscrow(payable(0x5Bc418252Fd72b4dF7feCc297caF50B23f9Ee6cA));

    address constant KHYPE = 0xfD739d4e423301CE9385c1fb8850539D657C296D;
    address constant PT_KHYPE = 0x311dB0FDe558689550c68355783c95eFDfe25329;
    address constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant FELIX_MORPHO = 0x68e37dE8d93d3496ae143F2E900490f6280C57cD;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console.log("\n================================================================");
        console.log("    CONFIGURE WHITELISTS");
        console.log("================================================================");
        console.log("Adapter:", address(adapter));

        vm.startBroadcast(deployerPrivateKey);

        // Token approvals
        console.log("\n[1/3] Whitelisting token approvals...");
        adapter.updateWhitelist(KHYPE, bytes4(keccak256("approve(address,uint256)")), true, 0);
        console.log("  \u2713 kHYPE.approve");

        adapter.updateWhitelist(PT_KHYPE, bytes4(keccak256("approve(address,uint256)")), true, 0);
        console.log("  \u2713 PT-kHYPE.approve");

        // Pendle functions
        console.log("\n[2/3] Whitelisting Pendle functions...");
        adapter.updateWhitelist(PENDLE_ROUTER, bytes4(keccak256("swapExactTokenForPt(address,address,uint256,tuple,tuple,tuple)")), true, 10_000e18);
        console.log("  \u2713 Pendle.swapExactTokenForPt");

        adapter.updateWhitelist(PENDLE_ROUTER, bytes4(keccak256("swapExactPtForToken(address,address,uint256,tuple,tuple)")), true, 10_000e18);
        console.log("  \u2713 Pendle.swapExactPtForToken");

        // Felix functions
        console.log("\n[3/3] Whitelisting Felix functions...");
        adapter.updateWhitelist(FELIX_MORPHO, bytes4(keccak256("supply(tuple,uint256,uint256,address,bytes)")), true, 10_000e18);
        console.log("  \u2713 Felix.supply");

        adapter.updateWhitelist(FELIX_MORPHO, bytes4(keccak256("borrow(tuple,uint256,uint256,address,address)")), true, 10_000e18);
        console.log("  \u2713 Felix.borrow");

        adapter.updateWhitelist(FELIX_MORPHO, bytes4(keccak256("repay(tuple,uint256,uint256,address,bytes)")), true, 10_000e18);
        console.log("  \u2713 Felix.repay");

        adapter.updateWhitelist(FELIX_MORPHO, bytes4(keccak256("withdraw(tuple,uint256,uint256,address,address)")), true, 10_000e18);
        console.log("  \u2713 Felix.withdraw");

        vm.stopBroadcast();

        console.log("\n  \u2713\u2713\u2713 WHITELISTS CONFIGURED \u2713\u2713\u2713");
        console.log("\n================================================================");
        console.log("    CONFIGURATION COMPLETE");
        console.log("================================================================\n");
    }
}