// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
pragma solidity 0.8.28;

import {MarketParams} from "../../../lib/morpho-blue/src/interfaces/IMorpho.sol";

/// @title IMorphoPTLoopAdapter
/// @notice Interface for Morpho PT (Principal Token) loop strategy adapter
/// @dev Implements leveraged collateral strategy using kHYPE-PT as collateral to borrow kHYPE
interface IMorphoPTLoopAdapter {
    
    /* EVENTS */
    
    event PositionIncreased(bytes32 indexed marketId, uint256 collateralAdded, uint256 borrowed, uint256 newHealthFactor);
    event PositionDecreased(bytes32 indexed marketId, uint256 collateralRemoved, uint256 repaid, uint256 newHealthFactor);
    event Rebalanced(bytes32 indexed marketId, uint256 oldHealthFactor, uint256 newHealthFactor);
    event EmergencyDeleveraged(bytes32 indexed marketId, uint256 collateralSold, uint256 debtRepaid);
    event StrategyParametersUpdated(uint256 maxLeverage, uint256 targetHealthFactor, uint256 minHealthFactor);
    event SetPendleRouter(address indexed oldRouter, address indexed newRouter);
    event SetSkimRecipient(address indexed newSkimRecipient);
    event Skim(address indexed token, uint256 amount);
    
    /* ERRORS */
    
    error NotAuthorized();
    error LoanAssetMismatch();
    error CollateralAssetMismatch(); 
    error HealthFactorTooLow();
    error MaxLeverageExceeded();
    error InvalidStrategyParameters();
    error PositionUnhealthy();
    error InsufficientLiquidity();
    error SlippageTooHigh();
    
    /* STRUCTS */
    
    /// @notice Strategy parameters for risk management
    struct StrategyParams {
        uint256 maxLeverage;        // Maximum leverage ratio (e.g., 300 = 3x leverage)
        uint256 targetHealthFactor; // Target health factor (e.g., 150 = 1.5x safety margin)
        uint256 minHealthFactor;    // Minimum health factor before emergency deleverage (e.g., 110 = 1.1x)
        uint256 maxSlippage;        // Maximum slippage tolerance for PT swaps (e.g., 200 = 2%)
    }
    
    /// @notice Current position information
    struct PositionInfo {
        uint256 collateralAssets;   // Amount of kHYPE-PT held as collateral
        uint256 borrowedAssets;     // Amount of kHYPE borrowed
        uint256 netValue;          // Net position value in vault asset terms
        uint256 healthFactor;      // Current health factor (scaled by 1e18)
        uint256 leverage;          // Current leverage ratio (scaled by 1e18)
    }
    
    /* VIEW FUNCTIONS */
    
    /// @notice Get strategy parameters
    function strategyParams() external view returns (StrategyParams memory);
    
    /// @notice Get current position information
    function getPositionInfo() external view returns (PositionInfo memory);
    
    /// @notice Get current health factor
    function getHealthFactor() external view returns (uint256);
    
    /// @notice Get maximum borrowable amount based on collateral
    function getMaxBorrowable() external view returns (uint256);
    
    /// @notice Get maximum collateral that can be withdrawn
    function getMaxWithdrawable() external view returns (uint256);
    
    /// @notice Check if position needs rebalancing
    function needsRebalancing() external view returns (bool);
    
    /// @notice Get the Pendle router address
    function pendleRouter() external view returns (address);
    
    /// @notice Get the loop market parameters
    function loopMarketParams() external view returns (MarketParams memory);
    
    /* STRATEGY FUNCTIONS */
    
    /// @notice Increase leveraged position
    /// @param additionalAssets Amount of vault assets to add to position
    /// @param targetLeverage Desired leverage ratio (0 = auto-calculate)
    function increasePosition(uint256 additionalAssets, uint256 targetLeverage) external;
    
    /// @notice Decrease leveraged position
    /// @param assetsToWithdraw Amount of vault assets to withdraw from position
    function decreasePosition(uint256 assetsToWithdraw) external;
    
    /// @notice Rebalance position to maintain target health factor
    function rebalance() external;
    
    /// @notice Emergency deleverage when approaching liquidation
    function emergencyDeleverage() external;
    
    /// @notice Fully close the position
    function closePosition() external;
    
    /* ADMIN FUNCTIONS */
    
    /// @notice Update strategy parameters (only vault owner)
    /// @param newParams New strategy parameters
    function setStrategyParams(StrategyParams calldata newParams) external;
    
    /// @notice Set Pendle router address (only vault owner)
    /// @param newPendleRouter New Pendle router address
    function setPendleRouter(address newPendleRouter) external;
    
    /// @notice Set skim recipient for reward collection
    /// @param newSkimRecipient Address to receive skimmed rewards
    function setSkimRecipient(address newSkimRecipient) external;
    
    /// @notice Skim rewards or excess tokens
    /// @param token Token address to skim
    function skim(address token) external;
    
    /* INTERNAL CALCULATION FUNCTIONS */
    
    /// @notice Calculate optimal loop iterations for given assets
    /// @param assets Amount of vault assets to deploy
    /// @param targetLeverage Desired leverage ratio
    /// @return iterations Number of loop iterations needed
    function calculateOptimalLoopIterations(uint256 assets, uint256 targetLeverage) external view returns (uint256 iterations);
    
    /// @notice Simulate position after adding assets
    /// @param additionalAssets Amount of assets to add
    /// @return newHealthFactor Projected health factor
    /// @return newLeverage Projected leverage ratio
    function simulatePositionIncrease(uint256 additionalAssets) external view returns (uint256 newHealthFactor, uint256 newLeverage);
    
    /// @notice Simulate position after removing assets  
    /// @param assetsToRemove Amount of assets to remove
    /// @return newHealthFactor Projected health factor
    /// @return newLeverage Projected leverage ratio
    function simulatePositionDecrease(uint256 assetsToRemove) external view returns (uint256 newHealthFactor, uint256 newLeverage);
}