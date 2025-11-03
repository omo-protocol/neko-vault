// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "../VaultV2.sol";
import "../adapters/UniversalAdapterEscrow.sol";
import "../gates/EmergencyGateWithRoles.sol";

/// @title SecurityMonitor
/// @notice Automated security monitoring contract that detects incidents and triggers emergency gate
/// @dev This contract should be granted MONITOR role in EmergencyGateWithRoles
///
/// DETECTION CAPABILITIES:
/// 1. Share price crash detection (>X% drop)
/// 2. Rapid withdrawal detection (>X% of TVL in Y seconds)
/// 3. Adapter balance anomaly (expected vs actual mismatch)
/// 4. External trigger from off-chain monitoring (via keeper)
///
/// INTEGRATION WITH WORKER SYSTEM:
/// - Off-chain worker calls checkAndRespond() periodically
/// - Worker monitors logs and calls reportIncident() when anomaly detected
/// - Contract automatically activates emergency gate if thresholds exceeded
///
/// SAFETY FEATURES:
/// - Configurable thresholds (not hardcoded)
/// - Cooldown period to prevent spam
/// - Owner can disable auto-response
/// - Multiple detection methods
/// - Event emission for monitoring
contract SecurityMonitor {

    /* TYPES */

    enum ThreatLevel {
        NONE,
        LOW,
        MEDIUM,
        HIGH,
        CRITICAL
    }

    struct MonitoringConfig {
        // Share price monitoring
        uint256 sharePriceCrashThreshold;  // BPS (e.g., 1000 = 10% drop)
        uint256 sharePriceCheckWindow;      // Seconds

        // Withdrawal monitoring
        uint256 rapidWithdrawalThreshold;   // BPS of TVL (e.g., 2000 = 20% of TVL)
        uint256 rapidWithdrawalWindow;      // Seconds

        // Adapter monitoring
        uint256 adapterBalanceMismatchThreshold;  // BPS (e.g., 500 = 5% mismatch)

        // Auto-response settings
        bool autoResponseEnabled;
        uint256 cooldownPeriod;  // Seconds between auto-responses
    }

    struct IncidentReport {
        uint256 timestamp;
        address reporter;
        ThreatLevel threat;
        string category;  // "SHARE_PRICE_CRASH", "RAPID_WITHDRAWAL", "ADAPTER_ANOMALY", "EXTERNAL"
        string description;
        bool emergencyActivated;
    }

    /* IMMUTABLES */

    address public immutable vault;
    address public immutable gate;

    /* STORAGE */

    address public owner;
    address public keeper;  // Off-chain worker that can call monitoring functions

    MonitoringConfig public config;

    // Historical data for monitoring
    uint256 public lastSharePrice;
    uint256 public lastSharePriceUpdate;
    uint256 public lastTotalAssets;
    uint256 public lastTotalAssetsUpdate;

    // Withdrawal tracking
    uint256 public withdrawalsInWindow;
    uint256 public withdrawalWindowStart;

    // Incident history
    IncidentReport[] public incidents;
    uint256 public lastEmergencyActivation;

    // Paused state
    bool public monitoringPaused;

    /* EVENTS */

    event ConfigUpdated(address indexed updatedBy);
    event IncidentDetected(uint256 indexed incidentId, ThreatLevel threat, string category, string description);
    event EmergencyActivated(uint256 indexed incidentId, string reason);
    event MonitoringPaused(bool paused, address indexed by);
    event KeeperChanged(address indexed oldKeeper, address indexed newKeeper);
    event ManualIncidentReported(address indexed reporter, ThreatLevel threat, string description);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);

    /* ERRORS */

    error Unauthorized();
    error InvalidConfiguration();
    error MonitoringIsPaused();
    error CooldownActive();
    error AutoResponseDisabled();

    /* CONSTRUCTOR */

    constructor(
        address _vault,
        address _gate,
        address _owner,
        address _keeper,
        MonitoringConfig memory _config
    ) {
        // SECURITY FIX Issue #4: Validate addresses
        require(
            _vault != address(0) && _gate != address(0) && _owner != address(0),
            "Invalid address"
        );

        vault = _vault;
        gate = _gate;
        owner = _owner;
        keeper = _keeper;
        config = _config;

        // Initialize historical data
        lastSharePrice = _getSharePrice();
        lastSharePriceUpdate = block.timestamp;
        lastTotalAssets = VaultV2(_vault).totalAssets();
        lastTotalAssetsUpdate = block.timestamp;
        withdrawalWindowStart = block.timestamp;
    }

    /* MODIFIERS */

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyKeeperOrOwner() {
        if (msg.sender != owner && msg.sender != keeper) revert Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (monitoringPaused) revert MonitoringIsPaused();
        _;
    }

    /* OWNER FUNCTIONS */

    function setConfig(MonitoringConfig calldata _config) external onlyOwner {
        // Validate config
        if (_config.sharePriceCrashThreshold > 5000) revert InvalidConfiguration();  // Max 50% drop
        if (_config.rapidWithdrawalThreshold > 5000) revert InvalidConfiguration();  // Max 50% of TVL
        if (_config.adapterBalanceMismatchThreshold > 5000) revert InvalidConfiguration();  // Max 50% mismatch

        config = _config;
        emit ConfigUpdated(msg.sender);
    }

    function setKeeper(address newKeeper) external onlyOwner {
        address oldKeeper = keeper;
        keeper = newKeeper;
        emit KeeperChanged(oldKeeper, newKeeper);
    }

    function setPaused(bool paused) external onlyOwner {
        monitoringPaused = paused;
        emit MonitoringPaused(paused, msg.sender);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        // SECURITY FIX Issue #4: Validate new owner address
        require(newOwner != address(0), "Invalid owner");
        address oldOwner = owner;
        owner = newOwner;
        emit OwnerChanged(oldOwner, newOwner);
    }

    /* KEEPER FUNCTIONS (Called by off-chain worker) */

    /// @notice Main monitoring function - checks all threat vectors
    /// @dev Called periodically by off-chain worker
    /// @return detected True if any threat detected
    /// @return activated True if emergency was activated
    function checkAndRespond() external onlyKeeperOrOwner whenNotPaused returns (
        bool detected,
        bool activated
    ) {
        // Check share price crash
        ThreatLevel threat1 = _checkSharePriceCrash();

        // Check rapid withdrawals
        ThreatLevel threat2 = _checkRapidWithdrawals();

        // Check adapter balance anomalies
        ThreatLevel threat3 = _checkAdapterAnomalies();

        // Determine max threat level
        ThreatLevel maxThreat = _maxThreatLevel(threat1, _maxThreatLevel(threat2, threat3));

        if (maxThreat >= ThreatLevel.HIGH) {
            detected = true;

            // Record incident
            string memory category = "AUTOMATED_DETECTION";
            string memory description = _formatThreatDescription(threat1, threat2, threat3);

            uint256 incidentId = _recordIncident(
                msg.sender,
                maxThreat,
                category,
                description
            );

            emit IncidentDetected(incidentId, maxThreat, category, description);

            // Auto-activate emergency if enabled and conditions met
            if (config.autoResponseEnabled) {
                // Allow first activation (lastEmergencyActivation == 0) or after cooldown
                if (lastEmergencyActivation == 0 ||
                    block.timestamp > lastEmergencyActivation + config.cooldownPeriod) {
                    _activateEmergency(incidentId, description);
                    activated = true;
                }
            }
        }

        // Update historical data
        _updateHistoricalData();

        return (detected, activated);
    }

    /// @notice Manual incident reporting by keeper (for off-chain detected threats)
    /// @dev Use when off-chain monitoring detects anomalies not visible on-chain
    function reportIncident(
        ThreatLevel threat,
        string calldata category,
        string calldata description,
        bool activateEmergency
    ) external onlyKeeperOrOwner whenNotPaused returns (uint256 incidentId) {
        // Record incident
        incidentId = _recordIncident(msg.sender, threat, category, description);
        emit IncidentDetected(incidentId, threat, category, description);
        emit ManualIncidentReported(msg.sender, threat, description);

        // Activate emergency if requested and authorized
        if (activateEmergency && threat >= ThreatLevel.HIGH) {
            if (!config.autoResponseEnabled) revert AutoResponseDisabled();
            // Check cooldown (skip for first activation)
            if (lastEmergencyActivation != 0 &&
                block.timestamp <= lastEmergencyActivation + config.cooldownPeriod) {
                revert CooldownActive();
            }
            _activateEmergency(incidentId, description);
        }

        return incidentId;
    }

    /* INTERNAL MONITORING FUNCTIONS */

    /// @notice Check for share price crash
    function _checkSharePriceCrash() internal view returns (ThreatLevel) {
        // SECURITY FIX Issue #3: Skip detection if baseline is not initialized or vault is empty
        // This prevents false positives when vault empties to totalSupply == 0
        if (lastSharePrice == 0) {
            return ThreatLevel.NONE;
        }

        if (VaultV2(vault).totalSupply() == 0) {
            return ThreatLevel.NONE;
        }

        if (block.timestamp < lastSharePriceUpdate + config.sharePriceCheckWindow) {
            return ThreatLevel.NONE;
        }

        uint256 currentPrice = _getSharePrice();
        if (currentPrice >= lastSharePrice) {
            return ThreatLevel.NONE;  // Price increased or stable
        }

        uint256 dropBps = ((lastSharePrice - currentPrice) * 10000) / lastSharePrice;

        if (dropBps >= config.sharePriceCrashThreshold) {
            // Classify threat level based on drop magnitude
            if (dropBps >= config.sharePriceCrashThreshold * 2) return ThreatLevel.CRITICAL;
            if (dropBps >= config.sharePriceCrashThreshold * 3 / 2) return ThreatLevel.HIGH;
            return ThreatLevel.MEDIUM;
        }

        return ThreatLevel.NONE;
    }

    /// @notice Check for rapid withdrawals
    function _checkRapidWithdrawals() internal view returns (ThreatLevel) {
        // SECURITY FIX Issue #2: Disable check if misconfigured
        if (config.rapidWithdrawalThreshold == 0 || config.rapidWithdrawalWindow == 0) {
            return ThreatLevel.NONE;
        }

        // Reset window if expired
        if (block.timestamp > withdrawalWindowStart + config.rapidWithdrawalWindow) {
            return ThreatLevel.NONE;
        }

        uint256 totalAssets = VaultV2(vault).totalAssets();
        if (totalAssets == 0) return ThreatLevel.NONE;

        uint256 withdrawalBps = (withdrawalsInWindow * 10000) / totalAssets;

        if (withdrawalBps >= config.rapidWithdrawalThreshold) {
            // Classify threat level
            if (withdrawalBps >= config.rapidWithdrawalThreshold * 2) return ThreatLevel.CRITICAL;
            if (withdrawalBps >= config.rapidWithdrawalThreshold * 3 / 2) return ThreatLevel.HIGH;
            return ThreatLevel.MEDIUM;
        }

        return ThreatLevel.NONE;
    }

    /// @notice Check for adapter balance anomalies
    function _checkAdapterAnomalies() internal view returns (ThreatLevel) {
        VaultV2 vaultContract = VaultV2(vault);
        uint256 adapterCount = vaultContract.adaptersLength();

        for (uint256 i = 0; i < adapterCount; i++) {
            address adapter = vaultContract.adapters(i);

            // Skip if not UniversalAdapterEscrow
            // (We can only check adapters that expose realAssets)
            try IAdapter(adapter).realAssets() returns (uint256 realAssets) {
                // Check if adapter has allocation tracking (UniversalAdapterEscrow)
                try this.checkAdapterBalance(adapter) returns (ThreatLevel threat) {
                    if (threat != ThreatLevel.NONE) {
                        return threat;
                    }
                } catch {
                    // Adapter doesn't support detailed checking, skip
                }
            } catch {
                // Adapter doesn't support realAssets, skip
            }
        }

        return ThreatLevel.NONE;
    }

    /// @notice External function to check adapter balance (to use try-catch)
    function checkAdapterBalance(address adapter) external view returns (ThreatLevel) {
        require(msg.sender == address(this), "Internal only");

        UniversalAdapterEscrow adapterContract = UniversalAdapterEscrow(adapter);
        uint256 totalAllocations = adapterContract.totalAllocations();
        uint256 realAssets = adapterContract.realAssets();

        if (totalAllocations == 0) return ThreatLevel.NONE;

        // SECURITY FIX Issue #1: Ignore surplus mismatches (realAssets >= totalAllocations).
        // Surpluses can be caused by third-party donations and should not trigger emergencies.
        // Only treat deficits (realAssets < totalAllocations) as anomalies.
        if (realAssets >= totalAllocations) {
            return ThreatLevel.NONE;
        }

        // Calculate deficit only
        uint256 diff = totalAllocations - realAssets;
        uint256 mismatchBps = (diff * 10000) / totalAllocations;

        if (mismatchBps >= config.adapterBalanceMismatchThreshold) {
            // Classify threat level
            if (mismatchBps >= config.adapterBalanceMismatchThreshold * 3) return ThreatLevel.CRITICAL;
            if (mismatchBps >= config.adapterBalanceMismatchThreshold * 2) return ThreatLevel.HIGH;
            return ThreatLevel.MEDIUM;
        }

        return ThreatLevel.NONE;
    }

    /* INTERNAL HELPER FUNCTIONS */

    function _getSharePrice() internal view returns (uint256) {
        VaultV2 vaultContract = VaultV2(vault);
        uint256 totalSupply = vaultContract.totalSupply();

        // SECURITY FIX Issue #3: Return 0 when vault is empty (uninitialized baseline)
        // This prevents false crash detection for non-18-decimal assets
        if (totalSupply == 0) return 0;

        uint256 totalAssets = vaultContract.totalAssets();
        return (totalAssets * 1e18) / totalSupply;
    }

    function _maxThreatLevel(ThreatLevel a, ThreatLevel b) internal pure returns (ThreatLevel) {
        return a > b ? a : b;
    }

    function _formatThreatDescription(
        ThreatLevel sharePriceThreat,
        ThreatLevel withdrawalThreat,
        ThreatLevel adapterThreat
    ) internal pure returns (string memory) {
        // Simplified - in production, format detailed description
        if (sharePriceThreat >= ThreatLevel.HIGH) return "Share price crash detected";
        if (withdrawalThreat >= ThreatLevel.HIGH) return "Rapid withdrawals detected";
        if (adapterThreat >= ThreatLevel.HIGH) return "Adapter balance anomaly detected";
        return "Multiple threats detected";
    }

    function _recordIncident(
        address reporter,
        ThreatLevel threat,
        string memory category,
        string memory description
    ) internal returns (uint256 incidentId) {
        incidentId = incidents.length;
        incidents.push(IncidentReport({
            timestamp: block.timestamp,
            reporter: reporter,
            threat: threat,
            category: category,
            description: description,
            emergencyActivated: false
        }));
    }

    function _activateEmergency(uint256 incidentId, string memory reason) internal {
        // Mark incident as activated
        incidents[incidentId].emergencyActivated = true;
        lastEmergencyActivation = block.timestamp;

        // Activate emergency on gate
        EmergencyGateWithRoles(gate).activateEmergencyAutomated(reason);

        emit EmergencyActivated(incidentId, reason);
    }

    function _updateHistoricalData() internal {
        lastSharePrice = _getSharePrice();
        lastSharePriceUpdate = block.timestamp;

        // SECURITY FIX Issue #2: Track withdrawals by detecting totalAssets decreases
        uint256 currentTotalAssets = VaultV2(vault).totalAssets();
        lastTotalAssetsUpdate = block.timestamp;

        // Reset withdrawal window if expired
        if (block.timestamp > withdrawalWindowStart + config.rapidWithdrawalWindow) {
            withdrawalsInWindow = 0;
            withdrawalWindowStart = block.timestamp;
        } else if (currentTotalAssets < lastTotalAssets) {
            // Detected withdrawal (totalAssets decreased)
            withdrawalsInWindow += (lastTotalAssets - currentTotalAssets);
        }

        lastTotalAssets = currentTotalAssets;
    }

    /* VIEW FUNCTIONS */

    function getIncidentCount() external view returns (uint256) {
        return incidents.length;
    }

    function getIncident(uint256 index) external view returns (
        uint256 timestamp,
        address reporter,
        ThreatLevel threat,
        string memory category,
        string memory description,
        bool emergencyActivated
    ) {
        IncidentReport memory incident = incidents[index];
        return (
            incident.timestamp,
            incident.reporter,
            incident.threat,
            incident.category,
            incident.description,
            incident.emergencyActivated
        );
    }

    function getCurrentMetrics() external view returns (
        uint256 sharePrice,
        uint256 totalAssets,
        uint256 totalSupply,
        uint256 withdrawalsInCurrentWindow
    ) {
        VaultV2 vaultContract = VaultV2(vault);
        return (
            _getSharePrice(),
            vaultContract.totalAssets(),
            vaultContract.totalSupply(),
            withdrawalsInWindow
        );
    }
}
