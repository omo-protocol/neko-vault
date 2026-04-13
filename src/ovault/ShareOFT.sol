// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";

/// @title ShareOFT
/// @notice Omnichain representation of VaultV2 shares on spoke chains
/// @dev ONLY deployed on spoke chains (Arbitrum, Plasma, etc.)
/// @dev Hub chain uses ShareOFTAdapter (lockbox pattern) instead
/// @dev Represents ownership in the vault on HyperEVM
/// @dev Users receive these tokens after cross-chain deposits
///
/// WARNING: Share tokens should only be minted by vault deposits on hub chain!
/// - Direct minting breaks vault accounting and share price calculations
/// - The adapter on hub chain locks actual vault shares 1:1 with these tokens
/// - Minting here is ONLY for testing UI/integration, NEVER in production
contract ShareOFT is OFT {
    uint8 internal constant SHARED_DECIMALS = 4;

    /// @notice Initializes the Share OFT contract
    /// @param _name Token name (e.g., "VaultV2 Shares")
    /// @param _symbol Token symbol (e.g., "vUSDT")
    /// @param _lzEndpoint LayerZero endpoint address for this chain
    /// @param _delegate Contract owner/delegate address
    constructor(
        string memory _name,
        string memory _symbol,
        address _lzEndpoint,
        address _delegate
    ) OFT(_name, _symbol, _lzEndpoint, _delegate) Ownable(_delegate) {}

    function sharedDecimals() public pure override returns (uint8) {
        return SHARED_DECIMALS;
    }

    function transferOwnership(address newOwner) public override onlyOwner {
        super.transferOwnership(newOwner);
        endpoint.setDelegate(newOwner);
    }

    // NOTE: The LayerZero OFT standard needs to mint/burn during cross-chain transfers
    // This is different from the hub's ShareOFTAdapter which uses a lockbox pattern
    // On spoke chains, shares are minted when bridged FROM hub, burned when bridged TO hub
    // The hub's adapter ensures 1:1 backing with real vault shares
}
