// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @notice Configurable mock agent that satisfies IOnchainStrategyValuer for testing
contract MockAgent {
    uint256 private _assets;
    bool private _healthy = true;
    bool private _shouldFail;

    function quoteCurrentAssets() external view returns (uint256 assets, bool healthy) {
        require(!_shouldFail, "MockAgent: forced failure");
        return (_assets, _healthy);
    }

    function setAssets(uint256 assets_) external {
        _assets = assets_;
    }

    function setHealthy(bool healthy_) external {
        _healthy = healthy_;
    }

    function setShouldFail(bool shouldFail_) external {
        _shouldFail = shouldFail_;
    }
}
