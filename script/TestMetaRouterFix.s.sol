// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract TestMetaRouterFix is Script {
    
    // From 999-core.json
    address constant PENDLE_SWAP = 0xd4F480965D2347d421F1bEC7F545682E5Ec2151D;
    address constant MAIN_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant KHYPE = 0xfD739d4e423301CE9385c1fb8850539D657C296D;
    
    uint256 constant TEST_AMOUNT = 5000000000000;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("=== TESTING PENDLE SWAP ROUTER ===");
        console.log("PendleSwap address:", PENDLE_SWAP);
        
        vm.startBroadcast(deployerPrivateKey);
        
        address deployer = vm.addr(deployerPrivateKey);
        
        uint256 balance = IERC20(KHYPE).balanceOf(deployer);
        console.log("kHYPE balance:", balance);
        
        if (balance < TEST_AMOUNT) {
            console.log("Insufficient balance");
            vm.stopBroadcast();
            return;
        }
        
        // Test basic function existence
        console.log("Testing basic function calls...");
        
        // Test 1: Check if PendleSwap responds to simple calls
        try this.testBasicCall(PENDLE_SWAP) {
            console.log("PendleSwap responds to calls");
        } catch {
            console.log("PendleSwap doesn't respond to basic calls");
        }
        
        // Test 2: Try approving the PendleSwap
        try IERC20(KHYPE).approve(PENDLE_SWAP, TEST_AMOUNT) returns (bool success) {
            console.log("Approval to PendleSwap:", success);
        } catch {
            console.log("Failed to approve PendleSwap");
        }
        
        // Test 3: Try a simple swap selector
        bytes4 swapSelector = bytes4(keccak256("swapExactTokenForPt(address,address,uint256)"));
        console.log("Simple swap selector:", vm.toString(swapSelector));
        
        vm.stopBroadcast();
        
        console.log("Tests completed. Next: Update adapter to use PendleSwap");
    }
    
    function testBasicCall(address target) external view {
        // Try a static call to see if contract responds
        (bool success,) = target.staticcall(abi.encodeWithSignature("factory()"));
        if (!success) {
            (success,) = target.staticcall(abi.encodeWithSignature("owner()"));
        }
        require(success, "No response");
    }
}