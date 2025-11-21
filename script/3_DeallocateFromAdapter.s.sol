// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/VaultV2.sol";
import "../src/adapters/UniversalAdapterEscrow.sol";
import {IUniversalAdapterEscrow} from "../src/adapters/interfaces/IUniversalAdapterEscrow.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

/**
 * @title DeallocateFromAdapter
 * @notice Deallocate funds from an adapter strategy back to the vault
 * @dev This script deallocates funds from the alm-whype-sthype strategy
 *
 * Usage:
 *   PRIVATE_KEY=0x... \
 *   VAULT_ADDRESS=0x... \
 *   ADAPTER_ADDRESS=0x... \
 *   AMOUNT=1000000000000000000 \
 *   forge script script/3_DeallocateFromAdapter.s.sol --rpc-url <RPC_URL> --broadcast -v
 *
 * Optional:
 *   DEALLOCATE_ALL=true  # Deallocate entire allocation
 */
contract DeallocateFromAdapter is Script {
    // Strategy ID for ALM WHYPE-stHYPE
    bytes32 constant ALM_WHYPE_STHYPE_ID = keccak256("alm-whype-sthype");

    function run() public {
        // Load configuration from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address vaultAddress = 0x52463983595Bec55bd3b50eA98e48F285d12Cca7; // vm.envAddress("VAULT_ADDRESS");
        address adapterAddress = 0xE7537bB191a6FfcD73eED7b2e720F5918Ba7E7E8; // vm.envAddress("ADAPTER_ADDRESS");

        // Amount to deallocate (in wei)
        uint256 amount = vm.envOr("AMOUNT", uint256(0));
        bool deallocateAll = vm.envOr("DEALLOCATE_ALL", true);

        require(vaultAddress != address(0), "VAULT_ADDRESS must be set");
        require(adapterAddress != address(0), "ADAPTER_ADDRESS must be set");

        VaultV2 vault = VaultV2(vaultAddress);
        UniversalAdapterEscrow adapter = UniversalAdapterEscrow(payable(adapterAddress));

        // Verify deployer is an allocator
        require(vault.isAllocator(deployer), "Deployer must be an allocator");
        require(vault.isAdapter(adapterAddress), "Adapter not registered in vault");

        console.log("\n================================================================");
        console.log("    DEALLOCATE FROM ADAPTER");
        console.log("================================================================");
        console.log("Deployer:", deployer);
        console.log("Vault:", vaultAddress);
        console.log("Adapter:", adapterAddress);
        console.log("Strategy ID: alm-whype-sthype");

        // Get current state
        uint256 currentAllocation = adapter.allocations(ALM_WHYPE_STHYPE_ID);
        uint256 adapterBalance = IERC20(vault.asset()).balanceOf(adapterAddress);
        uint256 vaultBalance = IERC20(vault.asset()).balanceOf(vaultAddress);

        console.log("\nCurrent State:");
        console.log("  Current allocation:", currentAllocation);
        console.log("  Adapter balance:", adapterBalance);
        console.log("  Vault balance:", vaultBalance);

        // Determine amount to deallocate
        if (deallocateAll) {
            amount = currentAllocation;
            console.log("\n[MODE] Deallocating ALL funds");
        } else {
            require(amount > 0, "AMOUNT must be set or use DEALLOCATE_ALL=true");
            require(amount <= currentAllocation, "Amount exceeds current allocation");
            console.log("\n[MODE] Deallocating specific amount");
        }

        console.log("  Amount to deallocate:", amount);

        if (amount == 0) {
            console.log("\n[INFO] No funds to deallocate (allocation is 0)");
            return;
        }

        vm.startBroadcast(deployerPrivateKey);

        // ======================================================================
        // DEALLOCATE
        // ======================================================================
        console.log("\n[EXECUTING] Deallocating from strategy...");

        // Prepare deallocate data
        // Format: (bytes32 strategyId, uint256 amount, bool executeNow, Call[] withdrawCalls)
        // For simple deallocation from idle balance, we use empty Call array
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = new IUniversalAdapterEscrow.Call[](0);

        bytes memory deallocData = abi.encode(
            ALM_WHYPE_STHYPE_ID,  // strategyId
            amount,                // amount to deallocate
            false,                 // executeNow (not used in deallocate)
            withdrawCalls          // empty calls - will withdraw from adapter balance
        );

        // Execute deallocation
        try vault.deallocate(adapterAddress, deallocData, amount) {
            console.log("  \u2713 Deallocation successful");
        } catch Error(string memory reason) {
            console.log("  \u2717 Deallocation failed:", reason);
            vm.stopBroadcast();
            revert(reason);
        } catch (bytes memory lowLevelData) {
            console.log("  \u2717 Deallocation failed with low-level error");
            console.logBytes(lowLevelData);
            vm.stopBroadcast();
            revert("Deallocation failed");
        }

        vm.stopBroadcast();

        // ======================================================================
        // VERIFY FINAL STATE
        // ======================================================================
        console.log("\n================================================================");
        console.log("    DEALLOCATION COMPLETE");
        console.log("================================================================");

        uint256 finalAllocation = adapter.allocations(ALM_WHYPE_STHYPE_ID);
        uint256 finalAdapterBalance = IERC20(vault.asset()).balanceOf(adapterAddress);
        uint256 finalVaultBalance = IERC20(vault.asset()).balanceOf(vaultAddress);

        console.log("\nFinal State:");
        console.log("  Final allocation:", finalAllocation);
        console.log("  Adapter balance:", finalAdapterBalance);
        console.log("  Vault balance:", finalVaultBalance);

        console.log("\nChanges:");
        console.log("  Allocation decreased by:", currentAllocation - finalAllocation);
        console.log("  Adapter balance decreased by:", adapterBalance - finalAdapterBalance);
        console.log("  Vault balance increased by:", finalVaultBalance - vaultBalance);

        if (finalAllocation == currentAllocation - amount) {
            console.log("\n  \u2713\u2713\u2713 DEALLOCATION SUCCESSFUL \u2713\u2713\u2713");
        } else {
            console.log("\n  \u26A0 WARNING: Unexpected allocation change");
        }

        console.log("================================================================\n");
    }
}
