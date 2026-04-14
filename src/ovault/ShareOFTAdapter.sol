// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {OFTAdapter} from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title ShareOFTAdapter
/// @notice Lockbox adapter for VaultV2 shares on the hub chain (HyperEVM)
/// @dev Uses OFTAdapter (lockbox mechanism) to wrap existing ERC-20 vault shares
/// @dev Deployed ONLY on hub chain alongside VaultV2
/// @dev Preserves vault share supply integrity - no minting/burning of underlying shares
/// @dev When shares are bridged to spoke chains:
///      1. Real vault shares are locked in this contract
///      2. Corresponding ShareOFT tokens are minted on destination chain
/// @dev When shares return from spoke chains:
///      1. ShareOFT tokens are burned on source chain
///      2. Real vault shares are unlocked from this contract
///
/// LOCKBOX PATTERN:
/// - Unlike mint-burn OFT, this adapter locks/unlocks existing tokens
/// - Maintains one-to-one backing between vault shares and cross-chain shares
/// - Critical for preserving ERC-4626 vault accounting accuracy
/// - The share token MUST be an OFT adapter (lockbox) not mint-burn
/// - A mint-burn adapter would break ShareERC20::totalSupply() accounting
contract ShareOFTAdapter is OFTAdapter {
    uint8 internal constant SHARED_DECIMALS = 4;

    /// @notice Initializes the Share OFT Adapter
    /// @param _token Address of the VaultV2 share token (ERC-20)
    /// @param _lzEndpoint LayerZero endpoint address on hub chain
    /// @param _delegate Address with administrative control
    constructor(
        address _token,
        address _lzEndpoint,
        address _delegate
    ) OFTAdapter(_token, _lzEndpoint, _delegate) Ownable(_delegate) {}

    function sharedDecimals() public pure override returns (uint8) {
        return SHARED_DECIMALS;
    }

    function transferOwnership(address newOwner) public override onlyOwner {
        super.transferOwnership(newOwner);
        endpoint.setDelegate(newOwner);
    }

    function renounceOwnership() public override onlyOwner {
        super.renounceOwnership();
        endpoint.setDelegate(address(0));
    }
}
