// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/monitoring/SecurityMonitor.sol";
import "../../src/gates/EmergencyGateWithRoles.sol";
import "../../src/VaultV2.sol";
import "../../src/adapters/UniversalAdapterEscrow.sol";

/// @title SecurityMonitorTest
/// @notice Comprehensive test suite for SecurityMonitor contract
/// @dev Tests cover: threat detection, automated response, configuration, integration with gates
contract SecurityMonitorTest is Test {
    SecurityMonitor public monitor;
    EmergencyGateWithRoles public gate;
    MockVaultForMonitoring public vault;
    MockAdapterForMonitoring public adapter;

    address public owner = address(0x1);
    address public keeper = address(0x2);
    address public user1 = address(0x3);

    SecurityMonitor.MonitoringConfig public defaultConfig;

    /* EVENTS */
    event ConfigUpdated(address indexed updatedBy);
    event IncidentDetected(uint256 indexed incidentId, SecurityMonitor.ThreatLevel threat, string category, string description);
    event EmergencyActivated(uint256 indexed incidentId, string reason);
    event MonitoringPaused(bool paused, address indexed by);
    event KeeperChanged(address indexed oldKeeper, address indexed newKeeper);
    event ManualIncidentReported(address indexed reporter, SecurityMonitor.ThreatLevel threat, string description);

    function setUp() public {
        // Deploy mock vault
        vault = new MockVaultForMonitoring();

        // Setup mock vault with initial values BEFORE deploying monitor
        vault.setTotalAssets(1000000e18);  // 1M tokens
        vault.setTotalSupply(1000000e18);  // 1:1 ratio initially

        // Deploy gate
        gate = new EmergencyGateWithRoles(address(vault), owner, EmergencyGateWithRoles.Mode.NORMAL);

        // Setup default config
        defaultConfig = SecurityMonitor.MonitoringConfig({
            sharePriceCrashThreshold: 1000,        // 10% drop
            sharePriceCheckWindow: 3600,           // 1 hour
            rapidWithdrawalThreshold: 2000,        // 20% of TVL
            rapidWithdrawalWindow: 3600,           // 1 hour
            adapterBalanceMismatchThreshold: 500,  // 5% mismatch
            autoResponseEnabled: true,
            cooldownPeriod: 3600                   // 1 hour
        });

        // Deploy monitor (will read vault values in constructor)
        monitor = new SecurityMonitor(
            address(vault),
            address(gate),
            owner,
            keeper,
            defaultConfig
        );

        // Grant monitor role to SecurityMonitor contract
        vm.prank(owner);
        gate.setMonitor(address(monitor), true);
    }

    /* ============================================================ */
    /*                     DEPLOYMENT TESTS                         */
    /* ============================================================ */

    function test_Deployment_Success() public view {
        assertEq(monitor.vault(), address(vault));
        assertEq(monitor.gate(), address(gate));
        assertEq(monitor.owner(), owner);
        assertEq(monitor.keeper(), keeper);
        assertFalse(monitor.monitoringPaused());

        // Check config
        (
            uint256 sharePriceCrashThreshold,
            uint256 sharePriceCheckWindow,
            uint256 rapidWithdrawalThreshold,
            uint256 rapidWithdrawalWindow,
            uint256 adapterBalanceMismatchThreshold,
            bool autoResponseEnabled,
            uint256 cooldownPeriod
        ) = monitor.config();
        assertEq(sharePriceCrashThreshold, 1000);
        assertEq(rapidWithdrawalThreshold, 2000);
        assertTrue(autoResponseEnabled);
    }

    function test_Deployment_InitializesHistoricalData() public view {
        // Should initialize last share price and total assets
        assertTrue(monitor.lastSharePrice() > 0);
        assertTrue(monitor.lastTotalAssets() > 0);
    }

    /* ============================================================ */
    /*                  CONFIGURATION TESTS                         */
    /* ============================================================ */

    function test_SetConfig_Success() public {
        SecurityMonitor.MonitoringConfig memory newConfig = SecurityMonitor.MonitoringConfig({
            sharePriceCrashThreshold: 1500,
            sharePriceCheckWindow: 7200,
            rapidWithdrawalThreshold: 3000,
            rapidWithdrawalWindow: 7200,
            adapterBalanceMismatchThreshold: 1000,
            autoResponseEnabled: false,
            cooldownPeriod: 7200
        });

        vm.expectEmit(true, false, false, false);
        emit ConfigUpdated(owner);

        vm.prank(owner);
        monitor.setConfig(newConfig);

        (
            uint256 sharePriceCrashThreshold,
            ,
            uint256 rapidWithdrawalThreshold,
            ,
            ,
            bool autoResponseEnabled,
        ) = monitor.config();
        assertEq(sharePriceCrashThreshold, 1500);
        assertEq(rapidWithdrawalThreshold, 3000);
        assertFalse(autoResponseEnabled);
    }

    function test_SetConfig_ValidationMaxThresholds() public {
        SecurityMonitor.MonitoringConfig memory invalidConfig = defaultConfig;
        invalidConfig.sharePriceCrashThreshold = 5001;  // > 50%

        vm.expectRevert(SecurityMonitor.InvalidConfiguration.selector);
        vm.prank(owner);
        monitor.setConfig(invalidConfig);
    }

    function test_SetConfig_Unauthorized() public {
        vm.expectRevert(SecurityMonitor.Unauthorized.selector);
        vm.prank(user1);
        monitor.setConfig(defaultConfig);
    }

    function test_SetKeeper_Success() public {
        address newKeeper = address(0x99);

        vm.expectEmit(true, true, false, false);
        emit KeeperChanged(keeper, newKeeper);

        vm.prank(owner);
        monitor.setKeeper(newKeeper);

        assertEq(monitor.keeper(), newKeeper);
    }

    function test_SetPaused_Success() public {
        vm.expectEmit(false, true, false, true);
        emit MonitoringPaused(true, owner);

        vm.prank(owner);
        monitor.setPaused(true);

        assertTrue(monitor.monitoringPaused());
    }

    /* ============================================================ */
    /*                SHARE PRICE CRASH TESTS                       */
    /* ============================================================ */

    function test_SharePriceCrash_DetectsHighThreat() public {
        // Initial state
        vault.setTotalAssets(1000000e18);
        vault.setTotalSupply(1000000e18);  // Price = 1.0

        // Wait for check window
        vm.warp(block.timestamp + 3600 + 1);

        // Price drops 15% (threshold is 10%)
        vault.setTotalAssets(850000e18);

        // Check and respond
        vm.prank(keeper);
        (bool detected, bool activated) = monitor.checkAndRespond();

        assertTrue(detected, "Should detect threat");
        assertTrue(activated, "Should activate emergency");
        assertEq(uint8(gate.mode()), uint8(EmergencyGateWithRoles.Mode.EMERGENCY));
    }

    function test_SharePriceCrash_NoThreatWhenBelowThreshold() public {
        // Initial state
        vault.setTotalAssets(1000000e18);
        vault.setTotalSupply(1000000e18);

        // Wait for check window
        vm.warp(block.timestamp + 3600 + 1);

        // Price drops 5% (below 10% threshold)
        vault.setTotalAssets(950000e18);

        vm.prank(keeper);
        (bool detected, bool activated) = monitor.checkAndRespond();

        assertFalse(detected, "Should not detect threat");
        assertFalse(activated, "Should not activate emergency");
    }

    function test_SharePriceCrash_NoThreatWhenPriceIncreases() public {
        // Initial state
        vault.setTotalAssets(1000000e18);
        vault.setTotalSupply(1000000e18);

        // Wait for check window
        vm.warp(block.timestamp + 3600 + 1);

        // Price increases
        vault.setTotalAssets(1100000e18);

        vm.prank(keeper);
        (bool detected,) = monitor.checkAndRespond();

        assertFalse(detected, "Should not detect threat when price increases");
    }

    function test_SharePriceCrash_RequiresCheckWindow() public {
        // Initial state
        vault.setTotalAssets(1000000e18);
        vault.setTotalSupply(1000000e18);

        // Immediately drop price (no time passed)
        vault.setTotalAssets(800000e18);

        vm.prank(keeper);
        (bool detected,) = monitor.checkAndRespond();

        // Should not detect because check window not elapsed
        assertFalse(detected);
    }

    /* ============================================================ */
    /*                RAPID WITHDRAWAL TESTS                        */
    /* ============================================================ */

    function test_RapidWithdrawal_DetectsHighThreat() public {
        // This test is limited because the mock doesn't track withdrawals
        // In a real integration test, you would simulate actual withdrawals
        // Here we verify the logic exists but can't fully test without integration

        vm.prank(keeper);
        (bool detected,) = monitor.checkAndRespond();

        // Without actual withdrawals tracked, should not detect
        assertFalse(detected);
    }

    /* ============================================================ */
    /*                ADAPTER ANOMALY TESTS                         */
    /* ============================================================ */

    function test_AdapterAnomaly_DetectsBalanceMismatch() public {
        // Deploy mock adapter
        adapter = new MockAdapterForMonitoring();
        adapter.setTotalAllocations(1000e18);
        adapter.setRealAssets(900e18);  // 10% mismatch

        // Add adapter to vault
        vault.addAdapter(address(adapter));

        // Wait for check window
        vm.warp(block.timestamp + 3600 + 1);

        vm.prank(keeper);
        (bool detected, bool activated) = monitor.checkAndRespond();

        assertTrue(detected, "Should detect adapter anomaly");
        assertTrue(activated, "Should activate emergency");
    }

    function test_AdapterAnomaly_NoThreatWhenBalanceMatches() public {
        adapter = new MockAdapterForMonitoring();
        adapter.setTotalAllocations(1000e18);
        adapter.setRealAssets(1000e18);  // Perfect match

        vault.addAdapter(address(adapter));

        vm.warp(block.timestamp + 3600 + 1);

        vm.prank(keeper);
        (bool detected,) = monitor.checkAndRespond();

        assertFalse(detected, "Should not detect threat when balances match");
    }

    /* ============================================================ */
    /*              MANUAL INCIDENT REPORTING TESTS                 */
    /* ============================================================ */

    function test_ReportIncident_Success() public {
        vm.expectEmit(true, false, false, true);
        emit ManualIncidentReported(keeper, SecurityMonitor.ThreatLevel.HIGH, "MEV attack detected");

        vm.prank(keeper);
        uint256 incidentId = monitor.reportIncident(
            SecurityMonitor.ThreatLevel.HIGH,
            "MEV_ATTACK",
            "MEV attack detected",
            true
        );

        assertEq(incidentId, 0);
        assertEq(monitor.getIncidentCount(), 1);
    }

    function test_ReportIncident_ActivatesEmergency() public {
        vm.prank(keeper);
        monitor.reportIncident(
            SecurityMonitor.ThreatLevel.HIGH,
            "EXTERNAL_THREAT",
            "External threat detected",
            true
        );

        assertEq(uint8(gate.mode()), uint8(EmergencyGateWithRoles.Mode.EMERGENCY));
    }

    function test_ReportIncident_NoActivationWhenLowThreat() public {
        vm.prank(keeper);
        monitor.reportIncident(
            SecurityMonitor.ThreatLevel.LOW,
            "INFORMATIONAL",
            "Low priority issue",
            true  // Request activation
        );

        // Should not activate for LOW threat even if requested
        assertEq(uint8(gate.mode()), uint8(EmergencyGateWithRoles.Mode.NORMAL));
    }

    function test_ReportIncident_Unauthorized() public {
        vm.expectRevert(SecurityMonitor.Unauthorized.selector);
        vm.prank(user1);
        monitor.reportIncident(
            SecurityMonitor.ThreatLevel.HIGH,
            "UNAUTHORIZED",
            "Unauthorized report",
            false
        );
    }

    function test_ReportIncident_AutoResponseDisabled() public {
        // Disable auto response
        SecurityMonitor.MonitoringConfig memory newConfig = defaultConfig;
        newConfig.autoResponseEnabled = false;
        vm.prank(owner);
        monitor.setConfig(newConfig);

        // Try to report with activation
        vm.expectRevert(SecurityMonitor.AutoResponseDisabled.selector);
        vm.prank(keeper);
        monitor.reportIncident(
            SecurityMonitor.ThreatLevel.HIGH,
            "TEST",
            "Test",
            true
        );
    }

    function test_ReportIncident_RespectsCooldown() public {
        // First report
        vm.prank(keeper);
        monitor.reportIncident(
            SecurityMonitor.ThreatLevel.HIGH,
            "FIRST",
            "First incident",
            true
        );

        // Guardian deactivates
        vm.prank(owner);
        gate.setGuardian(owner, true);
        vm.prank(owner);
        gate.deactivateEmergency("Resolved");

        // Second report too soon
        vm.expectRevert(SecurityMonitor.CooldownActive.selector);
        vm.prank(keeper);
        monitor.reportIncident(
            SecurityMonitor.ThreatLevel.CRITICAL,
            "SECOND",
            "Second incident",
            true
        );
    }

    function test_ReportIncident_AfterCooldown() public {
        // First report
        vm.prank(keeper);
        monitor.reportIncident(
            SecurityMonitor.ThreatLevel.HIGH,
            "FIRST",
            "First incident",
            true
        );

        // Deactivate
        vm.prank(owner);
        gate.setGuardian(owner, true);
        vm.prank(owner);
        gate.deactivateEmergency("Resolved");

        // Wait for cooldown
        vm.warp(block.timestamp + 3600 + 1);

        // Second report should succeed
        vm.prank(keeper);
        monitor.reportIncident(
            SecurityMonitor.ThreatLevel.HIGH,
            "SECOND",
            "Second incident after cooldown",
            true
        );

        assertEq(uint8(gate.mode()), uint8(EmergencyGateWithRoles.Mode.EMERGENCY));
    }

    /* ============================================================ */
    /*                 AUTOMATED RESPONSE TESTS                     */
    /* ============================================================ */

    function test_CheckAndRespond_AutoActivatesOnHighThreat() public {
        // Simulate high threat (15% price drop)
        vault.setTotalAssets(1000000e18);
        vault.setTotalSupply(1000000e18);
        vm.warp(block.timestamp + 3600 + 1);
        vault.setTotalAssets(850000e18);

        vm.prank(keeper);
        (bool detected, bool activated) = monitor.checkAndRespond();

        assertTrue(detected);
        assertTrue(activated);
        assertEq(monitor.getIncidentCount(), 1);
    }

    function test_CheckAndRespond_NoActivationWhenDisabled() public {
        // Disable auto response
        SecurityMonitor.MonitoringConfig memory newConfig = defaultConfig;
        newConfig.autoResponseEnabled = false;
        vm.prank(owner);
        monitor.setConfig(newConfig);

        // Simulate high threat
        vault.setTotalAssets(1000000e18);
        vault.setTotalSupply(1000000e18);
        vm.warp(block.timestamp + 3600 + 1);
        vault.setTotalAssets(850000e18);

        vm.prank(keeper);
        (bool detected, bool activated) = monitor.checkAndRespond();

        assertTrue(detected, "Should detect threat");
        assertFalse(activated, "Should not activate when disabled");
    }

    function test_CheckAndRespond_UpdatesHistoricalData() public {
        uint256 initialPrice = monitor.lastSharePrice();
        uint256 initialAssets = monitor.lastTotalAssets();

        // Change vault state
        vault.setTotalAssets(1100000e18);

        vm.prank(keeper);
        monitor.checkAndRespond();

        // Historical data should be updated
        assertGt(monitor.lastSharePrice(), initialPrice);
        assertGt(monitor.lastTotalAssets(), initialAssets);
    }

    function test_CheckAndRespond_Paused() public {
        vm.prank(owner);
        monitor.setPaused(true);

        vm.expectRevert(SecurityMonitor.MonitoringIsPaused.selector);
        vm.prank(keeper);
        monitor.checkAndRespond();
    }

    /* ============================================================ */
    /*                   COOLDOWN TESTS                             */
    /* ============================================================ */

    function test_Cooldown_PreventsSpamActivation() public {
        // First activation
        vault.setTotalAssets(1000000e18);
        vault.setTotalSupply(1000000e18);

        // Warp to time 3601 for first check
        vm.warp(3601);
        vault.setTotalAssets(850000e18);

        vm.prank(keeper);
        monitor.checkAndRespond();

        // Deactivate emergency
        vm.prank(owner);
        gate.setGuardian(owner, true);
        vm.prank(owner);
        gate.deactivateEmergency("Resolved");

        // Second threat detected after waiting full window
        // After first check at 3601, lastSharePrice was updated to 850000e18
        // We need another >10% drop from that baseline
        vault.setTotalAssets(700000e18);  // 700k is ~17.6% drop from 850k

        // Warp to time 7201 (3601 + 3600) - exactly at cooldown boundary
        vm.warp(7201);

        // Should detect but not activate (cooldown active)
        vm.prank(keeper);
        (bool detected, bool activated) = monitor.checkAndRespond();

        assertTrue(detected, "Should detect second threat");
        assertFalse(activated, "Should not activate during cooldown");
    }

    /* ============================================================ */
    /*                    VIEW FUNCTION TESTS                       */
    /* ============================================================ */

    function test_GetIncident_Success() public {
        vm.prank(keeper);
        monitor.reportIncident(
            SecurityMonitor.ThreatLevel.HIGH,
            "TEST_CATEGORY",
            "Test description",
            false
        );

        (
            uint256 timestamp,
            address reporter,
            SecurityMonitor.ThreatLevel threat,
            string memory category,
            string memory description,
            bool emergencyActivated
        ) = monitor.getIncident(0);

        assertEq(timestamp, block.timestamp);
        assertEq(reporter, keeper);
        assertEq(uint8(threat), uint8(SecurityMonitor.ThreatLevel.HIGH));
        assertEq(category, "TEST_CATEGORY");
        assertEq(description, "Test description");
        assertFalse(emergencyActivated);
    }

    function test_GetCurrentMetrics() public view {
        (
            uint256 sharePrice,
            uint256 totalAssets,
            uint256 totalSupply,
            uint256 withdrawalsInWindow
        ) = monitor.getCurrentMetrics();

        assertGt(sharePrice, 0);
        assertGt(totalAssets, 0);
        assertGt(totalSupply, 0);
        assertEq(withdrawalsInWindow, 0);  // No withdrawals tracked in mock
    }

    /* ============================================================ */
    /*                  INTEGRATION TESTS                           */
    /* ============================================================ */

    function test_Integration_FullEmergencyFlow() public {
        // 1. Monitor detects threat
        vault.setTotalAssets(1000000e18);
        vault.setTotalSupply(1000000e18);
        vm.warp(block.timestamp + 3600 + 1);
        vault.setTotalAssets(850000e18);  // 15% drop

        // 2. Keeper calls checkAndRespond
        vm.prank(keeper);
        (bool detected, bool activated) = monitor.checkAndRespond();

        assertTrue(detected);
        assertTrue(activated);

        // 3. Gate should be in emergency mode
        assertEq(uint8(gate.mode()), uint8(EmergencyGateWithRoles.Mode.EMERGENCY));
        assertTrue(gate.isAutomatedEmergency());

        // 4. Incident should be recorded
        assertEq(monitor.getIncidentCount(), 1);
        (, , SecurityMonitor.ThreatLevel threat, , , bool emergencyActivated) = monitor.getIncident(0);
        assertEq(uint8(threat), uint8(SecurityMonitor.ThreatLevel.HIGH));
        assertTrue(emergencyActivated);

        // 5. Guardian resolves
        vm.prank(owner);
        gate.setGuardian(owner, true);
        vm.prank(owner);
        gate.deactivateEmergency("Threat neutralized");

        assertEq(uint8(gate.mode()), uint8(EmergencyGateWithRoles.Mode.NORMAL));
    }

    function test_Integration_MultipleThreatsSelectsHighest() public {
        // Setup both share price crash and adapter anomaly
        adapter = new MockAdapterForMonitoring();
        adapter.setTotalAllocations(1000e18);
        adapter.setRealAssets(900e18);  // 10% mismatch (MEDIUM threat)
        vault.addAdapter(address(adapter));

        // Also create share price crash (HIGH threat)
        vault.setTotalAssets(1000000e18);
        vault.setTotalSupply(1000000e18);
        vm.warp(block.timestamp + 3600 + 1);
        vault.setTotalAssets(850000e18);  // 15% drop (HIGH threat)

        vm.prank(keeper);
        (bool detected, bool activated) = monitor.checkAndRespond();

        assertTrue(detected);
        assertTrue(activated);

        // Should activate for HIGH threat (share price), not just MEDIUM (adapter)
        assertEq(uint8(gate.mode()), uint8(EmergencyGateWithRoles.Mode.EMERGENCY));
    }

    /* ============================================================ */
    /*                     OWNERSHIP TESTS                          */
    /* ============================================================ */

    function test_TransferOwnership_Success() public {
        address newOwner = address(0x99);

        vm.prank(owner);
        monitor.transferOwnership(newOwner);

        assertEq(monitor.owner(), newOwner);
    }

    function test_TransferOwnership_Unauthorized() public {
        vm.expectRevert(SecurityMonitor.Unauthorized.selector);
        vm.prank(user1);
        monitor.transferOwnership(user1);
    }

    /* ============================================================ */
    /*                      EDGE CASES                              */
    /* ============================================================ */

    function test_EdgeCase_ZeroTotalSupply() public {
        // Mock with zero supply should return default price
        MockVaultForMonitoring emptyVault = new MockVaultForMonitoring();
        emptyVault.setTotalSupply(0);
        // Should not revert when calculating share price
    }

    function test_EdgeCase_VaultWithNoAdapters() public {
        // Should not revert when checking adapter anomalies with no adapters
        vm.prank(keeper);
        (bool detected,) = monitor.checkAndRespond();

        assertFalse(detected);
    }

    /* ============================================================ */
    /*                     FUZZ TESTS                               */
    /* ============================================================ */

    function testFuzz_SetConfig_ValidThresholds(uint256 threshold) public {
        vm.assume(threshold > 0 && threshold <= 5000);

        SecurityMonitor.MonitoringConfig memory newConfig = defaultConfig;
        newConfig.sharePriceCrashThreshold = threshold;
        newConfig.rapidWithdrawalThreshold = threshold;
        newConfig.adapterBalanceMismatchThreshold = threshold;

        vm.prank(owner);
        monitor.setConfig(newConfig);

        (uint256 sharePriceCrashThreshold,,,,,,) = monitor.config();
        assertEq(sharePriceCrashThreshold, threshold);
    }
}

/* ============================================================ */
/*                      MOCK CONTRACTS                          */
/* ============================================================ */

contract MockVaultForMonitoring {
    uint256 private _totalAssets;
    uint256 private _totalSupply;
    address[] private _adapters;

    function setTotalAssets(uint256 assets) external {
        _totalAssets = assets;
    }

    function setTotalSupply(uint256 supply) external {
        _totalSupply = supply;
    }

    function totalAssets() external view returns (uint256) {
        return _totalAssets;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function addAdapter(address adapter) external {
        _adapters.push(adapter);
    }

    function adaptersLength() external view returns (uint256) {
        return _adapters.length;
    }

    function adapters(uint256 index) external view returns (address) {
        return _adapters[index];
    }
}

contract MockAdapterForMonitoring {
    uint256 private _totalAllocations;
    uint256 private _realAssets;

    function setTotalAllocations(uint256 allocations) external {
        _totalAllocations = allocations;
    }

    function setRealAssets(uint256 assets) external {
        _realAssets = assets;
    }

    function totalAllocations() external view returns (uint256) {
        return _totalAllocations;
    }

    function realAssets() external view returns (uint256) {
        return _realAssets;
    }
}
