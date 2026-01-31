// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";

interface IUniversalAdapterEscrow {
    function updateWhitelist(
        address target,
        bytes4 selector,
        bool allowed,
        uint256 limit
    ) external;
}

/**
 * @title ConfigureMantleSupplyOptimizerWhitelist_WETH
 * @notice Configure function whitelists for Mantle Supply Optimizer strategy (WETH)
 * @dev Run AFTER 2d_ConfigureAdapter.s.sol
 *
 * CRITICAL: UniversalAdapterEscrow requires whitelisting ALL functions that will be called
 * via executeStrategy(). Without whitelist configuration, all strategy executions will
 * REVERT with FunctionNotWhitelisted() error.
 *
 * This script configures whitelists for the Mantle Supply Optimizer which deposits WETH into:
 * - Lendle (Aave V2 fork): deposit() for WETH
 * - Init Capital: mintTo() for WETH
 *
 * Required Environment Variables:
 *   - PRIVATE_KEY: Deployer/owner private key
 *
 * Usage:
 *   source .env && forge script script/2f_ConfigureMantleSupplyOptimizerWhitelist_WETH.s.sol \
 *     --rpc-url $MANTLE_RPC_URL --broadcast -v
 *
 * Protocol Documentation:
 *   - Lendle: https://docs.lendle.xyz/ (Aave V2 fork)
 *   - Init Capital: https://dev.init.capital/
 */
contract ConfigureMantleSupplyOptimizerWhitelist_WETH is Script {
    // ============================================================
    // ADAPTER ADDRESS (UPDATE BEFORE DEPLOYMENT)
    // ============================================================
    address constant ADAPTER_ADDRESS = address(0); // TODO: Set adapter address

    // ============================================================
    // TOKEN ADDRESS ON MANTLE
    // ============================================================
    address constant WETH = 0xdEAddEaDdeadDEadDEADDEAddEADDEAddead1111;

    // ============================================================
    // LENDLE PROTOCOL ADDRESSES (Aave V2 Fork)
    // https://docs.lendle.xyz/contracts-and-security/mantle-contracts
    // ============================================================
    address constant LENDLE_LENDING_POOL = 0xCFa5aE7c2CE8Fadc6426C1ff872cA45378Fb7cF3;

    // ============================================================
    // INIT CAPITAL PROTOCOL ADDRESSES
    // https://dev.init.capital/contract-addresses/mantle
    // ============================================================
    address constant INIT_CORE = 0x972BcB0284cca0152527c4f70f8F689852bCAFc5;
    // Lending pool for WETH (tokens are transferred here before mintTo)
    address constant INIT_LENDING_POOL_WETH = 0x51AB74f8B03F0305d8dcE936B473AB587911AEC4;

    // ============================================================
    // FUNCTION SELECTORS
    // ============================================================

    // ERC20 Standard Functions
    bytes4 constant ERC20_APPROVE = 0x095ea7b3;           // approve(address,uint256)
    bytes4 constant ERC20_TRANSFER = 0xa9059cbb;          // transfer(address,uint256)
    bytes4 constant ERC20_BALANCE_OF = 0x70a08231;        // balanceOf(address)

    // Lendle (Aave V2) Functions
    // deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode)
    bytes4 constant LENDLE_DEPOSIT = 0xe8eda9df;
    // withdraw(address asset, uint256 amount, address to)
    bytes4 constant LENDLE_WITHDRAW = 0x69328dec;

    // Init Capital Functions
    // mintTo(address _pool, address _to) - Deposit to lending pool
    bytes4 constant INIT_MINT_TO = 0x951b6c02;
    // burnTo(address _pool, address _to) - Withdraw from lending pool
    bytes4 constant INIT_BURN_TO = 0x7fe6bc3d;

    function run() public {
        // Load private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        require(ADAPTER_ADDRESS != address(0), "ADAPTER_ADDRESS must be set");

        IUniversalAdapterEscrow adapter = IUniversalAdapterEscrow(ADAPTER_ADDRESS);

        console.log("\n================================================================");
        console.log("    MANTLE SUPPLY OPTIMIZER WHITELIST CONFIGURATION (WETH)");
        console.log("================================================================");
        console.log("Deployer:", deployer);
        console.log("Adapter:", ADAPTER_ADDRESS);
        console.log("\nToken Address:");
        console.log("  WETH:", WETH);
        console.log("\nProtocol Addresses:");
        console.log("  Lendle LendingPool:", LENDLE_LENDING_POOL);
        console.log("  Init Capital Core:", INIT_CORE);
        console.log("  Init WETH Pool:", INIT_LENDING_POOL_WETH);

        vm.startBroadcast(deployerPrivateKey);

        // ============================================================
        // STEP 1: Whitelist Token Approval & Transfer Functions
        // ============================================================
        console.log("\n[Step 1/3] Whitelisting WETH token functions...");

        // WETH approvals and transfers
        adapter.updateWhitelist(WETH, ERC20_APPROVE, true, 0);
        console.log("  [OK] WETH.approve(address,uint256)");

        adapter.updateWhitelist(WETH, ERC20_TRANSFER, true, 0);
        console.log("  [OK] WETH.transfer(address,uint256)");

        adapter.updateWhitelist(WETH, ERC20_BALANCE_OF, true, 0);
        console.log("  [OK] WETH.balanceOf(address)");

        // ============================================================
        // STEP 2: Whitelist Lendle (Aave V2 Fork) Functions
        // Lendle uses standard Aave V2 interface for deposits
        // https://docs.lendle.xyz/
        // ============================================================
        console.log("\n[Step 2/3] Whitelisting Lendle functions...");

        // deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode)
        adapter.updateWhitelist(
            LENDLE_LENDING_POOL,
            LENDLE_DEPOSIT,
            true,
            0 // No limit - amount controlled by strategy
        );
        console.log("  [OK] Lendle.deposit(address,uint256,address,uint16) for WETH");

        // withdraw(address asset, uint256 amount, address to)
        adapter.updateWhitelist(
            LENDLE_LENDING_POOL,
            LENDLE_WITHDRAW,
            true,
            0 // No limit - amount controlled by strategy
        );
        console.log("  [OK] Lendle.withdraw(address,uint256,address) for WETH");

        // ============================================================
        // STEP 3: Whitelist Init Capital Functions
        // Init Capital requires: 1) Transfer tokens to pool, 2) Call mintTo on InitCore
        // https://dev.init.capital/guides/basic-interaction/deposit-and-withdraw
        // ============================================================
        console.log("\n[Step 3/3] Whitelisting Init Capital functions...");

        // mintTo(address _pool, address _to) - Main deposit function on InitCore
        // Note: Tokens must be transferred to the lending pool BEFORE calling mintTo
        adapter.updateWhitelist(
            INIT_CORE,
            INIT_MINT_TO,
            true,
            0 // No limit - amount controlled by strategy
        );
        console.log("  [OK] InitCore.mintTo(address,address) for WETH");

        // burnTo(address _pool, address _to) - Withdrawal function
        adapter.updateWhitelist(
            INIT_CORE,
            INIT_BURN_TO,
            true,
            0 // No limit - amount controlled by strategy
        );
        console.log("  [OK] InitCore.burnTo(address,address) for WETH");

        vm.stopBroadcast();

        // ============================================================
        // Summary
        // ============================================================
        console.log("\n================================================================");
        console.log("    WHITELIST CONFIGURATION COMPLETE!");
        console.log("================================================================");
        console.log("\nWhitelisted Functions Summary:");
        console.log("  Token Functions: 3");
        console.log("    - WETH: approve, transfer, balanceOf");
        console.log("\n  Lendle (Aave V2 Fork): 2");
        console.log("    - deposit(address,uint256,address,uint16)");
        console.log("    - withdraw(address,uint256,address)");
        console.log("\n  Init Capital: 2");
        console.log("    - mintTo(address,address) [deposit]");
        console.log("    - burnTo(address,address) [withdraw]");
        console.log("\n  Total: 7 function whitelists configured");

        console.log("\n[SUCCESS] Adapter ready for Mantle Supply Optimizer (WETH)!");

        console.log("\n================================================================");
        console.log("    STRATEGY EXECUTION FLOWS");
        console.log("================================================================");

        console.log("\nLendle Deposit Flow (WETH):");
        console.log("  1. WETH.approve(LENDLE_POOL, amount)");
        console.log("  2. LENDLE_POOL.deposit(WETH, amount, onBehalfOf, 0)");

        console.log("\nInit Capital Deposit Flow (WETH):");
        console.log("  1. WETH.transfer(INIT_WETH_POOL, amount)");
        console.log("  2. INIT_CORE.mintTo(INIT_WETH_POOL, receiver)");

        console.log("\n================================================================");
        console.log("    IMPORTANT CONFIGURATION NOTES");
        console.log("================================================================");
        console.log("\nTODOs before deployment:");
        console.log("  1. Set ADAPTER_ADDRESS to deployed UniversalAdapterEscrow");
        console.log("\nProtocol References:");
        console.log("  - Lendle Docs: https://docs.lendle.xyz/");
        console.log("  - Init Capital: https://dev.init.capital/contract-addresses/mantle");
        console.log("================================================================\n");
    }
}
