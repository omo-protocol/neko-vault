// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title IUniversalValuer
/// @notice Interface for the Universal Valuer that calculates total value across all strategies
interface IUniversalValuer {
    /* STRUCTS */

    struct StrategyValuer {
        address implementation;
        bool useCache;
        uint256 cacheTime;
        uint256 cachedValue;
        uint256 lastUpdate;
    }

    /* ERRORS */

    error NotAuthorized();
    error InvalidStrategy();
    error ValuerNotSet();
    error StaleData();

    /* EVENTS */

    event ValuerRegistered(bytes32 indexed strategyId, address indexed valuer, bool useCache, uint256 cacheTime);
    event ValuerUpdated(bytes32 indexed strategyId, address indexed newValuer);
    event CacheUpdated(bytes32 indexed strategyId, uint256 value);
    event BaseValuerSet(address indexed baseValuer);

    /* FUNCTIONS */

    /// @notice Get total value of all strategies for an escrow
    /// @param escrow The escrow address holding the positions
    /// @return totalValue The total value in underlying asset
    function getTotalValue(address escrow) external view returns (uint256 totalValue);

    /// @notice Get value of a specific strategy
    /// @param escrow The escrow address
    /// @param strategyId The strategy identifier
    /// @return value The strategy value in underlying asset
    function getStrategyValue(address escrow, bytes32 strategyId) external view returns (uint256 value);

    /// @notice Register a valuer for a strategy
    /// @param strategyId The strategy identifier
    /// @param valuer The valuer implementation address
    /// @param useCache Whether to use caching
    /// @param cacheTime Cache duration in seconds
    function registerStrategyValuer(
        bytes32 strategyId,
        address valuer,
        bool useCache,
        uint256 cacheTime
    ) external;

    /// @notice Update cache for a strategy
    /// @param strategyId The strategy identifier
    /// @param value The new cached value
    function updateCache(bytes32 strategyId, uint256 value) external;

    /// @notice Get valuer info for a strategy
    /// @param strategyId The strategy identifier
    /// @return The strategy valuer configuration
    function strategyValuers(bytes32 strategyId) external view returns (StrategyValuer memory);

    /// @notice Set the base valuer for simple strategies
    /// @param baseValuer The base valuer address
    function setBaseValuer(address baseValuer) external;

    /// @notice Check if cache is valid for a strategy
    /// @param strategyId The strategy identifier
    /// @return Whether the cache is still valid
    function isCacheValid(bytes32 strategyId) external view returns (bool);
}