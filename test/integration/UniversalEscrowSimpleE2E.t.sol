// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/adapters/UniversalEscrowAdapter.sol";
import "../../src/adapters/StrategyEscrow.sol";
import "../../src/valuers/UniversalValuerOffchain.sol";
import "../../src/VaultV2.sol";
import "../../src/VaultV2Factory.sol";
import "../../src/interfaces/IERC20.sol";
import "../../src/libraries/SafeERC20Lib.sol";

/// @title UniversalEscrowSimpleE2ETest
/// @notice Simplified end-to-end test for UniversalEscrowAdapter + StrategyEscrow + UniversalValuerOffchain
/// @dev Tests the core functionality of these contracts working together
contract UniversalEscrowSimpleE2ETest is Test {
    using SafeERC20Lib for IERC20;

    // Core contracts
    VaultV2 public vault;
    VaultV2Factory public vaultFactory;
    UniversalEscrowAdapter public adapter;
    StrategyEscrow public escrow;
    UniversalValuerOffchain public valuer;
    MockERC20 public asset;

    // Actors
    address public vaultOwner = address(0x1);
    address public depositor = address(0x2);
    address public allocator = address(0x3);
    address public signer1;
    uint256 public signer1Key = 0x1234;

    // Strategy identifiers
    bytes32 constant STRATEGY_A = keccak256("STRATEGY_A");
    bytes32 constant STRATEGY_B = keccak256("STRATEGY_B");

    // Events to test
    event StrategyAllocated(bytes32 indexed strategyId, uint256 amount);
    event StrategyDeallocated(bytes32 indexed strategyId, uint256 amount);
    event ValueUpdated(bytes32 indexed strategyId, uint256 value, uint256 confidence, uint256 timestamp, bool isPush);

    function setUp() public {
        // Deploy mock asset
        asset = new MockERC20("Test Token", "TST");

        // Deploy vault factory
        vaultFactory = new VaultV2Factory();

        // Deploy vault through factory
        bytes32 salt = keccak256("TEST_VAULT");
        vault = VaultV2(vaultFactory.createVaultV2(vaultOwner, address(asset), salt));

        // Deploy valuer first
        valuer = new UniversalValuerOffchain(vaultOwner, address(asset));

        // Use a deterministic deployment approach
        // First calculate what the final adapter address will be
        uint256 currentNonce = vm.getNonce(address(this));
        address futureAdapterAddress = vm.computeCreateAddress(address(this), currentNonce + 1);

        // Deploy escrow with the future adapter address
        escrow = new StrategyEscrow(futureAdapterAddress, vaultOwner);

        // Deploy adapter (this should have the predicted address)
        adapter = new UniversalEscrowAdapter(
            address(vault),
            address(escrow),
            address(valuer),
            true // using offchain valuer
        );

        // Verify the addresses match
        require(address(adapter) == futureAdapterAddress, "Address prediction failed");

        // Setup signer for off-chain valuation
        signer1 = vm.addr(signer1Key);

        // Configure valuer
        vm.startPrank(vaultOwner);
        valuer.configureSigner(signer1, true, 100);
        valuer.setRequiredWeight(100);
        valuer.configureStrategy(STRATEGY_A, 0, 24 hours, 500, 95);
        valuer.configureStrategy(STRATEGY_B, 0, 24 hours, 500, 95);
        vm.stopPrank();

        // Setup vault roles
        vm.startPrank(vaultOwner);
        vault.setCurator(vaultOwner);

        // Submit and execute setIsAllocator (timelock is 0 initially)
        bytes memory setAllocatorData = abi.encodeWithSelector(vault.setIsAllocator.selector, allocator, true);
        vault.submit(setAllocatorData);
        vault.setIsAllocator(allocator, true);

        // Submit and execute addAdapter
        bytes memory addAdapterData = abi.encodeWithSelector(vault.addAdapter.selector, address(adapter));
        vault.submit(addAdapterData);
        vault.addAdapter(address(adapter));

        // Set caps for strategy allocations
        // Need to set caps where keccak256(idData) == strategy ID returned by adapter
        // So idData should be such that keccak256(idData) == STRATEGY_A
        // Since STRATEGY_A = keccak256("STRATEGY_A"), we use "STRATEGY_A" as idData
        bytes memory strategyACapData = "STRATEGY_A";
        bytes memory strategyBCapData = "STRATEGY_B";

        bytes memory increaseCapAData = abi.encodeWithSelector(
            vault.increaseAbsoluteCap.selector,
            strategyACapData,
            2000e18 // 2000 tokens absolute cap for Strategy A
        );
        vault.submit(increaseCapAData);
        vault.increaseAbsoluteCap(strategyACapData, 2000e18);

        bytes memory increaseCapBData = abi.encodeWithSelector(
            vault.increaseAbsoluteCap.selector,
            strategyBCapData,
            1000e18 // 1000 tokens absolute cap for Strategy B
        );
        vault.submit(increaseCapBData);
        vault.increaseAbsoluteCap(strategyBCapData, 1000e18);

        // Set relative caps to 100% (WAD) to bypass relative cap checks
        uint256 WAD = 1e18;
        bytes memory increaseRelCapAData = abi.encodeWithSelector(
            vault.increaseRelativeCap.selector,
            strategyACapData,
            WAD // 100% relative cap for Strategy A
        );
        vault.submit(increaseRelCapAData);
        vault.increaseRelativeCap(strategyACapData, WAD);

        bytes memory increaseRelCapBData = abi.encodeWithSelector(
            vault.increaseRelativeCap.selector,
            strategyBCapData,
            WAD // 100% relative cap for Strategy B
        );
        vault.submit(increaseRelCapBData);
        vault.increaseRelativeCap(strategyBCapData, WAD);

        escrow.setGuardian(vaultOwner);

        // Whitelist the ERC20 transfer function for deallocations
        escrow.updateWhitelist(
            address(asset),
            IERC20.transfer.selector,
            true,
            type(uint256).max // No daily limit
        );

        // Track the asset token for emergency withdrawals
        escrow.trackToken(address(asset));

        vm.stopPrank();

        // Fund depositor
        asset.mint(depositor, 10000e18);
        vm.prank(depositor);
        asset.approve(address(vault), type(uint256).max);
    }

    /// @notice Test basic end-to-end flow
    function testBasicE2EFlow() public {
        // Step 1: Deposit to vault
        uint256 depositAmount = 1000e18;

        vm.prank(depositor);
        uint256 shares = vault.deposit(depositAmount, depositor);

        assertEq(shares, depositAmount);
        assertEq(vault.totalAssets(), depositAmount);
        assertEq(asset.balanceOf(address(vault)), depositAmount);

        // Step 2: Allocate to strategy A
        uint256 allocationAmount = 600e18;
        bytes memory allocationData = abi.encode(STRATEGY_A, allocationAmount, bytes(""));

        vm.expectEmit(true, true, true, true, address(adapter));
        emit StrategyAllocated(STRATEGY_A, allocationAmount);

        vm.prank(allocator);
        vault.allocate(address(adapter), allocationData, allocationAmount);

        assertEq(asset.balanceOf(address(escrow)), allocationAmount);
        assertEq(adapter.getStrategyAllocation(STRATEGY_A), allocationAmount);

        // Step 3: Update valuation through off-chain valuer
        uint256 strategyValue = 650e18;
        uint256 confidence = 98;
        uint256 nonce = 1;

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, strategyValue, confidence, nonce, signer1Key);

        vm.expectEmit(true, true, true, true, address(valuer));
        emit ValueUpdated(STRATEGY_A, strategyValue, confidence, block.timestamp, true);

        valuer.updateValue(STRATEGY_A, strategyValue, confidence, nonce, signatures);

        assertEq(valuer.getValue(STRATEGY_A), strategyValue);

        // Step 4: Allocate to strategy B
        uint256 secondAllocation = 200e18;
        bytes memory secondAllocationData = abi.encode(STRATEGY_B, secondAllocation, bytes(""));

        vm.prank(allocator);
        vault.allocate(address(adapter), secondAllocationData, secondAllocation);

        assertEq(adapter.getStrategyAllocation(STRATEGY_B), secondAllocation);
        assertEq(asset.balanceOf(address(escrow)), allocationAmount + secondAllocation);

        // Step 5: Update second strategy valuation
        uint256 strategyBValue = 210e18;
        signatures[0] = _signValue(STRATEGY_B, strategyBValue, confidence, 2, signer1Key);
        valuer.updateValue(STRATEGY_B, strategyBValue, confidence, 2, signatures);

        // Step 6: Deallocate from strategy A
        uint256 deallocateAmount = 300e18;
        bytes memory deallocateData = abi.encode(STRATEGY_A, deallocateAmount, bytes(""));

        vm.expectEmit(true, true, true, true, address(adapter));
        emit StrategyDeallocated(STRATEGY_A, deallocateAmount);

        vm.prank(allocator);
        vault.deallocate(address(adapter), deallocateData, deallocateAmount);

        assertEq(adapter.getStrategyAllocation(STRATEGY_A), allocationAmount - deallocateAmount);

        // Step 7: Withdrawal by depositor
        uint256 withdrawAmount = 100e18;
        vm.prank(depositor);
        vault.withdraw(withdrawAmount, depositor, depositor);

        assertTrue(asset.balanceOf(depositor) >= withdrawAmount);
    }

    /// @notice Test batch valuation update
    function testBatchValuation() public {
        // Setup: Deposit and allocate
        vm.prank(depositor);
        vault.deposit(1000e18, depositor);

        vm.startPrank(allocator);
        vault.allocate(address(adapter), abi.encode(STRATEGY_A, 400e18, bytes("")), 400e18);
        vault.allocate(address(adapter), abi.encode(STRATEGY_B, 300e18, bytes("")), 300e18);
        vm.stopPrank();

        // Batch update valuations
        bytes32[] memory strategyIds = new bytes32[](2);
        strategyIds[0] = STRATEGY_A;
        strategyIds[1] = STRATEGY_B;

        uint256[] memory values = new uint256[](2);
        values[0] = 420e18;
        values[1] = 315e18;

        uint256[] memory confidences = new uint256[](2);
        confidences[0] = 96;
        confidences[1] = 97;

        uint256 nonce = 1;
        bytes32 batchHash = keccak256(abi.encode(strategyIds, values, confidences, nonce));

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signBatchHash(batchHash, signer1Key);

        valuer.batchUpdateValues(strategyIds, values, confidences, nonce, signatures);

        assertEq(valuer.getValue(STRATEGY_A), 420e18);
        assertEq(valuer.getValue(STRATEGY_B), 315e18);
    }

    /// @notice Test strategy pause functionality
    function testStrategyPause() public {
        // Setup: Deposit and initial allocation
        vm.prank(depositor);
        vault.deposit(1000e18, depositor);

        vm.prank(allocator);
        vault.allocate(address(adapter), abi.encode(STRATEGY_A, 500e18, bytes("")), 500e18);

        // Pause strategy
        vm.prank(vaultOwner);
        adapter.toggleStrategyPause(STRATEGY_A, true);
        assertTrue(adapter.strategyPaused(STRATEGY_A));

        // Cannot allocate to paused strategy
        vm.expectRevert(IUniversalEscrowAdapter.StrategyPaused.selector);
        vm.prank(allocator);
        vault.allocate(address(adapter), abi.encode(STRATEGY_A, 100e18, bytes("")), 100e18);

        // Can still deallocate from paused strategy
        vm.prank(allocator);
        vault.deallocate(address(adapter), abi.encode(STRATEGY_A, 200e18, bytes("")), 200e18);

        assertEq(adapter.getStrategyAllocation(STRATEGY_A), 300e18);

        // Unpause strategy
        vm.prank(vaultOwner);
        adapter.toggleStrategyPause(STRATEGY_A, false);
        assertFalse(adapter.strategyPaused(STRATEGY_A));

        // Can allocate again
        vm.prank(allocator);
        vault.allocate(address(adapter), abi.encode(STRATEGY_A, 150e18, bytes("")), 150e18);
        assertEq(adapter.getStrategyAllocation(STRATEGY_A), 450e18);
    }

    /// @notice Test escrow pause functionality
    function testEscrowPause() public {
        // Setup
        vm.prank(depositor);
        vault.deposit(1000e18, depositor);

        vm.prank(allocator);
        vault.allocate(address(adapter), abi.encode(STRATEGY_A, 500e18, bytes("")), 500e18);

        // Pause multicall
        vm.prank(vaultOwner); // Guardian
        escrow.pauseMulticall();
        assertTrue(escrow.multicallPaused());

        // Create a call
        IStrategyEscrow.Call[] memory calls = new IStrategyEscrow.Call[](1);
        calls[0] = IStrategyEscrow.Call({
            target: address(asset),
            value: 0,
            data: abi.encodeWithSelector(IERC20.approve.selector, address(0x999), 100e18)
        });

        // Should revert when paused
        vm.expectRevert(IStrategyEscrow.MulticallIsPaused.selector);
        vm.prank(address(adapter)); // Call as adapter since it has permission
        escrow.executeMulticall(STRATEGY_A, calls);

        // Unpause
        vm.prank(vaultOwner);
        escrow.unpauseMulticall();
        assertFalse(escrow.multicallPaused());
    }

    /// @notice Test force recovery
    function testForceRecovery() public {
        // Setup: Deposit and allocate
        vm.prank(depositor);
        vault.deposit(1000e18, depositor);

        vm.prank(allocator);
        vault.allocate(address(adapter), abi.encode(STRATEGY_A, 600e18, bytes("")), 600e18);

        uint256 vaultBalanceBefore = asset.balanceOf(address(vault));

        // Force recovery (2-step process)
        // Step 1: Initiate recovery
        vm.prank(vaultOwner);
        adapter.initiateEmergencyRecovery();
        assertTrue(adapter.emergencyRecoveryPending());

        // Step 2: Wait for timelock and execute
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(vaultOwner);
        adapter.forceRecovery();

        // Emergency mode is set
        assertTrue(adapter.emergencyMode());
        assertFalse(adapter.emergencyRecoveryPending());

        // Funds recovered to vault
        assertTrue(asset.balanceOf(address(vault)) > vaultBalanceBefore);

        // Reset emergency mode
        vm.prank(vaultOwner);
        adapter.resetEmergencyMode();
        assertFalse(adapter.emergencyMode());
    }

    /// @notice Test valuation with fallback
    function testValuationFallback() public {
        // Setup: Allocate and set initial valuation
        vm.prank(depositor);
        vault.deposit(1000e18, depositor);

        vm.prank(allocator);
        vault.allocate(address(adapter), abi.encode(STRATEGY_A, 400e18, bytes("")), 400e18);

        // Set initial valuation
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, 420e18, 95, 1, signer1Key);
        valuer.updateValue(STRATEGY_A, 420e18, 95, 1, signatures);

        // Set fallback value
        vm.prank(vaultOwner);
        valuer.setFallbackValue(STRATEGY_A, 400e18);

        // Fast forward past staleness (25 hours > MAX_STALENESS of 24 hours)
        vm.warp(block.timestamp + 25 hours);

        // Should use fallback value
        assertEq(valuer.getValue(STRATEGY_A), 400e18);
    }

    /* HELPER FUNCTIONS */

    function _signValue(
        bytes32 strategyId,
        uint256 value,
        uint256 confidence,
        uint256 nonce,
        uint256 privateKey
    ) internal view returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encode(
            strategyId,
            value,
            confidence,
            nonce,
            block.chainid,
            address(valuer)
        ));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    function _signBatchHash(bytes32 batchHash, uint256 privateKey) internal pure returns (bytes memory) {
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", batchHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }
}

// ============ Mock Contracts ============

contract MockERC20 is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}