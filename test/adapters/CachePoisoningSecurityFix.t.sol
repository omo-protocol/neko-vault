// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {UniversalAdapterEscrow} from "../../src/adapters/UniversalAdapterEscrow.sol";
import {IUniversalAdapterEscrow} from "../../src/adapters/interfaces/IUniversalAdapterEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockAgent} from "../mocks/MockAgent.sol";

/// @title CachePoisoningSecurityFix
/// @notice Test suite validating the fix for cache poisoning vulnerability
/// @dev Tests that state-changing functions no longer update cache, preventing stale data poisoning
contract CachePoisoningSecurityFix is Test {
    UniversalAdapterEscrow adapter;
    MockERC20 asset;
    MockValuer valuer;
    MockVault vault;
    MockAgent mockAgent;
    address owner;
    address keeper;

    bytes32 strategyId = keccak256("TEST_STRATEGY");

    function setUp() public {
        owner = makeAddr("owner");
        keeper = makeAddr("keeper");

        asset = new MockERC20("Test Asset", "TEST", 18);
        valuer = new MockValuer();
        mockAgent = new MockAgent();

        // Create vault as owner so adapter gets correct owner
        vm.startPrank(owner);
        vault = new MockVault(address(asset));

        adapter = new UniversalAdapterEscrow(address(vault));

        // Setup a test strategy
        adapter.setStrategy(strategyId, address(mockAgent), "", type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Test that allocate() does NOT update cached valuation
    /// @dev This prevents cache poisoning from stale valuer data in same transaction
    function test_AllocateDoesNotUpdateCache() public {
        // Setup: Give adapter some tokens
        asset.mint(address(adapter), 1000e18);

        // Record initial cache state
        (uint256 cachedBefore, uint256 timestampBefore,) = adapter.getCachedValuation();

        // Wait to ensure timestamp would change if cache was updated
        vm.warp(block.timestamp + 100);

        // Execute allocate
        vm.startPrank(address(vault));
        bytes memory allocData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        adapter.allocate(allocData, 500e18, bytes4(0), address(0));
        vm.stopPrank();

        // Verify cache was NOT updated
        (uint256 cachedAfter, uint256 timestampAfter,) = adapter.getCachedValuation();
        assertEq(cachedAfter, cachedBefore, "Cache value should not change after allocate");
        assertEq(timestampAfter, timestampBefore, "Cache timestamp should not change after allocate");
    }

    /// @notice Test that deallocate() does NOT update cached valuation
    function test_DeallocateDoesNotUpdateCache() public {
        // Setup: Allocate first
        asset.mint(address(adapter), 1000e18);
        vm.startPrank(address(vault));
        bytes memory allocData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        adapter.allocate(allocData, 500e18, bytes4(0), address(0));

        // Record cache state
        (uint256 cachedBefore, uint256 timestampBefore,) = adapter.getCachedValuation();
        vm.warp(block.timestamp + 100);

        // Execute deallocate
        bytes memory deallocData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        adapter.deallocate(deallocData, 250e18, bytes4(0), address(0));
        vm.stopPrank();

        // Verify cache was NOT updated
        (uint256 cachedAfter, uint256 timestampAfter,) = adapter.getCachedValuation();
        assertEq(cachedAfter, cachedBefore, "Cache value should not change after deallocate");
        assertEq(timestampAfter, timestampBefore, "Cache timestamp should not change after deallocate");
    }

    /// @notice Test that executeStrategy() does NOT update cached valuation
    function test_ExecuteStrategyDoesNotUpdateCache() public {
        // Setup
        asset.mint(address(adapter), 1000e18);
        vm.startPrank(address(vault));
        bytes memory allocData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        adapter.allocate(allocData, 500e18, bytes4(0), address(0));
        vm.stopPrank();

        // Whitelist a dummy call
        vm.prank(owner);
        adapter.updateWhitelist(address(valuer), bytes4(0), true, 0);

        // Record cache state
        (uint256 cachedBefore, uint256 timestampBefore,) = adapter.getCachedValuation();
        vm.warp(block.timestamp + 100);

        // Execute strategy
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(valuer),
            data: abi.encodeWithSignature("dummyCall()"),
            value: 0
        });

        vm.prank(owner);
        adapter.executeStrategy(strategyId, calls);

        // Verify cache was NOT updated
        (uint256 cachedAfter, uint256 timestampAfter,) = adapter.getCachedValuation();
        assertEq(cachedAfter, cachedBefore, "Cache value should not change after executeStrategy");
        assertEq(timestampAfter, timestampBefore, "Cache timestamp should not change after executeStrategy");
    }

    /// @notice Test that refreshCachedValuation() successfully updates cache
    /// @dev This is the ONLY function that should update the cache
    function test_RefreshCachedValuationUpdatesCache() public {
        // Setup - allocate all funds so there's no excess idle
        asset.mint(address(adapter), 500e18);
        vm.startPrank(address(vault));
        bytes memory allocData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        adapter.allocate(allocData, 500e18, bytes4(0), address(0));
        vm.stopPrank();

        // Set agent to return specific value (with some yield)
        mockAgent.setAssets(520e18);

        // Record cache state before refresh
        (uint256 cachedBefore, uint256 timestampBefore,) = adapter.getCachedValuation();

        vm.warp(block.timestamp + 100);

        // Call refreshCachedValuation
        vm.expectEmit(true, true, true, true);
        emit CachedValuationRefreshed(520e18, block.timestamp);
        vm.prank(keeper);
        adapter.refreshCachedValuation();

        // Verify cache WAS updated
        (uint256 cachedAfter, uint256 timestampAfter,) = adapter.getCachedValuation();
        assertEq(cachedAfter, 520e18, "Cache value should be updated to valuer value");
        assertEq(timestampAfter, block.timestamp, "Cache timestamp should be updated to current time");
        assertTrue(cachedAfter != cachedBefore || timestampAfter != timestampBefore, "Cache state should change");
    }

    /// @notice Test that refreshCachedValuation() accepts any valid agent value
    function test_RefreshCachedValuationAcceptsLowValue() public {
        // Setup - allocate all funds
        asset.mint(address(adapter), 500e18);
        vm.startPrank(address(vault));
        bytes memory allocData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        adapter.allocate(allocData, 500e18, bytes4(0), address(0));
        vm.stopPrank();

        // Agent reports low value — should succeed (no sanity bounds)
        mockAgent.setAssets(300e18);
        adapter.refreshCachedValuation();

        (uint256 cached,,) = adapter.getCachedValuation();
        assertEq(cached, 300e18);
    }

    /// @notice Test that refreshCachedValuation() accepts high values
    function test_RefreshCachedValuationAcceptsHighValue() public {
        // Setup - allocate all funds
        asset.mint(address(adapter), 500e18);
        vm.startPrank(address(vault));
        bytes memory allocData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        adapter.allocate(allocData, 500e18, bytes4(0), address(0));
        vm.stopPrank();

        // Agent reports high value — should succeed (no sanity bounds)
        mockAgent.setAssets(800e18);
        adapter.refreshCachedValuation();

        (uint256 cached,,) = adapter.getCachedValuation();
        assertEq(cached, 800e18);
    }

    /// @notice Test the full workflow: state change -> keeper updates valuer -> refresh cache
    /// @dev This demonstrates the correct security pattern
    function test_FullSecureWorkflow() public {
        // Step 1: User allocates funds
        asset.mint(address(adapter), 500e18);
        vm.startPrank(address(vault));
        bytes memory allocData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        adapter.allocate(allocData, 500e18, bytes4(0), address(0));
        vm.stopPrank();

        // Verify cache was NOT updated by allocate
        (, uint256 timestampAfter1,) = adapter.getCachedValuation();
        assertEq(timestampAfter1, 0, "Cache should not be updated by allocate");

        // Step 2: Time passes, agent reports yield
        vm.warp(block.timestamp + 300); // 5 minutes later
        mockAgent.setAssets(520e18); // Strategy earned some yield

        // Step 3: Keeper refreshes cache with validated data
        vm.prank(keeper);
        adapter.refreshCachedValuation();

        // Verify cache is now updated with validated data
        (uint256 cachedAfter2, uint256 timestampAfter2,) = adapter.getCachedValuation();
        assertEq(cachedAfter2, 520e18, "Cache should reflect validated valuation");
        assertEq(timestampAfter2, block.timestamp, "Cache timestamp should be current");
    }

    /// @notice Event emitted when cached valuation is refreshed
    event CachedValuationRefreshed(uint256 newValue, uint256 timestamp);
}

/// @notice Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Mock vault for testing
contract MockVault {
    address public asset;
    address public owner;

    constructor(address _asset) {
        asset = _asset;
        owner = msg.sender;
    }
}

/// @notice Mock valuer for testing
contract MockValuer {
    uint256 private _value;

    function setValue(uint256 value) external {
        _value = value;
    }

    function getValue(bytes32) external view returns (uint256) {
        return _value;
    }

    function dummyCall() external pure returns (bool) {
        return true;
    }
}
