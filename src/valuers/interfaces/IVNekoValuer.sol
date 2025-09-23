// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title IVNekoValuer
/// @notice Interface for vNeko strategy valuation
interface IVNekoValuer {
    /// @notice Get total value of all vNeko strategies
    /// @param escrow The escrow address holding positions
    /// @return Total value in NEKO
    function getTotalValue(address escrow) external view returns (uint256);

    /// @notice Get value of volatility farming position
    /// @param escrow The escrow address
    /// @return Value in NEKO
    function getVolatilityFarmingValue(address escrow) external view returns (uint256);

    /// @notice Get value of lending position (Morpho V2)
    /// @param escrow The escrow address
    /// @return NPV in NEKO
    function getLendingPositionValue(address escrow) external view returns (uint256);

    /// @notice Get value of market making position
    /// @param escrow The escrow address
    /// @return Value in NEKO
    function getMarketMakingValue(address escrow) external view returns (uint256);

    /// @notice Get value of arbitrage positions
    /// @param escrow The escrow address
    /// @return Value in NEKO
    function getArbPositionValue(address escrow) external view returns (uint256);
}