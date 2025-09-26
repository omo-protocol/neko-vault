// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IUniversalValuerOffchain} from "../adapters/interfaces/IUniversalValuerOffchain.sol";
import {IUniversalAdapterEscrow} from "../adapters/interfaces/IUniversalAdapterEscrow.sol";
import {IERC20} from "../interfaces/IERC20.sol";

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

        // Validate price bounds
        _validatePriceBounds(strategyId, lastReport.value, value);

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
    function requestUpdate(bytes32 strategyId) external override {
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

        // Check staleness
        if (block.timestamp > report.timestamp + MAX_STALENESS) {
            // Use fallback value if available
            if (fallbackValues[strategyId] > 0) {
                return fallbackValues[strategyId];
            }
            revert ValueTooStale();
        }

        // Check confidence threshold
        if (report.confidence < defaultConfidenceThreshold) {
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
            ValueReport memory report = latestReports[strategies[i]];

            // Skip stale or low confidence values
            if (block.timestamp <= report.timestamp + MAX_STALENESS &&
                report.confidence >= defaultConfidenceThreshold) {
                totalValue += report.value;
            }
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

        // Update all values
        for (uint256 i = 0; i < strategyIds.length; i++) {
            bytes32 strategyId = strategyIds[i];

            // Check nonce for each strategy
            if (nonce <= latestReports[strategyId].nonce) continue;

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

    /// @notice Set price change bounds for a strategy
    function setPriceChangeBounds(bytes32 strategyId, uint256 maxChangeBps) external onlyOwner {
        if (maxChangeBps > BASIS_POINTS) revert InvalidPriceChangeBounds();
        maxPriceChangeBps[strategyId] = maxChangeBps;
        emit PriceChangeBoundsSet(strategyId, maxChangeBps);
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

            if (signers[signer].authorized) {
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

            if (signers[signer].authorized) {
                totalWeight += signers[signer].weight;
                usedSigners[usedCount] = signer;
                usedCount++;
            }
        }

        return totalWeight;
    }

    /// @dev Recover signer from signature
    function _recoverSigner(bytes32 hash, bytes memory signature) internal pure returns (address) {
        if (signature.length != 65) revert InvalidSignature();

        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }

        if (v < 27) {
            v += 27;
        }

        if (v != 27 && v != 28) revert InvalidSignature();

        return ecrecover(hash, v, r, s);
    }

    /// @dev Calculate percentage change
    function _calculateChangePercent(uint256 oldValue, uint256 newValue) internal pure returns (uint256) {
        if (oldValue == 0) return newValue > 0 ? BASIS_POINTS : 0;

        uint256 diff = newValue > oldValue ? newValue - oldValue : oldValue - newValue;
        return (diff * BASIS_POINTS) / oldValue;
    }

    /// @dev Validate price bounds to prevent extreme movements
    function _validatePriceBounds(bytes32 strategyId, uint256 oldValue, uint256 newValue) internal view {
        if (oldValue == 0) return; // No bounds check for initial value

        uint256 maxChange = maxPriceChangeBps[strategyId];
        if (maxChange == 0) {
            maxChange = MAX_PRICE_CHANGE_BPS; // Use default if not set
        }

        uint256 changePercent = _calculateChangePercent(oldValue, newValue);
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