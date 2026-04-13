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
    uint256 private constant MAX_NONCE_GAP = 1000;

    /* IMMUTABLES */

    address public immutable owner;
    address public immutable asset;

    /* STORAGE */

    mapping(bytes32 => ValueReport) public latestReports;
    mapping(address => SignerConfig) public signers;
    mapping(bytes32 => UpdateConfig) public updateConfigs;

    uint256 public requiredWeight;
    uint256 public defaultConfidenceThreshold = 90;

    mapping(bytes32 => uint256) public fallbackValues;
    bool public emergencyMode;

    mapping(address => uint256) public signerChangeTimestamp;
    mapping(address => bool) public pendingSignerRemoval;
    mapping(bytes32 => uint256) public maxPriceChangeBps;
    mapping(bytes32 => uint256) public maxInitialValue;
    mapping(bytes32 => address) public registeredEscrowTotals;

    uint256 public emergencyMinConfidence = 50;

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
    ) external override onlyOwner notEmergency {
        if (registeredEscrowTotals[strategyId] != address(0)) {
            revert CannotUpdateReservedEscrowTotal();
        }

        ValueReport memory lastReport = latestReports[strategyId];

        if (nonce <= lastReport.nonce) revert StaleNonce();
        if (nonce > lastReport.nonce + MAX_NONCE_GAP) revert NonceGapTooLarge();
        if (expiry < block.timestamp) revert SignatureExpired();
        if (expiry > block.timestamp + MAX_SIGNATURE_AGE) revert SignatureExpiryTooFar();

        UpdateConfig memory config = updateConfigs[strategyId];
        uint256 changePercent = _calculateChangePercent(lastReport.value, value);
        uint256 minConfidence = _effectiveMinConfidence(config);

        if (block.timestamp < lastReport.timestamp + config.minUpdateInterval) {
            if (changePercent < config.pushThreshold) {
                revert UpdateTooFrequent();
            }
        }

        if (lastReport.value > 0) {
            _validatePriceBounds(strategyId, changePercent);
        } else {
            uint256 maxInitial = maxInitialValue[strategyId];
            if (maxInitial > 0 && value > maxInitial) {
                revert InitialValueExceedsMax(value, maxInitial);
            }
        }

        if (confidence < minConfidence) revert LowConfidence();

        uint256 totalWeight = _verifySignatures(strategyId, value, confidence, nonce, expiry, signatures);

        if (totalWeight < requiredWeight) revert InsufficientSignatures();

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

        bool isStale = block.timestamp > report.timestamp + _effectiveMaxStaleness(config);
        bool lowConfidence = report.confidence < _effectiveMinConfidence(config);

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

        if (report.timestamp == 0) {
            if (fallbackValues[strategyId] > 0) {
                return fallbackValues[strategyId];
            }
            revert ValueTooStale();
        }

        uint256 maxStaleness = (config.minUpdateInterval > 0) ? config.maxStaleness : MAX_STALENESS;

        if (block.timestamp > report.timestamp + maxStaleness) {
            if (fallbackValues[strategyId] > 0) {
                return fallbackValues[strategyId];
            }
            revert ValueTooStale();
        }

        uint256 minConfidence = (config.minConfidence > 0) ? config.minConfidence : defaultConfidenceThreshold;

        if (report.confidence < minConfidence) {
            revert LowConfidence();
        }

        return report.value;
    }

    /// @dev Internal helper to compute total value for an escrow with staleness tracking
    /// @dev Used by isValuationHealthy() to determine if any strategy has stale data
    /// @param escrow The escrow address to compute total value for
    /// @return result Struct containing value and staleness indicators
    function _computeTotalValueWithStaleness(address escrow)
        internal
        view
        returns (IUniversalValuerOffchain.TotalValueResult memory result)
    {
        bytes32[] memory strategies = _getActiveStrategies(escrow);

        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 strategyId = strategies[i];
            ValueReport memory report = latestReports[strategyId];
            UpdateConfig memory config = updateConfigs[strategyId];

            uint256 maxStaleness = _effectiveMaxStaleness(config);
            uint256 minConfidence = _effectiveMinConfidence(config);
            uint256 stalenessAge = block.timestamp - report.timestamp;

            if (stalenessAge <= maxStaleness && report.confidence >= minConfidence) {
                result.value += report.value;
                result.freshCount++;
            } else if (fallbackValues[strategyId] > 0) {
                result.value += fallbackValues[strategyId];
                result.hasStaleData = true;
                result.fallbackCount++;
            } else if (report.value > 0 && stalenessAge <= maxStaleness && report.confidence >= emergencyMinConfidence)
            {
                result.value += report.value;
                result.hasStaleData = true;
                result.staleCount++;
            } else {
                result.hasStaleData = true;
                result.staleCount++;
            }
        }
    }

    /// @inheritdoc IUniversalValuerOffchain
    function batchUpdateValues(
        bytes32[] calldata strategyIds,
        uint256[] calldata values,
        uint256[] calldata confidences,
        uint256 nonce,
        uint256 expiry,
        bytes[] calldata signatures
    ) external override onlyOwner notEmergency {
        if (strategyIds.length != values.length || strategyIds.length != confidences.length) {
            revert ArrayLengthMismatch();
        }
        if (expiry < block.timestamp) revert SignatureExpired();
        if (expiry > block.timestamp + MAX_SIGNATURE_AGE) revert SignatureExpiryTooFar();

        bytes32 batchHash =
            keccak256(abi.encode(strategyIds, values, confidences, nonce, expiry, block.chainid, address(this)));
        uint256 totalWeight = _verifyBatchSignatures(batchHash, signatures);

        if (totalWeight < requiredWeight) revert InsufficientSignatures();

        for (uint256 i = 0; i < strategyIds.length; i++) {
            bytes32 strategyId = strategyIds[i];
            if (registeredEscrowTotals[strategyId] != address(0)) {
                revert CannotUpdateReservedEscrowTotal();
            }
            ValueReport memory lastReport = latestReports[strategyId];

            if (nonce <= lastReport.nonce) revert StaleNonce();
            if (nonce > lastReport.nonce + MAX_NONCE_GAP) revert NonceGapTooLarge();

            UpdateConfig memory config = updateConfigs[strategyId];
            uint256 changePercent = _calculateChangePercent(lastReport.value, values[i]);
            uint256 minConfidence = _effectiveMinConfidence(config);

            if (block.timestamp < lastReport.timestamp + config.minUpdateInterval) {
                if (changePercent < config.pushThreshold) {
                    revert UpdateTooFrequent();
                }
            }
            if (lastReport.value > 0) {
                _validatePriceBounds(strategyId, changePercent);
            } else {
                uint256 maxInitial = maxInitialValue[strategyId];
                if (maxInitial > 0 && values[i] > maxInitial) {
                    revert InitialValueExceedsMax(values[i], maxInitial);
                }
            }
            if (confidences[i] < minConfidence) revert LowConfidence();
        }

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

    /* ESCROW TOTAL REGISTRATION */

    /// @notice Register an ESCROW_TOTAL ID to prevent collision with strategy IDs
    /// @dev Called by escrow contracts during deployment. Only the escrow matching the totalId can register.
    /// @param totalId The ESCROW_TOTAL ID (must match keccak256(abi.encodePacked("ESCROW_TOTAL", msg.sender)))
    function registerEscrowTotal(bytes32 totalId) external {
        bytes32 expectedId = keccak256(abi.encodePacked("ESCROW_TOTAL", msg.sender));
        if (totalId != expectedId) {
            revert InvalidEscrowTotalRegistration();
        }
        if (registeredEscrowTotals[totalId] != address(0) && registeredEscrowTotals[totalId] != msg.sender) {
            revert InvalidEscrowTotalRegistration();
        }

        registeredEscrowTotals[totalId] = msg.sender;
        emit EscrowTotalRegistered(totalId, msg.sender);
    }

    /// @notice Check if an ID is a registered ESCROW_TOTAL
    /// @param id The ID to check
    /// @return escrow The escrow address that registered this ID (address(0) if not registered)
    function getRegisteredEscrow(bytes32 id) external view returns (address escrow) {
        return registeredEscrowTotals[id];
    }

    /* ADMIN FUNCTIONS */

    /// @notice Initiate signer configuration change (step 1 of 2-step process)
    function initiateSignerChange(address signer, bool authorized, uint256 weight) external onlyOwner {
        if (!authorized && signers[signer].authorized) {
            signerChangeTimestamp[signer] = block.timestamp + SIGNER_TIMELOCK;
            pendingSignerRemoval[signer] = true;
            emit SignerRemovalInitiated(signer, signerChangeTimestamp[signer]);
        } else {
            signers[signer] = SignerConfig({authorized: authorized, weight: weight});
            emit SignerConfigured(signer, authorized, weight);
        }
    }

    /// @notice Execute pending signer removal after timelock
    function executeSignerRemoval(address signer) external onlyOwner {
        if (!pendingSignerRemoval[signer]) revert NoSignerRemovalPending();
        if (block.timestamp < signerChangeTimestamp[signer]) revert SignerRemovalTimelockNotExpired();

        signers[signer] = SignerConfig({authorized: false, weight: 0});

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
        if (minUpdateInterval >= maxStaleness) revert UpdateIntervalExceedsStaleness();

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

    /// @notice Set emergency minimum confidence threshold for Path 4 fallback
    /// @dev This threshold is used when normal confidence requirements fail but
    ///      the value is still within ABSOLUTE_MAX_STALENESS
    /// @param threshold New emergency confidence threshold (0-100)
    function setEmergencyMinConfidence(uint256 threshold) external onlyOwner {
        if (threshold > 100) revert InvalidEmergencyConfidence();
        // Emergency threshold should be lower than normal threshold
        if (threshold > defaultConfidenceThreshold) revert InvalidEmergencyConfidence();
        emergencyMinConfidence = threshold;
        emit EmergencyMinConfidenceUpdated(threshold);
    }

    /// @notice Set price change bounds for a strategy
    function setPriceChangeBounds(bytes32 strategyId, uint256 maxChangeBps) external onlyOwner {
        if (maxChangeBps > MAX_PRICE_CHANGE_BPS) revert InvalidPriceChangeBounds();
        if (maxChangeBps > BASIS_POINTS) revert InvalidPriceChangeBounds();

        UpdateConfig memory config = updateConfigs[strategyId];
        if (config.pushThreshold > 0 && config.pushThreshold > maxChangeBps) {
            revert PushThresholdExceedsMaxChange(config.pushThreshold, maxChangeBps);
        }

        maxPriceChangeBps[strategyId] = maxChangeBps;
        emit PriceChangeBoundsSet(strategyId, maxChangeBps);
    }

    /// @notice Set maximum initial value for a strategy
    /// @param strategyId The strategy identifier
    /// @param maxValue Maximum allowed value for first report (0 = no limit)
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
        if (registeredEscrowTotals[strategyId] != address(0)) revert CannotUpdateReservedEscrowTotal();

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

        if (report.timestamp == 0) {
            return true;
        }

        if (block.timestamp > report.timestamp + _effectiveMaxStaleness(config)) {
            return true;
        }

        if (report.confidence < _effectiveMinConfidence(config)) {
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

    /// @inheritdoc IUniversalValuerOffchain
    function isValuationHealthy(address escrow) external view override returns (bool healthy) {
        IUniversalValuerOffchain.TotalValueResult memory result = _computeTotalValueWithStaleness(escrow);
        return !result.hasStaleData;
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
        bytes32 messageHash =
            keccak256(abi.encode(strategyId, value, confidence, nonce, expiry, block.chainid, address(this)));

        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));

        address[] memory usedSigners = new address[](signatures.length);
        uint256 usedCount = 0;

        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = _recoverSigner(ethSignedHash, signatures[i]);

            bool alreadyUsed = false;
            for (uint256 j = 0; j < usedCount; j++) {
                if (usedSigners[j] == signer) {
                    alreadyUsed = true;
                    break;
                }
            }

            if (alreadyUsed) continue;

            if (
                signers[signer].authorized
                    && (!pendingSignerRemoval[signer] || signerChangeTimestamp[signer] > block.timestamp)
            ) {
                totalWeight += signers[signer].weight;
                usedSigners[usedCount] = signer;
                usedCount++;
            }
        }

        return totalWeight;
    }

    function _effectiveMaxStaleness(UpdateConfig memory config) internal view returns (uint256 maxStaleness) {
        return config.minUpdateInterval > 0 ? config.maxStaleness : MAX_STALENESS;
    }

    function _effectiveMinConfidence(UpdateConfig memory config) internal view returns (uint256 minConfidence) {
        return config.minConfidence > 0 ? config.minConfidence : defaultConfidenceThreshold;
    }

    /// @dev Verify batch signatures
    function _verifyBatchSignatures(bytes32 batchHash, bytes[] calldata signatures)
        internal
        view
        returns (uint256 totalWeight)
    {
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", batchHash));

        address[] memory usedSigners = new address[](signatures.length);
        uint256 usedCount = 0;

        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = _recoverSigner(ethSignedHash, signatures[i]);

            bool alreadyUsed = false;
            for (uint256 j = 0; j < usedCount; j++) {
                if (usedSigners[j] == signer) {
                    alreadyUsed = true;
                    break;
                }
            }

            if (alreadyUsed) continue;

            if (
                signers[signer].authorized
                    && (!pendingSignerRemoval[signer] || signerChangeTimestamp[signer] > block.timestamp)
            ) {
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
        if (signature.length != 65) revert InvalidSignature();

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
        try IUniversalAdapterEscrow(escrow).getActiveStrategies() returns (bytes32[] memory ids) {
            return ids;
        } catch {
            revert("StrategyEnumerationFailed");
        }
    }
}
