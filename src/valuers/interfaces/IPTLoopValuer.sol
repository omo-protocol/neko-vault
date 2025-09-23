// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title IPTLoopValuer
/// @notice Interface for PT-kHYPE loop strategy valuation
interface IPTLoopValuer {
    /// @notice Get total NPV of PT loop position
    /// @param escrow The escrow address holding positions
    /// @return Net position value in kHYPE
    function getPTLoopValue(address escrow) external view returns (uint256);

    /// @notice Get health factor of the leveraged position
    /// @param escrow The escrow address
    /// @return Health factor (1e18 = 1.0)
    function getHealthFactor(address escrow) external view returns (uint256);

    /// @notice Get current leverage ratio
    /// @param escrow The escrow address
    /// @return Leverage ratio (1e18 = 1.0x)
    function getLeverageRatio(address escrow) external view returns (uint256);

    /// @notice Get breakdown of position components
    /// @param escrow The escrow address
    /// @return freePT Free PT tokens not used as collateral
    /// @return collateralPT PT tokens used as collateral
    /// @return debt Borrowed kHYPE amount
    /// @return freeUnderlying Free kHYPE balance
    function getComponentValues(address escrow)
        external
        view
        returns (
            uint256 freePT,
            uint256 collateralPT,
            uint256 debt,
            uint256 freeUnderlying
        );
}