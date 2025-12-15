// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title IUniversalValuerOffchain
/// @notice Interface for off-chain valuation system with signed oracle reports
interface IUniversalValuerOffchain {
    /* STRUCTS */

    struct ValueReport {
        uint256 value;        // Strategy value in base asset
        uint256 timestamp;    // When value was calculated
        uint256 confidence;   // Confidence score (0-100)
        uint256 nonce;        // Prevent replay attacks
        bool isPush;          // True if pushed, false if pulled
        address lastUpdater;  // Who submitted the update
    }

    struct SignerConfig {
        bool authorized;      // Is signer authorized
        uint256 weight;       // Weight for multi-sig (e.g., 1 for single, 2 for important)
    }

    struct UpdateConfig {
        uint256 minUpdateInterval;  // Minimum time between updates
        uint256 maxStaleness;       // Maximum age before stale
        uint256 pushThreshold;      // % change to trigger push (in basis points)
        uint256 minConfidence;      // Minimum acceptable confidence
    }

    enum UpdateReason {
        STALENESS,      // Value is too old
        THRESHOLD,      // Change exceeded threshold
        ON_DEMAND,      // Manual request
        EMERGENCY       // Emergency update
    }

    /* EVENTS */

    event ValueUpdated(
        bytes32 indexed strategyId,
        uint256 value,
        uint256 confidence,
        uint256 timestamp,
        bool isPush
    );
    event UpdateRequested(
        bytes32 indexed strategyId,
        address requester,
        UpdateReason reason
    );
    event SignerConfigured(
        address indexed signer,
        bool authorized,
        uint256 weight
    );
    event StrategyConfigured(
        bytes32 indexed strategyId,
        uint256 minUpdateInterval,
        uint256 maxStaleness,
        uint256 pushThreshold
    );
    event RequiredWeightUpdated(uint256 newWeight);
    event DefaultConfidenceThresholdUpdated(uint256 newThreshold);
    event FallbackValueSet(bytes32 indexed strategyId, uint256 value);
    event EmergencyModeToggled(bool enabled);
    event EmergencyValueUpdate(bytes32 indexed strategyId, uint256 value);
    event SignerRemovalInitiated(address indexed signer, uint256 executeTimestamp);
    event SignerRemovalCancelled(address indexed signer);
    event PriceChangeBoundsSet(bytes32 indexed strategyId, uint256 maxChangeBps);
    event MaxInitialValueSet(bytes32 indexed strategyId, uint256 maxValue);
    event EscrowTotalRegistered(bytes32 indexed totalId, address indexed escrow);
    event EmergencyMinConfidenceUpdated(uint256 newThreshold);
    event StaleStrategySkipped(bytes32 indexed strategyId, uint256 stalenessAge, uint256 maxStaleness);
    event ValuationHealthChecked(address indexed escrow, bool isHealthy, uint256 freshCount, uint256 staleCount);

    /* STRUCTS - Health Check */

    /// @notice Result of total value computation with staleness metadata
    struct TotalValueResult {
        uint256 value;           // Total computed value
        bool hasStaleData;       // True if any strategy used stale/fallback data
        uint256 freshCount;      // Number of strategies with fresh values
        uint256 staleCount;      // Number of strategies with stale values
        uint256 fallbackCount;   // Number of strategies using fallback values
    }

    /* ERRORS */

    error NotAuthorized();
    error StaleNonce();
    error NonceGapTooLarge(); // L-02 FIX: Nonce jumped too far ahead
    error UpdateTooFrequent();
    error InsufficientSignatures();
    error ValueTooStale();
    error LowConfidence();
    error InvalidSignature();
    error ArrayLengthMismatch();
    error EmergencyMode();
    error NotInEmergencyMode();
    error SignatureExpired();
    error SignatureExpiryTooFar();
    error NoSignerRemovalPending();
    error SignerRemovalTimelockNotExpired();
    error InvalidWeight();
    error InvalidPriceChangeBounds();
    error PriceChangeExceedsBounds(uint256 changePercent, uint256 maxChange);
    error PushThresholdExceedsMaxChange(uint256 pushThreshold, uint256 maxChange);
    error InitialValueExceedsMax(uint256 value, uint256 maxInitialValue);
    error UpdateIntervalExceedsStaleness(); // L-03 FIX: minUpdateInterval must be < maxStaleness
    error StrategyNotConfigured();
    error CannotUpdateReservedEscrowTotal(); // SECURITY FIX: Cannot update ESCROW_TOTAL IDs via strategy updates
    error InvalidEscrowTotalRegistration(); // SECURITY FIX: Only valid ESCROW_TOTAL IDs can be registered
    error InvalidEmergencyConfidence(); // SECURITY FIX: Invalid emergency confidence threshold

    /* FUNCTIONS */

    /// @notice Update a strategy value with signatures
    /// @param strategyId The strategy identifier
    /// @param value The calculated value
    /// @param confidence Confidence score (0-100)
    /// @param nonce Unique nonce to prevent replay
    /// @param expiry Signature expiry timestamp
    /// @param signatures Array of signatures from authorized signers
    function updateValue(
        bytes32 strategyId,
        uint256 value,
        uint256 confidence,
        uint256 nonce,
        uint256 expiry,
        bytes[] calldata signatures
    ) external;

    /// @notice Request an update for a strategy (pull model)
    /// @param strategyId The strategy to update
    function requestUpdate(bytes32 strategyId) external;

    /// @notice Get the latest value for a strategy
    /// @param strategyId The strategy identifier
    /// @return The latest value
    function getValue(bytes32 strategyId) external view returns (uint256);


    /// @notice Batch update multiple strategy values
    /// @param strategyIds Array of strategy identifiers
    /// @param values Array of values
    /// @param confidences Array of confidence scores
    /// @param nonce Shared nonce for the batch
    /// @param expiry Signature expiry timestamp
    /// @param signatures Signatures authorizing the batch
    function batchUpdateValues(
        bytes32[] calldata strategyIds,
        uint256[] calldata values,
        uint256[] calldata confidences,
        uint256 nonce,
        uint256 expiry,
        bytes[] calldata signatures
    ) external;

    /// @notice Check if a strategy needs updating
    /// @param strategyId The strategy to check
    /// @return True if update is needed
    function needsUpdate(bytes32 strategyId) external view returns (bool);

    /// @notice Get detailed report for a strategy
    /// @param strategyId The strategy identifier
    /// @return The full value report
    function getReport(bytes32 strategyId) external view returns (ValueReport memory);

    /// @notice Register an ESCROW_TOTAL ID to prevent collision with strategy IDs
    /// @dev Called by escrow contracts during deployment to protect their total ID
    /// @param totalId The ESCROW_TOTAL ID (must match keccak256(abi.encodePacked("ESCROW_TOTAL", msg.sender)))
    function registerEscrowTotal(bytes32 totalId) external;

    /// @notice Check if an ID is a registered ESCROW_TOTAL
    /// @param id The ID to check
    /// @return escrow The escrow address that registered this ID (address(0) if not registered)
    function getRegisteredEscrow(bytes32 id) external view returns (address escrow);


    /// @notice Check if escrow valuation is healthy (no stale data)
    /// @param escrow The escrow address
    /// @return healthy True if all strategies have fresh values
    function isValuationHealthy(address escrow) external view returns (bool healthy);
}