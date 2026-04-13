// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/valuers/UniversalValuerOffchain.sol";
import "../../src/adapters/UniversalAdapterEscrow.sol";
import "../../src/VaultV2.sol";
import {IUniversalValuerOffchain} from "../../src/adapters/interfaces/IUniversalValuerOffchain.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/**
 * @title UniversalValuerOffchainStaleness
 * @notice Test suite for staleness boundary behavior after security fix
 * @dev Tests the removal of Path 2 (24h-48h extended staleness window)
 */
contract UniversalValuerOffchainStaleness is Test {
    UniversalValuerOffchain public valuer;
    UniversalAdapterEscrow public adapter;
    VaultV2 public vault;
    MockERC20 public asset;

    address public owner = address(0x1);
    address public signer1;
    uint256 public signer1Key = 0x1234;

    bytes32 constant STRATEGY_A = keccak256("STRATEGY_A");
    bytes32 constant STRATEGY_B = keccak256("STRATEGY_B");

    uint256 constant MAX_STALENESS = 24 hours;
    uint256 constant ABSOLUTE_MAX_STALENESS = 48 hours;
    uint256 constant MIN_UPDATE_INTERVAL = 5 minutes;

    function setUp() public {
        asset = new MockERC20("Test", "TST", 18);

        vm.startPrank(owner);
        vault = new VaultV2(owner, address(asset));
        valuer = new UniversalValuerOffchain(owner, address(asset));
        vm.stopPrank();

        adapter = new UniversalAdapterEscrow(address(vault), address(valuer), true);

        signer1 = vm.addr(signer1Key);

        vm.startPrank(owner);
        valuer.initiateSignerChange(signer1, true, 100);
        valuer.setRequiredWeight(100);
        valuer.configureStrategy(STRATEGY_A, MIN_UPDATE_INTERVAL, MAX_STALENESS, 500, 90);
        valuer.configureStrategy(STRATEGY_B, MIN_UPDATE_INTERVAL, MAX_STALENESS, 500, 90);

        // Setup adapter strategy
        adapter.setStrategy(STRATEGY_A, owner, "", type(uint256).max);
        adapter.setStrategy(STRATEGY_B, owner, "", type(uint256).max);
        vm.stopPrank();

        // Give adapter some balance and allocate to make strategy active
        asset.mint(address(adapter), 1000e18);
        vm.startPrank(address(vault));
        bytes memory allocateData = abi.encode(
            STRATEGY_A,
            uint256(100e18),
            false,
            new IUniversalAdapterEscrow.Call[](0)
        );
        adapter.allocate(allocateData, 100e18, bytes4(0), address(0));
        vm.stopPrank();
    }

    /* STALENESS BOUNDARY TESTS */

    /// @notice Test that values at exactly maxStaleness are accepted
    function testValueAtMaxStalenessIsAccepted() public {
        // Submit initial value
        _submitValue(STRATEGY_A, 1000e18, 95, 1);

        // Warp to exactly maxStaleness
        vm.warp(block.timestamp + MAX_STALENESS);

        // Value should still be accepted
        uint256 value = valuer.getValue(STRATEGY_A);
        assertEq(value, 1000e18, "Value at maxStaleness should be accepted");
    }

    /// @notice Test that values just past maxStaleness revert
    function testValuePastMaxStalenessReverts() public {
        // Submit initial value
        _submitValue(STRATEGY_A, 1000e18, 95, 1);

        // Warp past maxStaleness
        vm.warp(block.timestamp + MAX_STALENESS + 1);

        // Value should revert
        vm.expectRevert(IUniversalValuerOffchain.ValueTooStale.selector);
        valuer.getValue(STRATEGY_A);
    }

    /// @notice Test that Path 2 (24h-48h window) no longer accepts stale values
    function testPath2RemovedNoExtendedStalenessAcceptance() public {
        // Submit initial value
        _submitValue(STRATEGY_A, 1000e18, 95, 1);

        // Warp to middle of old "extended" window (e.g., 36 hours)
        vm.warp(block.timestamp + 36 hours);

        // Before fix: This would return 1000e18
        // After fix: This should revert
        vm.expectRevert(IUniversalValuerOffchain.ValueTooStale.selector);
        valuer.getValue(STRATEGY_A);
    }

    /// @notice Test that fallback values are used when stale
    function testFallbackValueUsedWhenStale() public {
        // Submit initial value
        _submitValue(STRATEGY_A, 1000e18, 95, 1);

        // Set fallback value
        vm.prank(owner);
        valuer.setFallbackValue(STRATEGY_A, 500e18);

        // Warp past maxStaleness
        vm.warp(block.timestamp + MAX_STALENESS + 1);

        // Should return fallback value instead of reverting
        uint256 value = valuer.getValue(STRATEGY_A);
        assertEq(value, 500e18, "Fallback value should be used when stale");
    }

    /* VALUATION HEALTH TESTS */

    /// @notice Test valuation health with fresh values
    function testValuationHealthWithFreshValues() public {
        // Submit values for strategies
        _submitValue(STRATEGY_A, 1000e18, 95, 1);

        // Should be healthy with fresh values
        bool isHealthy = valuer.isValuationHealthy(address(adapter));
        assertTrue(isHealthy, "Fresh values should be healthy");
    }

    /// @notice Test valuation health with stale values (no fallback) - should be unhealthy
    function testValuationHealthWithStaleNoFallback() public {
        // Submit value
        _submitValue(STRATEGY_A, 1000e18, 95, 1);

        // Warp past maxStaleness (but not past ABSOLUTE_MAX_STALENESS)
        vm.warp(block.timestamp + MAX_STALENESS + 1);

        // Should be unhealthy
        bool isHealthy = valuer.isValuationHealthy(address(adapter));
        assertFalse(isHealthy, "Stale values should be unhealthy");
    }

    /// @notice Test valuation health uses fallback when stale (still unhealthy due to fallback usage)
    function testValuationHealthWithFallbackWhenStale() public {
        // Submit value
        _submitValue(STRATEGY_A, 1000e18, 95, 1);

        // Set fallback
        vm.prank(owner);
        valuer.setFallbackValue(STRATEGY_A, 500e18);

        // Warp past maxStaleness
        vm.warp(block.timestamp + MAX_STALENESS + 1);

        // Should be unhealthy (fallback usage marks as stale data)
        bool isHealthy = valuer.isValuationHealthy(address(adapter));
        assertFalse(isHealthy, "Fallback usage should be marked as unhealthy");
    }

    /* HEALTH CHECK TESTS */

    /// @notice Test isValuationHealthy returns true for fresh values
    function testIsValuationHealthyWithFreshValues() public {
        // Submit fresh value
        _submitValue(STRATEGY_A, 1000e18, 95, 1);

        bool isHealthy = valuer.isValuationHealthy(address(adapter));
        assertTrue(isHealthy, "Fresh values should be healthy");
    }

    /// @notice Test isValuationHealthy returns false for stale values
    function testIsValuationHealthyWithStaleValues() public {
        // Submit value
        _submitValue(STRATEGY_A, 1000e18, 95, 1);

        // Warp past maxStaleness
        vm.warp(block.timestamp + MAX_STALENESS + 1);

        bool isHealthy = valuer.isValuationHealthy(address(adapter));
        assertFalse(isHealthy, "Stale values should not be healthy");
    }

    /* PATH 4 EMERGENCY FALLBACK TESTS */

    /// @notice Test Path 4 requires maxStaleness (not ABSOLUTE_MAX_STALENESS)
    function testPath4BoundedByMaxStaleness() public {
        // First, lower the minConfidence for this test to allow lower confidence submissions
        vm.prank(owner);
        valuer.setDefaultConfidenceThreshold(50);
        vm.prank(owner);
        valuer.configureStrategy(STRATEGY_A, MIN_UPDATE_INTERVAL, MAX_STALENESS, 500, 50);

        // Submit value with lower confidence that meets emergencyMinConfidence but not minConfidence (60)
        _submitValue(STRATEGY_A, 1000e18, 60, 1); // 60 >= 50 (emergencyMinConfidence)

        // Warp past maxStaleness - Path 4 should NOT accept this anymore
        vm.warp(block.timestamp + MAX_STALENESS + 1);

        // The value should not be included in total (no fallback set)
        // Should be marked as unhealthy
        bool isHealthy = valuer.isValuationHealthy(address(adapter));
        assertFalse(isHealthy, "Should be unhealthy after maxStaleness");
    }

    /* CONSISTENCY TESTS */

    /// @notice Test consistency between getValue() and isValuationHealthy()
    function testConsistencyBetweenGetValueAndIsValuationHealthy() public {
        // Submit value
        _submitValue(STRATEGY_A, 1000e18, 95, 1);

        // Warp past maxStaleness but within ABSOLUTE_MAX_STALENESS
        vm.warp(block.timestamp + 30 hours);

        // getValue should revert
        vm.expectRevert(IUniversalValuerOffchain.ValueTooStale.selector);
        valuer.getValue(STRATEGY_A);

        // isValuationHealthy should also recognize stale data
        bool isHealthy = valuer.isValuationHealthy(address(adapter));
        assertFalse(isHealthy, "Should recognize stale data");
    }

    /* ADAPTER INTEGRATION TESTS */

    function testRealAssetsUsesPerStrategyAggregationWithoutEscrowTotalReport() public {
        _submitValue(STRATEGY_A, 100e18, 95, 1);

        assertEq(adapter.realAssets(), 100e18, "Should aggregate fresh strategy values directly");
    }

    function testRealAssetsCapsStaleAggregatedValuationToTrackedAssets() public {
        _submitValue(STRATEGY_A, 100e18, 95, 1);

        vm.prank(owner);
        valuer.setFallbackValue(STRATEGY_A, 200e18);

        vm.warp(block.timestamp + MAX_STALENESS + 1);

        uint256 staleAssets = adapter.realAssets();
        assertEq(staleAssets, 95e18, "Should haircut a tracked-assets-capped stale valuation");
    }

    /// @notice Test realAssets applies haircut when valuation is unhealthy
    /// @dev SKIPPED: Depends on getValue(ESCROW_TOTAL_ID) feature not yet implemented
    function skip_testRealAssetsAppliesHaircutWhenUnhealthy() public {
        // Allocate more to strategy (adapter already has 1000e18 and 100e18 allocated in setup)
        vm.startPrank(address(vault));
        bytes memory allocateData = abi.encode(
            STRATEGY_A,
            uint256(400e18),
            false,
            new IUniversalAdapterEscrow.Call[](0)
        );
        adapter.allocate(allocateData, 400e18, bytes4(0), address(0));
        vm.stopPrank();

        // Submit fresh value
        _submitValue(STRATEGY_A, 500e18, 95, 1);

        // Get realAssets with fresh value - no haircut
        uint256 freshAssets = adapter.realAssets();

        // Warp past maxStaleness
        vm.warp(block.timestamp + MAX_STALENESS + 1);

        // Set fallback so we get a value (otherwise reverts)
        vm.prank(owner);
        valuer.setFallbackValue(STRATEGY_A, 500e18);

        // Get realAssets with stale value - should apply haircut
        uint256 staleAssets = adapter.realAssets();

        // Stale assets should be less due to haircut (5%)
        assertLt(staleAssets, freshAssets, "Stale assets should be less due to haircut");
        // Expected: 500e18 * 0.95 = 475e18 (approximately, plus idle balance)
    }

    /* HELPER FUNCTIONS */

    function _submitValue(bytes32 strategyId, uint256 value, uint256 confidence, uint256 nonce) internal {
        uint256 expiry = block.timestamp + 1 hours;
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(strategyId, value, confidence, nonce, expiry, signer1Key);
        vm.prank(owner);
        valuer.updateValue(strategyId, value, confidence, nonce, expiry, signatures);
    }

    function _signValue(
        bytes32 strategyId,
        uint256 value,
        uint256 confidence,
        uint256 nonce,
        uint256 expiry,
        uint256 privateKey
    ) internal view returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encode(
            strategyId,
            value,
            confidence,
            nonce,
            expiry,
            block.chainid,
            address(valuer)
        ));

        bytes32 ethSignedHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            messageHash
        ));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }
}
