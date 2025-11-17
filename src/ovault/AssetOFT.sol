// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";

/// @title AssetOFT
/// @notice Omnichain Fungible Token for vault underlying assets (e.g., USDT, USDC)
/// @dev Deployed on all chains (Hub: HyperEVM + Spokes: Arbitrum, Plasma)
/// @dev Enables cross-chain transfers of vault collateral assets
/// @dev Uses LayerZero OFT standard for omnichain fungibility
contract AssetOFT is OFT {
    /// @notice Initializes the Asset OFT contract
    /// @param _name Token name (e.g., "USD Tether")
    /// @param _symbol Token symbol (e.g., "USDT")
    /// @param _lzEndpoint LayerZero endpoint address for this chain
    /// @param _delegate Contract owner/delegate address
    constructor(
        string memory _name,
        string memory _symbol,
        address _lzEndpoint,
        address _delegate
    ) OFT(_name, _symbol, _lzEndpoint, _delegate) Ownable(_delegate) {}

    /// @notice Mints initial tokens for testing/liquidity
    /// @dev Should only be called during deployment for initial setup
    /// @dev In production, consider restricting or removing this function
    /// @param _to Address to receive minted tokens
    /// @param _amount Amount of tokens to mint
    function mint(address _to, uint256 _amount) external onlyOwner {
        _mint(_to, _amount);
    }
}
