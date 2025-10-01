// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IUniversalValuerOffchain} from "../adapters/interfaces/IUniversalValuerOffchain.sol";
import {IUniversalAdapterEscrow} from "../adapters/interfaces/IUniversalAdapterEscrow.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title UniversalValuerOffchain
/// @notice Off-chain valuation system with signed oracle reports and hybrid push/pull model
/// @dev Reduces audit costs by moving complex valuation logic off-chain
contract UniversalValuerOffchain is IUniversalValuerOffchain {
    /* CONSTANTS */

    uint256 private constant MAX_STALENESS = 24 hours;
    uint256 private constant MIN_UPDATE_INTERVAL = 5 minutes;
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant SIGNER_TIMELOCK = 24 hours; // 24-hour timelock for signer changes
    uint256 private constant MAX_SIGNATURE_AGE = 1 hours; // 1-hour signature expiry
    uint256 private constant MAX_PRICE_CHANGE_BPS = 5000; // 50% max price change per update

    /* IMMUTABLES */

    address public immutable owner;
    address public immutable asset;

    /* STORAGE */

    mapping(bytes32 => ValueReport) public latestReports;
    mapping(address => SignerConfig) public signers;
    mapping(bytes32 => UpdateConfig) public updateConfigs;

    uint256 public requiredWeight;
    uint256 public defaultConfidenceThreshold = 95; // 95% confidence required

    // Fallback values for emergency
    mapping(bytes32 => uint256) public fallbackValues;
    bool public emergencyMode;

    // Signer rotation timelock
    mapping(address => uint256) public signerChangeTimestamp;
    mapping(address => bool) public pendingSignerRemoval;

    // Price validation bounds
    mapping(bytes32 => uint256) public maxPriceChangeBps; // Per-strategy max change

    // Initial value bounds (prevents decimal mismatch on first report)
    mapping(bytes32 => uint256) public maxInitialValue; // Per-strategy max for first report

    // Absolute staleness limit (beyond this, don't use stale values to prevent double-counting)
    uint256 public constant ABSOLUTE_MAX_STALENESS = 48 hours; // Hard limit on stale value usage

    /* MODIFIERS */

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier notEmergency() {
        if (emergencyMode) revert EmergencyMode();
        _;
    }

    /* CONSTRUCTOR */

    constructor(address _owner, address _asset) {
        owner = _owner;
        asset = _asset;
        requiredWeight = 1; // Start with single signer
    }

    /* EXTERNAL FUNCTIONS */

    /// @inheritdoc IUniversalValuerOffchain
    function updateValue(
        bytes32 strategyId,
        uint256 value,
        uint256 confidence,
        uint256 nonce,
        uint256 expiry,
        bytes[] calldata signatures
    ) external override notEmergency {
        ValueReport memory lastReport = latestReports[strategyId];

        // Validate nonce to prevent replay
        if (nonce <= lastReport.nonce) revert StaleNonce();

        // Validate signature expiry
        if (expiry < block.timestamp) revert SignatureExpired();
        if (expiry > block.timestamp + MAX_SIGNATURE_AGE) revert SignatureExpiryTooFar();

        // Check minimum update interval (unless significant change)
        UpdateConfig memory config = updateConfigs[strategyId];
        uint256 changePercent = _calculateChangePercent(lastReport.value, value);

        if (block.timestamp < lastReport.timestamp + config.minUpdateInterval) {
            // Only allow update if change exceeds threshold
            if (changePercent < config.pushThreshold) {
                revert UpdateTooFrequent();
            }
        }

        // Validate price bounds (L-01 FIX: pass pre-calculated changePercent to avoid double calculation)
        if (lastReport.value > 0) {
            _validatePriceBounds(strategyId, changePercent);
        } else {
            // CRITICAL SECURITY FIX: Validate initial values to prevent decimal mismatch attacks
            // First report must be bounded to prevent 1e18 vs 1e6 decimal errors
            uint256 maxInitial = maxInitialValue[strategyId];
            if (maxInitial > 0 && value > maxInitial) {
                revert InitialValueExceedsMax(value, maxInitial);
            }
        }

        // Validate confidence meets minimum requirement
        if (confidence < config.minConfidence) revert LowConfidence();

        // Verify signatures with duplicate prevention
        uint256 totalWeight = _verifySignatures(
            strategyId,
            value,
            confidence,
            nonce,
            expiry,
            signatures
        );

        if (totalWeight < requiredWeight) revert InsufficientSignatures();

        // Store the new report
        latestReports[strategyId] = ValueReport({
            value: value,
            timestamp: block.timestamp,
            confidence: confidence,
            nonce: nonce,
            isPush: true,
            lastUpdater: msg.sender
        });

        emit ValueUpdated(strategyId, value, confidence, block.timestamp, true);
    }

    /// @inheritdoc IUniversalValuerOffchain
    function requestUpdate(bytes32 strategyId) external override notEmergency {
        ValueReport memory report = latestReports[strategyId];
        UpdateConfig memory config = updateConfigs[strategyId];

        // Check if update is needed
        bool isStale = block.timestamp > report.timestamp + config.maxStaleness;
        bool lowConfidence = report.confidence < config.minConfidence;

        if (isStale || lowConfidence) {
            emit UpdateRequested(strategyId, msg.sender, UpdateReason.STALENESS);
        } else {
            emit UpdateRequested(strategyId, msg.sender, UpdateReason.ON_DEMAND);
        }
    }

    /// @inheritdoc IUniversalValuerOffchain
    function getValue(bytes32 strategyId) external view override returns (uint256) {
        ValueReport memory report = latestReports[strategyId];
        UpdateConfig memory config = updateConfigs[strategyId];

        // L-18 FIX: If strategy is configured, use config values directly; otherwise use constants as fallback
        uint256 maxStaleness = (config.minUpdateInterval > 0) ? config.maxStaleness : MAX_STALENESS;

        // Check staleness
        if (block.timestamp > report.timestamp + maxStaleness) {
            // Use fallback value if available
            if (fallbackValues[strategyId] > 0) {
                return fallbackValues[strategyId];
            }
            revert ValueTooStale();
        }

        // L-18 FIX: If strategy is configured, use config values directly; otherwise use defaults as fallback
        uint256 minConfidence = (config.minConfidence > 0) ? config.minConfidence : defaultConfidenceThreshold;

        // Check confidence threshold
        if (report.confidence < minConfidence) {
            revert LowConfidence();
        }

        return report.value;
    }

    /// @inheritdoc IUniversalValuerOffchain
    function getTotalValue(address escrow) external view override returns (uint256 totalValue) {
        // This would aggregate all strategy values for the escrow
        // In practice, would need strategy enumeration logic
        // For now, simplified implementation

        bytes32[] memory strategies = _getActiveStrategies(escrow);

        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 strategyId = strategies[i];
            ValueReport memory report = latestReports[strategyId];
            UpdateConfig memory config = updateConfigs[strategyId];

            // L-18 FIX: If strategy is configured, use config values directly; otherwise use defaults as fallback
            uint256 maxStaleness = (config.minUpdateInterval > 0) ? config.maxStaleness : MAX_STALENESS;
            uint256 minConfidence = (config.minUpdateInterval > 0) ? config.minConfidence : defaultConfidenceThreshold;

            // CRITICAL SECURITY FIX: Improved stale value handling to prevent double counting
            // Priority: 1. Fresh value with sufficient confidence
            //          2. Moderately stale value (within config staleness)
            //          3. Fallback value (emergency backup)
            //          4. Last known value (only if within ABSOLUTE_MAX_STALENESS)

            uint256 stalenessAge = block.timestamp - report.timestamp;

            if (stalenessAge <= maxStaleness && report.confidence >= minConfidence) {
                // Use fresh, high-confidence value
                totalValue += report.value;
            } else if (stalenessAge <= ABSOLUTE_MAX_STALENESS && report.confidence >= minConfidence) {
                // Moderately stale but within absolute limit - use with caution
                // This prevents using values that are so old they might double-count
                totalValue += report.value;
            } else if (fallbackValues[strategyId] > 0) {
                // Use fallback value if main value is too stale or low confidence
                totalValue += fallbackValues[strategyId];
            } else if (report.value > 0 && stalenessAge <= ABSOLUTE_MAX_STALENESS) {
                // DEFENSE IN DEPTH: Only use last known value if within absolute staleness limit
                // Beyond 48h, value is too risky (might double-count deallocated assets)
                totalValue += report.value;
            }
            // If none of the above, strategy contributes 0 (prevents double-counting)
        }

        // Add idle assets
        totalValue += IERC20(asset).balanceOf(escrow);

        return totalValue;
    }

    /// @inheritdoc IUniversalValuerOffchain
    function batchUpdateValues(
        bytes32[] calldata strategyIds,
        uint256[] calldata values,
        uint256[] calldata confidences,
        uint256 nonce,
        uint256 expiry,
        bytes[] calldata signatures
    ) external override notEmergency {
        if (strategyIds.length != values.length ||
            strategyIds.length != confidences.length) {
            revert ArrayLengthMismatch();
        }

        // Validate signature expiry
        if (expiry < block.timestamp) revert SignatureExpired();
        if (expiry > block.timestamp + MAX_SIGNATURE_AGE) revert SignatureExpiryTooFar();

        // Verify signatures for batch
        bytes32 batchHash = keccak256(abi.encode(strategyIds, values, confidences, nonce, expiry));
        uint256 totalWeight = _verifyBatchSignatures(batchHash, signatures);

        if (totalWeight < requiredWeight) revert InsufficientSignatures();

        // CRITICAL FIX: Make batch updates ATOMIC - validate ALL strategies first, then update
        // This prevents partial updates that could be exploited for value manipulation attacks

        // Phase 1: Validate ALL updates (reverts if ANY fails)
        for (uint256 i = 0; i < strategyIds.length; i++) {
            bytes32 strategyId = strategyIds[i];
            ValueReport memory lastReport = latestReports[strategyId];

            // Validate nonce to prevent replay - must be strictly increasing
            if (nonce <= lastReport.nonce) revert StaleNonce();

            UpdateConfig memory config = updateConfigs[strategyId];
            uint256 changePercent = _calculateChangePercent(lastReport.value, values[i]);

            // Check minimum update interval (unless significant change)
            if (block.timestamp < lastReport.timestamp + config.minUpdateInterval) {
                // Only allow update if change exceeds threshold
                if (changePercent < config.pushThreshold) {
                    revert UpdateTooFrequent();
                }
            }

            // Validate price bounds
            if (lastReport.value > 0) {
                _validatePriceBounds(strategyId, changePercent);
            }

            // Validate confidence meets minimum requirement for this strategy
            if (confidences[i] < config.minConfidence) revert LowConfidence();
        }

        // Phase 2: All validations passed - now update ALL strategies atomically
        for (uint256 i = 0; i < strategyIds.length; i++) {
            bytes32 strategyId = strategyIds[i];

            latestReports[strategyId] = ValueReport({
                value: values[i],
                timestamp: block.timestamp,
                confidence: confidences[i],
                nonce: nonce,
                isPush: true,
                lastUpdater: msg.sender
            });

            emit ValueUpdated(strategyId, values[i], confidences[i], block.timestamp, true);
        }
    }

    /* ADMIN FUNCTIONS */

    /// @notice Initiate signer configuration change (step 1 of 2-step process)
    function initiateSignerChange(
        address signer,
        bool authorized,
        uint256 weight
    ) external onlyOwner {
        if (!authorized && signers[signer].authorized) {
            // Removing an authorized signer requires timelock
            signerChangeTimestamp[signer] = block.timestamp + SIGNER_TIMELOCK;
            pendingSignerRemoval[signer] = true;
            emit SignerRemovalInitiated(signer, signerChangeTimestamp[signer]);
        } else {
            // Adding or modifying signer can be immediate
            signers[signer] = SignerConfig({
                authorized: authorized,
                weight: weight
            });
            emit SignerConfigured(signer, authorized, weight);
        }
    }

    /// @notice Execute pending signer removal after timelock
    function executeSignerRemoval(address signer) external onlyOwner {
        if (!pendingSignerRemoval[signer]) revert NoSignerRemovalPending();
        if (block.timestamp < signerChangeTimestamp[signer]) revert SignerRemovalTimelockNotExpired();

        // Remove signer
        signers[signer] = SignerConfig({
            authorized: false,
            weight: 0
        });

        // Clear timelock state
        pendingSignerRemoval[signer] = false;
        signerChangeTimestamp[signer] = 0;

        emit SignerConfigured(signer, false, 0);
    }

    /// @notice Cancel pending signer removal
    function cancelSignerRemoval(address signer) external onlyOwner {
        if (!pendingSignerRemoval[signer]) revert NoSignerRemovalPending();

        pendingSignerRemoval[signer] = false;
        signerChangeTimestamp[signer] = 0;

        emit SignerRemovalCancelled(signer);
    }

    /// @notice Configure update parameters for a strategy
    function configureStrategy(
        bytes32 strategyId,
        uint256 minUpdateInterval,
        uint256 maxStaleness,
        uint256 pushThreshold,
        uint256 minConfidence
    ) external onlyOwner {
        if (minUpdateInterval < MIN_UPDATE_INTERVAL) revert UpdateTooFrequent();
        if (maxStaleness > MAX_STALENESS) revert ValueTooStale();
        if (pushThreshold > MAX_PRICE_CHANGE_BPS) revert InvalidPriceChangeBounds();
        if (minConfidence < defaultConfidenceThreshold || minConfidence > 100) revert LowConfidence();

        // M-08 FIX: Ensure pushThreshold doesn't exceed maxPriceChangeBps to prevent stuck strategies
        uint256 maxChange = maxPriceChangeBps[strategyId];
        if (maxChange == 0) {
            maxChange = MAX_PRICE_CHANGE_BPS; // Use default if not set
        }
        if (pushThreshold > maxChange) {
            revert PushThresholdExceedsMaxChange(pushThreshold, maxChange);
        }

        updateConfigs[strategyId] = UpdateConfig({
            minUpdateInterval: minUpdateInterval,
            maxStaleness: maxStaleness,
            pushThreshold: pushThreshold,
            minConfidence: minConfidence
        });

        emit StrategyConfigured(strategyId, minUpdateInterval, maxStaleness, pushThreshold);
    }

    /// @notice Set required weight for multi-sig
    function setRequiredWeight(uint256 weight) external onlyOwner {
        if (weight == 0) revert InvalidWeight();
        requiredWeight = weight;
        emit RequiredWeightUpdated(weight);
    }

    /// @notice Set default confidence threshold for strategy value acceptance
    /// @param threshold New confidence threshold (0-100)
    function setDefaultConfidenceThreshold(uint256 threshold) external onlyOwner {
        if (threshold > 100) revert LowConfidence(); // Reuse existing error for invalid confidence
        defaultConfidenceThreshold = threshold;
        emit DefaultConfidenceThresholdUpdated(threshold);
    }

    /// @notice Set price change bounds for a strategy
    function setPriceChangeBounds(bytes32 strategyId, uint256 maxChangeBps) external onlyOwner {
        if (maxChangeBps > BASIS_POINTS) revert InvalidPriceChangeBounds();

        // M-08 FIX: Ensure new price bounds don't conflict with existing pushThreshold
        UpdateConfig memory config = updateConfigs[strategyId];
        if (config.pushThreshold > 0 && config.pushThreshold > maxChangeBps) {
            revert PushThresholdExceedsMaxChange(config.pushThreshold, maxChangeBps);
        }

        maxPriceChangeBps[strategyId] = maxChangeBps;
        emit PriceChangeBoundsSet(strategyId, maxChangeBps);
    }

    /// @notice Set maximum initial value for a strategy (prevents decimal mismatch on first report)
    /// @param strategyId The strategy identifier
    /// @param maxValue Maximum allowed value for first report (0 = no limit)
    /// @dev CRITICAL: Set this to reasonable bounds based on expected strategy size in asset decimals
    ///      Example: For USDC (6 decimals) strategy managing $1M, set to 1_000_000e6
    function setMaxInitialValue(bytes32 strategyId, uint256 maxValue) external onlyOwner {
        maxInitialValue[strategyId] = maxValue;
        emit MaxInitialValueSet(strategyId, maxValue);
    }

    /// @notice Set fallback value for emergency
    function setFallbackValue(bytes32 strategyId, uint256 value) external onlyOwner {
        fallbackValues[strategyId] = value;
        emit FallbackValueSet(strategyId, value);
    }

    /// @notice Toggle emergency mode
    function setEmergencyMode(bool enabled) external onlyOwner {
        emergencyMode = enabled;
        emit EmergencyModeToggled(enabled);
    }

    /// @notice Force update a value in emergency
    function emergencyUpdate(bytes32 strategyId, uint256 value) external onlyOwner {
        if (!emergencyMode) revert NotInEmergencyMode();

        latestReports[strategyId] = ValueReport({
            value: value,
            timestamp: block.timestamp,
            confidence: 100,
            nonce: latestReports[strategyId].nonce + 1,
            isPush: false,
            lastUpdater: msg.sender
        });

        emit EmergencyValueUpdate(strategyId, value);
    }

    /* VIEW FUNCTIONS */

    /// @notice Check if a value needs updating
    function needsUpdate(bytes32 strategyId) external view returns (bool) {
        ValueReport memory report = latestReports[strategyId];
        UpdateConfig memory config = updateConfigs[strategyId];

        // Check staleness
        if (block.timestamp > report.timestamp + config.maxStaleness) {
            return true;
        }

        // Check confidence
        if (report.confidence < config.minConfidence) {
            return true;
        }

        return false;
    }

    /// @notice Get detailed report for a strategy
    function getReport(bytes32 strategyId) external view returns (ValueReport memory) {
        return latestReports[strategyId];
    }

    /// @notice Check if signer is authorized
    function isAuthorizedSigner(address signer) external view returns (bool) {
        return signers[signer].authorized;
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Verify signatures and return total weight with duplicate prevention
    function _verifySignatures(
        bytes32 strategyId,
        uint256 value,
        uint256 confidence,
        uint256 nonce,
        uint256 expiry,
        bytes[] calldata signatures
    ) internal view returns (uint256 totalWeight) {
        bytes32 messageHash = keccak256(abi.encode(
            strategyId,
            value,
            confidence,
            nonce,
            expiry,
            block.chainid,
            address(this)
        ));

        bytes32 ethSignedHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            messageHash
        ));

        // Track used signers to prevent duplicates
        address[] memory usedSigners = new address[](signatures.length);
        uint256 usedCount = 0;

        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = _recoverSigner(ethSignedHash, signatures[i]);

            // Skip if signer already counted
            bool alreadyUsed = false;
            for (uint256 j = 0; j < usedCount; j++) {
                if (usedSigners[j] == signer) {
                    alreadyUsed = true;
                    break;
                }
            }

            if (alreadyUsed) continue;

            // Check if signer is authorized and not pending deactivation
            // If pendingSignerRemoval[signer] is true, signer should be excluded after his removal delay passes
            if (signers[signer].authorized && (!pendingSignerRemoval[signer] || signerChangeTimestamp[signer] > block.timestamp)) {
                totalWeight += signers[signer].weight;
                usedSigners[usedCount] = signer;
                usedCount++;
            }
        }

        return totalWeight;
    }

    /// @dev Verify batch signatures
    function _verifyBatchSignatures(
        bytes32 batchHash,
        bytes[] calldata signatures
    ) internal view returns (uint256 totalWeight) {
        bytes32 ethSignedHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            batchHash
        ));

        // Track used signers to prevent duplicates
        address[] memory usedSigners = new address[](signatures.length);
        uint256 usedCount = 0;

        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = _recoverSigner(ethSignedHash, signatures[i]);

            // Skip if signer already counted
            bool alreadyUsed = false;
            for (uint256 j = 0; j < usedCount; j++) {
                if (usedSigners[j] == signer) {
                    alreadyUsed = true;
                    break;
                }
            }

            if (alreadyUsed) continue;

            // Check if signer is authorized and not pending deactivation
            // If pendingSignerRemoval[signer] is true, signer should be excluded immediately
            if (signers[signer].authorized && (!pendingSignerRemoval[signer] || signerChangeTimestamp[signer] > block.timestamp)) {
                totalWeight += signers[signer].weight;
                usedSigners[usedCount] = signer;
                usedCount++;
            }
        }

        return totalWeight;
    }

    /// @dev Recover signer from signature using OpenZeppelin's battle-tested ECDSA library
    /// @param hash The hash that was signed (already prefixed with Ethereum message format)
    /// @param signature The signature bytes
    /// @return The recovered signer address
    function _recoverSigner(bytes32 hash, bytes memory signature) internal pure returns (address) {
        // L-11 FIX: Use OpenZeppelin's ECDSA.recover for safer signature validation
        // This handles malleability and edge cases better than custom ecrecover implementation

        // Basic signature length validation to maintain existing behavior
        if (signature.length != 65) revert InvalidSignature();

        // OpenZeppelin's ECDSA.recover handles most edge cases internally
        // and returns address(0) for invalid signatures instead of reverting
        address signer = ECDSA.recover(hash, signature);

        if (signer == address(0)) revert InvalidSignature();

        return signer;
    }

    /// @dev Calculate percentage change
    function _calculateChangePercent(uint256 oldValue, uint256 newValue) internal pure returns (uint256) {
        if (oldValue == 0) return newValue > 0 ? BASIS_POINTS : 0;

        uint256 diff = newValue > oldValue ? newValue - oldValue : oldValue - newValue;
        return (diff * BASIS_POINTS) / oldValue;
    }

    /// @dev Validate price bounds to prevent extreme movements
    /// @param strategyId The strategy identifier
    /// @param changePercent The pre-calculated change percentage to validate
    function _validatePriceBounds(bytes32 strategyId, uint256 changePercent) internal view {
        uint256 maxChange = maxPriceChangeBps[strategyId];
        if (maxChange == 0) {
            maxChange = MAX_PRICE_CHANGE_BPS; // Use default if not set
        }

        if (changePercent > maxChange) {
            revert PriceChangeExceedsBounds(changePercent, maxChange);
        }
    }

    /// @dev Get active strategies for escrow
    function _getActiveStrategies(address escrow) internal view returns (bytes32[] memory) {
        // Query UniversalAdapterEscrow for active strategies
        try IUniversalAdapterEscrow(escrow).getActiveStrategies() returns (bytes32[] memory ids) {
            return ids;
        } catch {
            // Return empty array if the call fails (e.g., not a UniversalAdapterEscrow)
            return new bytes32[](0);
        }
    }
}