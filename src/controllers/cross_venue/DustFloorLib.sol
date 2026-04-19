// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title DustFloorLib
/// @notice Relative-dust-floor helpers: floors are stored as bps of deployable capital
///         (NAV − Base reserve) so behavior scales with vault size. Extracted from
///         MultiLegController to keep the clone under EIP-170 runtime size.
library DustFloorLib {
    /// @dev deployable = max(0, nav − reserve). Zero before the first valuation — in that
    ///      case all derived floors are 0 and the caller's `< floor` check never suppresses.
    function deployableUsd(uint256 nav, uint256 reserve) internal pure returns (uint256) {
        return nav > reserve ? nav - reserve : 0;
    }

    /// @dev Convert a bps dust floor against current deployable into absolute USD.
    function floorUsd(uint256 nav, uint256 reserve, uint256 bps) internal pure returns (uint256) {
        if (bps == 0) return 0;
        uint256 dep = nav > reserve ? nav - reserve : 0;
        return (dep * bps) / 10_000;
    }
}
