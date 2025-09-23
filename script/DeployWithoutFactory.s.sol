// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/VaultV2.sol";
import "../src/adapters/UniversalEscrowAdapter.sol";
import "../src/adapters/StrategyEscrow.sol";  // Using updated StrategyEscrow
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IStrategyEscrow} from "../src/adapters/interfaces/IStrategyEscrow.sol";

contract DeployWithoutFactory is Script {
    address constant KHYPE = 0xfD739d4e423301CE9385c1fb8850539D657C296D;
    address constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;

    bytes32 constant PT_KHYPE_LOOP_ID = keccak256("pt-khype-loop");
    uint256 constant DEPOSIT_AMOUNT = 0.001 ether;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("\n========================================");
        console.log("=== DEPLOY WITHOUT FACTORY ===");
        console.log("========================================");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy vault
        console.log("\n1. DEPLOYING VAULT:");
        VaultV2 vault = new VaultV2(deployer, KHYPE);
        console.log("   Vault:", address(vault));
        vault.setCurator(deployer);

        // Step 2: Deploy valuer
        console.log("\n2. DEPLOYING VALUER:");
        SimpleValuer valuer = new SimpleValuer();
        console.log("   Valuer:", address(valuer));

        // Step 3: MANUAL CIRCULAR DEPENDENCY SOLUTION
        console.log("\n3. SOLVING CIRCULAR DEPENDENCY MANUALLY:");

        // Step 3a: Deploy escrow with owner only (new constructor)
        // The escrow doesn't know about adapter yet
        StrategyEscrow escrow = new StrategyEscrow(address(0), deployer);
        console.log("   Escrow deployed:", address(escrow));

        // Step 3b: Deploy adapter pointing to escrow
        // Adapter knows the escrow address
        UniversalEscrowAdapter adapter = new UniversalEscrowAdapter(
            address(vault),
            address(escrow),
            address(valuer),
            true
        );
        console.log("   Adapter deployed:", address(adapter));

        // Step 3c: Set adapter in escrow (this is the key!)
        // Now escrow knows the adapter
        escrow.setAdapter(address(adapter));
        console.log("   Adapter set in escrow");

        // Step 3d: Verify linkage
        console.log("\n4. VERIFYING LINKAGE:");
        console.log("   Escrow.adapter:", escrow.adapter());
        console.log("   Adapter.escrow:", adapter.escrow());
        console.log("   Linkage correct:", escrow.adapter() == address(adapter));
        console.log("   Adapter locked:", escrow.adapterLocked());

        // Step 4: Configure escrow
        console.log("\n5. CONFIGURING ESCROW:");
        escrow.setStrategyAgent(PT_KHYPE_LOOP_ID, deployer);
        escrow.updateWhitelist(KHYPE, bytes4(keccak256("approve(address,uint256)")), true, 100 ether);
        escrow.updateWhitelist(PENDLE_ROUTER, bytes4(0), true, 100 ether);
        console.log("   Configured for Pendle");

        // Step 5: Setup vault
        console.log("\n6. SETTING UP VAULT:");

        // Set allocator
        bytes memory allocatorData = abi.encodeWithSignature("setIsAllocator(address,bool)", deployer, true);
        vault.submit(allocatorData);
        vault.setIsAllocator(deployer, true);
        console.log("   Allocator set");

        // Add adapter
        bytes memory adapterData = abi.encodeWithSignature("addAdapter(address)", address(adapter));
        vault.submit(adapterData);
        vault.addAdapter(address(adapter));
        console.log("   Adapter registered");

        // Set caps
        bytes memory capIdData = bytes("pt-khype-loop");
        bytes memory capData = abi.encodeWithSignature(
            "increaseAbsoluteCap(bytes,uint256)",
            capIdData,
            10 ether
        );
        vault.submit(capData);
        vault.increaseAbsoluteCap(capIdData, 10 ether);
        console.log("   Cap set");

        // Step 6: Deposit and allocate
        console.log("\n7. DEPOSIT AND ALLOCATE:");

        IERC20 khype = IERC20(KHYPE);

        // Deposit
        if (khype.balanceOf(deployer) >= DEPOSIT_AMOUNT) {
            khype.approve(address(vault), DEPOSIT_AMOUNT);
            uint256 shares = vault.deposit(DEPOSIT_AMOUNT, deployer);
            console.log("   Deposited:", DEPOSIT_AMOUNT);
            console.log("   Shares:", shares);

            // Allocate
            IStrategyEscrow.Call[] memory calls = new IStrategyEscrow.Call[](0);
            bytes memory escrowCallData = abi.encode(calls);
            bytes memory allocationData = abi.encode(PT_KHYPE_LOOP_ID, DEPOSIT_AMOUNT, escrowCallData);

            try vault.allocate(address(adapter), allocationData, DEPOSIT_AMOUNT) {
                uint256 escrowBalance = khype.balanceOf(address(escrow));
                console.log("   [SUCCESS] Allocated:", DEPOSIT_AMOUNT);
                console.log("   Escrow balance:", escrowBalance);

                // Approve Pendle
                if (escrowBalance > 0) {
                    IStrategyEscrow.Call[] memory pendleCalls = new IStrategyEscrow.Call[](1);
                    pendleCalls[0] = IStrategyEscrow.Call({
                        target: KHYPE,
                        value: 0,
                        data: abi.encodeWithSignature("approve(address,uint256)", PENDLE_ROUTER, escrowBalance)
                    });
                    escrow.executeMulticall(PT_KHYPE_LOOP_ID, pendleCalls);
                    console.log("   Pendle approved!");
                }
            } catch Error(string memory reason) {
                console.log("   [ERROR]", reason);
            }
        }

        // Summary
        console.log("\n========================================");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("========================================");
        console.log("Deployed without factory by:");
        console.log("  1. Deploying StrategyEscrowV2 (without adapter)");
        console.log("  2. Deploying UniversalEscrowAdapter(escrow)");
        console.log("  3. Calling escrow.setAdapter(adapter)");
        console.log("  4. Adapter is now locked in escrow");
        console.log("\nFinal Contracts:");
        console.log("  Vault:", address(vault));
        console.log("  Adapter:", address(adapter));
        console.log("  Escrow:", address(escrow));

        vm.stopBroadcast();

        console.log("\n=== SUCCESS WITHOUT FACTORY! ===");
    }
}

contract SimpleValuer {
    function getTotalValue(address escrow) external view returns (uint256) {
        return IERC20(0xfD739d4e423301CE9385c1fb8850539D657C296D).balanceOf(escrow);
    }
}