// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/VaultV2.sol";
import "../src/VaultV2Factory.sol";
import "../src/adapters/UniversalAdapterEscrow.sol";
import "../src/adapters/UniversalAdapterEscrowFactory.sol";
import "../src/valuers/UniversalValuerOffchain.sol";
import {IVaultV2} from "../src/interfaces/IVaultV2.sol";
import {IUniversalAdapterEscrow} from "../src/adapters/interfaces/IUniversalAdapterEscrow.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

/**
 * @title PTKHYPELoopE2E
 * @notice End-to-end deployment and execution of PT-KHYPE loop strategy
 * @dev Deploys infrastructure and executes complete strategy flow
 */
contract PTKHYPELoopE2E is Script {
    // ============ Constants ============

    bytes32 constant PT_KHYPE_LOOP_ID = keccak256("pt-khype-loop");
    uint256 constant INITIAL_DEPOSIT = 1000e18;
    uint256 constant ALLOCATION_AMOUNT = 500e18;
    uint256 constant DAILY_LIMIT = 10000e18;

    // ============ State Variables ============

    VaultV2Factory vaultFactory;
    UniversalAdapterEscrowFactory adapterFactory;
    VaultV2 vault;
    UniversalAdapterEscrow adapter;
    UniversalValuerOffchain valuer;

    MockERC20 khype;
    MockERC20 ptKhype;
    MockPendleRouter pendleRouter;

    address deployer;
    uint256 deployerPrivateKey;

    // ============ Main Execution ============

    function run() public {
        deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);

        console.log("\n=================================================");
        console.log("    PT-KHYPE LOOP STRATEGY E2E EXECUTION");
        console.log("=================================================");
        console.log("Deployer:", deployer);

        // Phase 1: Deploy infrastructure
        deployInfrastructure();

        // Phase 2: Setup mock tokens
        setupMockTokens();

        // Phase 3: Configure contracts
        configureContracts();

        // Phase 4: Execute strategy
        executeStrategy();

        // Phase 5: Verify and report
        verifyResults();
    }

    // ============ Phase 1: Deploy Infrastructure ============

    function deployInfrastructure() internal {
        console.log("\n>>> PHASE 1: DEPLOYING INFRASTRUCTURE");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy factories
        vaultFactory = new VaultV2Factory();
        console.log("   VaultV2Factory:", address(vaultFactory));

        adapterFactory = new UniversalAdapterEscrowFactory();
        console.log("   AdapterFactory:", address(adapterFactory));

        // Deploy mock KHYPE token
        khype = new MockERC20("KHYPE", "KHYPE", 18);
        console.log("   KHYPE Token:", address(khype));

        // Deploy valuer
        valuer = new UniversalValuerOffchain(deployer, address(khype));
        valuer.initiateSignerChange(deployer, true, 100);
        valuer.setRequiredWeight(100);
        console.log("   Valuer:", address(valuer));

        // Deploy VaultV2
        bytes32 salt = keccak256("pt-khype-e2e");
        address vaultAddress = vaultFactory.createVaultV2(deployer, address(khype), salt);
        vault = VaultV2(vaultAddress);
        console.log("   VaultV2:", address(vault));

        // Deploy UniversalAdapterEscrow
        address adapterAddress = adapterFactory.deployAdapter(address(vault), address(valuer), false, salt);
        adapter = UniversalAdapterEscrow(payable(adapterAddress));
        console.log("   Adapter:", address(adapter));

        vm.stopBroadcast();
    }

    // ============ Phase 2: Setup Mock Tokens ============

    function setupMockTokens() internal {
        console.log("\n>>> PHASE 2: SETTING UP MOCK TOKENS");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy PT-KHYPE mock
        ptKhype = new MockERC20("PT-KHYPE", "PT-KHYPE", 18);
        console.log("   PT-KHYPE:", address(ptKhype));

        // Deploy mock Pendle router
        pendleRouter = new MockPendleRouter(address(khype), address(ptKhype));
        console.log("   Pendle Router:", address(pendleRouter));

        // Mint initial KHYPE for testing
        khype.mint(deployer, INITIAL_DEPOSIT * 2);
        console.log("   Minted KHYPE:", INITIAL_DEPOSIT * 2);

        vm.stopBroadcast();
    }

    // ============ Phase 3: Configure Contracts ============

    function configureContracts() internal {
        console.log("\n>>> PHASE 3: CONFIGURING CONTRACTS");

        vm.startBroadcast(deployerPrivateKey);

        // Configure vault
        vault.setCurator(deployer);

        // Add adapter
        vault.submit(abi.encodeCall(IVaultV2.addAdapter, (address(adapter))));
        vault.addAdapter(address(adapter));
        console.log("   Adapter added to vault");

        // Set allocator
        vault.submit(abi.encodeCall(IVaultV2.setIsAllocator, (deployer, true)));
        vault.setIsAllocator(deployer, true);
        console.log("   Allocator set");

        // Set caps for PT-KHYPE strategy
        bytes memory idData = abi.encodePacked("pt-khype-loop");
        vault.submit(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, type(uint128).max)));
        vault.increaseAbsoluteCap(idData, type(uint128).max);
        vault.submit(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, 1e18)));
        vault.increaseRelativeCap(idData, 1e18);
        console.log("   Caps configured");

        // Configure strategy
        adapter.setStrategy(PT_KHYPE_LOOP_ID, deployer, "", DAILY_LIMIT);
        console.log("   Strategy configured");

        // Configure whitelist
        adapter.updateWhitelist(address(khype), bytes4(keccak256("approve(address,uint256)")), true, type(uint256).max);
        adapter.updateWhitelist(
            address(pendleRouter), bytes4(keccak256("swapExactTokenForPt(address,uint256)")), true, type(uint256).max
        );
        console.log("   Whitelist configured");

        vm.stopBroadcast();
    }

    // ============ Phase 4: Execute Strategy ============

    function executeStrategy() internal {
        console.log("\n>>> PHASE 4: EXECUTING PT-KHYPE STRATEGY");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deposit to vault
        console.log("\n   Step 1: Depositing to vault");
        khype.approve(address(vault), INITIAL_DEPOSIT);
        uint256 shares = vault.deposit(INITIAL_DEPOSIT, deployer);
        console.log("      Deposited:", INITIAL_DEPOSIT);
        console.log("      Shares received:", shares);

        // Step 2: Allocate to strategy
        console.log("\n   Step 2: Allocating to strategy");
        bytes memory allocData =
            abi.encode(PT_KHYPE_LOOP_ID, ALLOCATION_AMOUNT, false, new IUniversalAdapterEscrow.Call[](0));
        vault.allocate(address(adapter), allocData, ALLOCATION_AMOUNT);
        console.log("      Allocated:", ALLOCATION_AMOUNT);
        console.log("      Strategy allocation:", adapter.getAllocation(PT_KHYPE_LOOP_ID));

        // Step 3: Execute Pendle swap
        console.log("\n   Step 3: Executing Pendle swap");
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](2);

        // Approve Pendle router
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(khype),
            value: 0,
            data: abi.encodeWithSelector(khype.approve.selector, address(pendleRouter), ALLOCATION_AMOUNT)
        });

        // Execute swap
        calls[1] = IUniversalAdapterEscrow.Call({
            target: address(pendleRouter),
            value: 0,
            data: abi.encodeWithSelector(pendleRouter.swapExactTokenForPt.selector, address(adapter), ALLOCATION_AMOUNT)
        });

        adapter.executeStrategy(PT_KHYPE_LOOP_ID, calls);
        console.log("      Swap executed");
        console.log("      PT-KHYPE received:", ptKhype.balanceOf(address(adapter)));

        // Step 4: Deallocate from strategy (simulate unwinding)
        console.log("\n   Step 4: Deallocating from strategy");

        // Simulate unwinding: burn PT and mint back KHYPE
        uint256 ptBalance = ptKhype.balanceOf(address(adapter));
        ptKhype.burn(address(adapter), ptBalance);
        khype.mint(address(adapter), ALLOCATION_AMOUNT);

        bytes memory deallocData =
            abi.encode(PT_KHYPE_LOOP_ID, ALLOCATION_AMOUNT, new IUniversalAdapterEscrow.Call[](0));
        vault.deallocate(address(adapter), deallocData, ALLOCATION_AMOUNT);
        console.log("      Deallocated:", ALLOCATION_AMOUNT);
        console.log("      Remaining allocation:", adapter.getAllocation(PT_KHYPE_LOOP_ID));

        // Step 5: Withdraw from vault
        console.log("\n   Step 5: Withdrawing from vault");
        uint256 assetsRedeemed = vault.redeem(shares, deployer, deployer);
        console.log("      Shares redeemed:", shares);
        console.log("      Assets received:", assetsRedeemed);

        vm.stopBroadcast();
    }

    // ============ Phase 5: Verify Results ============

    function verifyResults() internal view {
        console.log("\n>>> PHASE 5: VERIFICATION & RESULTS");
        console.log("\n   Final Balances:");
        console.log("      Deployer KHYPE:", khype.balanceOf(deployer));
        console.log("      Vault KHYPE:", khype.balanceOf(address(vault)));
        console.log("      Adapter KHYPE:", khype.balanceOf(address(adapter)));
        console.log("      Adapter PT-KHYPE:", ptKhype.balanceOf(address(adapter)));

        console.log("\n   Vault State:");
        console.log("      Total Assets:", vault.totalAssets());
        console.log("      Total Supply:", vault.totalSupply());
        console.log("      Adapters Count:", vault.adaptersLength());

        console.log("\n   Strategy State:");
        IUniversalAdapterEscrow.StrategyConfig memory config = adapter.getStrategy(PT_KHYPE_LOOP_ID);
        console.log("      Active:", config.active);
        console.log("      Agent:", config.agent);
        console.log("      Daily Limit:", config.dailyLimit);
        console.log("      Daily Used:", config.dailyUsed);
        console.log("      Active Strategies:", adapter.getActiveStrategies().length);

        console.log("\n=================================================");
        console.log("    E2E EXECUTION COMPLETE!");
        console.log("=================================================");
        console.log("[SUCCESS] PT-KHYPE loop strategy executed successfully!");
    }
}

// ============ Mock Contracts ============

contract MockERC20 is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}

contract MockPendleRouter {
    IERC20 public khype;
    IERC20 public ptKhype;

    constructor(address _khype, address _ptKhype) {
        khype = IERC20(_khype);
        ptKhype = IERC20(_ptKhype);
    }

    function swapExactTokenForPt(address receiver, uint256 amount) external returns (uint256) {
        // Simple mock: 1:0.95 swap ratio
        uint256 ptAmount = (amount * 95) / 100;

        khype.transferFrom(msg.sender, address(this), amount);
        MockERC20(address(ptKhype)).mint(receiver, ptAmount);

        return ptAmount;
    }
}
