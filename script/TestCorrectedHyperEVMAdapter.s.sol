// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IPendleSwap {
    function swapExactTokenForPt(address,address,uint256) external returns (uint256);
    function swapTokenForPt(address,uint256,uint256) external returns (uint256);
    function tokenForPt(address,uint256) external returns (uint256);
}

contract TestCorrectedHyperEVMAdapter is Script {
    
    address constant PENDLE_SWAP = 0xd4F480965D2347d421F1bEC7F545682E5Ec2151D;
    address constant KHYPE = 0xfD739d4e423301CE9385c1fb8850539D657C296D;
    address constant MARKET = 0x8867d2b7aDb8609c51810237EcC9A25A2F601B97;
    address constant PT_TOKEN = 0x311dB0FDe558689550c68355783c95eFDfe25329;
    
    uint256 constant TEST_AMOUNT = 5000000000000;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("=== TESTING PENDLE SWAP DIRECTLY ===");
        console.log("PendleSwap:", PENDLE_SWAP);
        console.log("Test amount:", TEST_AMOUNT);
        
        vm.startBroadcast(deployerPrivateKey);
        
        address deployer = vm.addr(deployerPrivateKey);
        
        uint256 balance = IERC20(KHYPE).balanceOf(deployer);
        console.log("kHYPE balance:", balance);
        
        if (balance < TEST_AMOUNT) {
            console.log("Insufficient balance");
            vm.stopBroadcast();
            return;
        }
        
        // Approve PendleSwap
        IERC20(KHYPE).approve(PENDLE_SWAP, TEST_AMOUNT);
        console.log("Approved PendleSwap");
        
        // Check PT balance before
        uint256 ptBefore = IERC20(PT_TOKEN).balanceOf(deployer);
        console.log("PT balance before:", ptBefore);
        
        // Test different function signatures
        console.log("Testing simple functions...");
        
        // Test 1: Try swapExactTokenForPt with 3 params
        try IPendleSwap(PENDLE_SWAP).swapExactTokenForPt(MARKET, deployer, TEST_AMOUNT) returns (uint256 ptOut) {
            console.log("SUCCESS: swapExactTokenForPt(3 params) - PT out:", ptOut);
        } catch Error(string memory reason) {
            console.log("Failed swapExactTokenForPt(3 params):", reason);
        } catch (bytes memory data) {
            console.log("Failed swapExactTokenForPt(3 params) - bytes:");
            console.logBytes(data);
        }
        
        // Test 2: Try swapTokenForPt
        try IPendleSwap(PENDLE_SWAP).swapTokenForPt(MARKET, TEST_AMOUNT, TEST_AMOUNT * 80 / 100) returns (uint256 ptOut) {
            console.log("SUCCESS: swapTokenForPt - PT out:", ptOut);
        } catch Error(string memory reason) {
            console.log("Failed swapTokenForPt:", reason);
        } catch (bytes memory data) {
            console.log("Failed swapTokenForPt - bytes:");
            console.logBytes(data);
        }
        
        // Test 3: Try tokenForPt
        try IPendleSwap(PENDLE_SWAP).tokenForPt(KHYPE, TEST_AMOUNT) returns (uint256 ptOut) {
            console.log("SUCCESS: tokenForPt - PT out:", ptOut);
        } catch Error(string memory reason) {
            console.log("Failed tokenForPt:", reason);
        } catch (bytes memory data) {
            console.log("Failed tokenForPt - bytes:");
            console.logBytes(data);
        }
        
        // Check PT balance after
        uint256 ptAfter = IERC20(PT_TOKEN).balanceOf(deployer);
        console.log("PT balance after:", ptAfter);
        console.log("PT gained:", ptAfter - ptBefore);
        
        vm.stopBroadcast();
    }
}