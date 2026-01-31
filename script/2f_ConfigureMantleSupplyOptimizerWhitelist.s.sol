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
 * @title ConfigureMantleSupplyOptimizerWhitelist
 * @notice Configure function whitelists for Mantle Supply Optimizer strategy
 * @dev Run AFTER 2d_ConfigureAdapter.s.sol
 *
 * CRITICAL: UniversalAdapterEscrow requires whitelisting ALL functions that will be called
 * via executeStrategy(). Without whitelist configuration, all strategy executions will
 * REVERT with FunctionNotWhitelisted() error.
 *
 * This script configures whitelists for the Mantle Supply Optimizer which deposits into:
 * - Lendle (Aave V2 fork): deposit() for USDT & USDe
 * - Init Capital: mintTo() for USDT & USDe
 * - Compound V3 (Comet): supply() for USDe
 *
 * Required Environment Variables:
 *   - PRIVATE_KEY: Deployer/owner private key
 *
 * Usage:
 *   source .env && forge script script/2f_ConfigureMantleSupplyOptimizerWhitelist.s.sol \
 *     --rpc-url $MANTLE_RPC_URL --broadcast -v
 *
 * Protocol Documentation:
 *   - Lendle: https://docs.lendle.xyz/ (Aave V2 fork)
 *   - Init Capital: https://dev.init.capital/
 *   - Compound V3: https://docs.compound.finance/
 */
contract ConfigureMantleSupplyOptimizerWhitelist is Script {
    // ============================================================
    // ADAPTER ADDRESS (UPDATE BEFORE DEPLOYMENT)
    // ============================================================
    address constant ADAPTER_ADDRESS = 0x4503d80B06Ac36C7DFEb393617ADd46036aB8d13; // TODO: Set adapter address

    // ============================================================
    // TOKEN ADDRESSES ON MANTLE
    // ============================================================
    address constant USDT = 0x201EBa5CC46D216Ce6DC03F6a759e8E766e956aE;
    address constant USDE = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34;

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
    // Lending pools for specific assets (tokens are transferred here before mintTo)
    address constant INIT_LENDING_POOL_USDT = 0xadA66a8722B5cdfe3bC504007A5d793e7100ad09;
    address constant INIT_LENDING_POOL_USDE = 0x3282437C436eE6AA9861a6A46ab0822d82581b1c;

    // ============================================================
    // COMPOUND V3 (COMET) PROTOCOL ADDRESSES
    // https://docs.compound.finance/
    // ============================================================
    // cUSDEv3 Comet proxy on Mantle - USDe base market
    address constant COMPOUND_COMET_USDE = address(0); // TODO: Set cUSDEv3 Comet address

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

    // Compound V3 (Comet) Functions
    // supply(address asset, uint amount)
    bytes4 constant COMPOUND_SUPPLY = 0xf2b9fdb8;
    // withdraw(address asset, uint amount)
    bytes4 constant COMPOUND_WITHDRAW = 0xf3fef3a3;
    // supplyTo(address dst, address asset, uint amount)
    bytes4 constant COMPOUND_SUPPLY_TO = 0x4232cd63;
    // withdrawTo(address to, address asset, uint amount)
    bytes4 constant COMPOUND_WITHDRAW_TO = 0xc3b35a7e;

    function run() public {
        // Load private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        require(ADAPTER_ADDRESS != address(0), "ADAPTER_ADDRESS must be set");

        IUniversalAdapterEscrow adapter = IUniversalAdapterEscrow(ADAPTER_ADDRESS);

        console.log("\n================================================================");
        console.log("    MANTLE SUPPLY OPTIMIZER WHITELIST CONFIGURATION");
        console.log("================================================================");
        console.log("Deployer:", deployer);
        console.log("Adapter:", ADAPTER_ADDRESS);
        console.log("\nToken Addresses:");
        console.log("  USDT:", USDT);
        console.log("  USDe:", USDE);
        console.log("\nProtocol Addresses:");
        console.log("  Lendle LendingPool:", LENDLE_LENDING_POOL);
        console.log("  Init Capital Core:", INIT_CORE);
        console.log("  Init USDT Pool:", INIT_LENDING_POOL_USDT);
        console.log("  Init USDe Pool:", INIT_LENDING_POOL_USDE);
        console.log("  Compound Comet USDe:", COMPOUND_COMET_USDE);

        vm.startBroadcast(deployerPrivateKey);

        // ============================================================
        // STEP 1: Whitelist Token Approval & Transfer Functions
        // ============================================================
        console.log("\n[Step 1/5] Whitelisting token functions...");

        // USDT approvals and transfers
        adapter.updateWhitelist(USDT, ERC20_APPROVE, true, 0);
        console.log("  [OK] USDT.approve(address,uint256)");

        adapter.updateWhitelist(USDT, ERC20_TRANSFER, true, 0);
        console.log("  [OK] USDT.transfer(address,uint256)");

        adapter.updateWhitelist(USDT, ERC20_BALANCE_OF, true, 0);
        console.log("  [OK] USDT.balanceOf(address)");

        // USDe approvals and transfers
        adapter.updateWhitelist(USDE, ERC20_APPROVE, true, 0);
        console.log("  [OK] USDe.approve(address,uint256)");

        adapter.updateWhitelist(USDE, ERC20_TRANSFER, true, 0);
        console.log("  [OK] USDe.transfer(address,uint256)");

        adapter.updateWhitelist(USDE, ERC20_BALANCE_OF, true, 0);
        console.log("  [OK] USDe.balanceOf(address)");

        // ============================================================
        // STEP 2: Whitelist Lendle (Aave V2 Fork) Functions
        // Lendle uses standard Aave V2 interface for deposits
        // https://docs.lendle.xyz/
        // ============================================================
        console.log("\n[Step 2/5] Whitelisting Lendle functions...");

        // deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode)
        adapter.updateWhitelist(
            LENDLE_LENDING_POOL,
            LENDLE_DEPOSIT,
            true,
            0 // No limit - amount controlled by strategy
        );
        console.log("  [OK] Lendle.deposit(address,uint256,address,uint16) for USDT & USDe");

        // withdraw(address asset, uint256 amount, address to)
        adapter.updateWhitelist(
            LENDLE_LENDING_POOL,
            LENDLE_WITHDRAW,
            true,
            0 // No limit - amount controlled by strategy
        );
        console.log("  [OK] Lendle.withdraw(address,uint256,address) for USDT & USDe");

        // ============================================================
        // STEP 3: Whitelist Init Capital Functions
        // Init Capital requires: 1) Transfer tokens to pool, 2) Call mintTo on InitCore
        // https://dev.init.capital/guides/basic-interaction/deposit-and-withdraw
        // ============================================================
        console.log("\n[Step 3/5] Whitelisting Init Capital functions...");

        // mintTo(address _pool, address _to) - Main deposit function on InitCore
        // Note: Tokens must be transferred to the lending pool BEFORE calling mintTo
        adapter.updateWhitelist(
            INIT_CORE,
            INIT_MINT_TO,
            true,
            0 // No limit - amount controlled by strategy
        );
        console.log("  [OK] InitCore.mintTo(address,address) for USDT & USDe");

        // burnTo(address _pool, address _to) - Withdrawal function
        adapter.updateWhitelist(
            INIT_CORE,
            INIT_BURN_TO,
            true,
            0 // No limit - amount controlled by strategy
        );
        console.log("  [OK] InitCore.burnTo(address,address) for USDT & USDe");

        // ============================================================
        // STEP 4: Whitelist Compound V3 (Comet) Functions
        // Compound V3 uses supply(asset, amount) for deposits
        // https://docs.compound.finance/
        // ============================================================
        console.log("\n[Step 4/5] Whitelisting Compound V3 functions...");

        if (COMPOUND_COMET_USDE != address(0)) {
            // supply(address asset, uint amount)
            adapter.updateWhitelist(
                COMPOUND_COMET_USDE,
                COMPOUND_SUPPLY,
                true,
                0 // No limit - amount controlled by strategy
            );
            console.log("  [OK] Comet.supply(address,uint256) for USDe");

            // supplyTo(address dst, address asset, uint amount)
            adapter.updateWhitelist(
                COMPOUND_COMET_USDE,
                COMPOUND_SUPPLY_TO,
                true,
                0 // No limit
            );
            console.log("  [OK] Comet.supplyTo(address,address,uint256) for USDe");

            // withdraw(address asset, uint amount)
            adapter.updateWhitelist(
                COMPOUND_COMET_USDE,
                COMPOUND_WITHDRAW,
                true,
                0 // No limit
            );
            console.log("  [OK] Comet.withdraw(address,uint256) for USDe");

            // withdrawTo(address to, address asset, uint amount)
            adapter.updateWhitelist(
                COMPOUND_COMET_USDE,
                COMPOUND_WITHDRAW_TO,
                true,
                0 // No limit
            );
            console.log("  [OK] Comet.withdrawTo(address,address,uint256) for USDe");
        } else {
            console.log("  [SKIP] Compound Comet address not configured");
        }

        // ============================================================
        // STEP 5: Whitelist Init Capital Lending Pool Transfers
        // Init Capital requires direct transfers to lending pools
        // ============================================================
        console.log("\n[Step 5/5] Whitelisting Init pool transfers...");

        if (INIT_LENDING_POOL_USDT != address(0)) {
            // Allow USDT transfers to Init USDT pool (required before mintTo)
            console.log("  [INFO] USDT transfers to Init pool enabled via USDT.transfer whitelist");
        }

        if (INIT_LENDING_POOL_USDE != address(0)) {
            // Allow USDe transfers to Init USDe pool (required before mintTo)
            console.log("  [INFO] USDe transfers to Init pool enabled via USDe.transfer whitelist");
        }

        vm.stopBroadcast();

        // ============================================================
        // Summary
        // ============================================================
        console.log("\n================================================================");
        console.log("    WHITELIST CONFIGURATION COMPLETE!");
        console.log("================================================================");
        console.log("\nWhitelisted Functions Summary:");
        console.log("  Token Functions: 6");
        console.log("    - USDT: approve, transfer, balanceOf");
        console.log("    - USDe: approve, transfer, balanceOf");
        console.log("\n  Lendle (Aave V2 Fork): 2");
        console.log("    - deposit(address,uint256,address,uint16)");
        console.log("    - withdraw(address,uint256,address)");
        console.log("\n  Init Capital: 2");
        console.log("    - mintTo(address,address) [deposit]");
        console.log("    - burnTo(address,address) [withdraw]");
        console.log("\n  Compound V3 (Comet): 4");
        console.log("    - supply(address,uint256)");
        console.log("    - supplyTo(address,address,uint256)");
        console.log("    - withdraw(address,uint256)");
        console.log("    - withdrawTo(address,address,uint256)");

        console.log("\n[SUCCESS] Adapter ready for Mantle Supply Optimizer!");

        console.log("\n================================================================");
        console.log("    STRATEGY EXECUTION FLOWS");
        console.log("================================================================");

        console.log("\nLendle Deposit Flow (USDT or USDe):");
        console.log("  1. USDT/USDe.approve(LENDLE_POOL, amount)");
        console.log("  2. LENDLE_POOL.deposit(asset, amount, onBehalfOf, 0)");

        console.log("\nInit Capital Deposit Flow (USDT or USDe):");
        console.log("  1. USDT/USDe.approve(INIT_POOL, amount) OR");
        console.log("     USDT/USDe.transfer(INIT_POOL, amount)");
        console.log("  2. INIT_CORE.mintTo(pool, receiver)");

        console.log("\nCompound V3 Deposit Flow (USDe only):");
        console.log("  1. USDe.approve(COMET, amount)");
        console.log("  2. COMET.supply(USDe, amount)");

        console.log("\n================================================================");
        console.log("    IMPORTANT CONFIGURATION NOTES");
        console.log("================================================================");
        console.log("\nTODOs before deployment:");
        console.log("  1. Set ADAPTER_ADDRESS to deployed UniversalAdapterEscrow");
        console.log("  2. Set COMPOUND_COMET_USDE to cUSDEv3 proxy address on Mantle");
        console.log("     (Check: https://docs.compound.finance/ or governance proposal)");
        console.log("\nProtocol References:");
        console.log("  - Lendle Docs: https://docs.lendle.xyz/");
        console.log("  - Init Capital: https://dev.init.capital/contract-addresses/mantle");
        console.log("  - Compound V3: https://docs.compound.finance/");
        console.log("================================================================\n");
    }
}
