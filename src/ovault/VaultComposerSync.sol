// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {VaultComposerSync as BaseVaultComposerSync} from "@layerzerolabs/ovault-evm/contracts/VaultComposerSync.sol";

/// @title VaultComposerSync
/// @notice Orchestrates cross-chain ERC-4626 vault operations on the hub chain
/// @dev Deployed ONLY on hub chain (HyperEVM) alongside VaultV2
/// @dev Receives composed messages from spoke chains and executes vault deposits/withdrawals
/// @dev Automatically routes resulting tokens (shares/assets) to destination chains
/// @dev Inherits from LayerZero's VaultComposerSync base implementation
///
/// ARCHITECTURE:
/// Hub Chain (HyperEVM):
///   - VaultV2 (ERC-4626 vault) - NO CHANGES NEEDED
///   - VaultComposerSync (this contract)
///   - AssetOFT (underlying asset)
///   - ShareOFTAdapter (lockbox for vault shares)
///
/// Spoke Chains (Arbitrum, Plasma):
///   - AssetOFT (same asset, bridged)
///   - ShareOFT (vault shares representation)
///
/// CROSS-CHAIN DEPOSIT FLOW:
/// 1. User calls AssetOFT.send() on spoke chain with composeMsg
/// 2. Assets are bridged to hub chain
/// 3. This composer receives lzCompose() callback
/// 4. Composer deposits assets into VaultV2
/// 5. Vault mints shares to composer
/// 6. Composer sends shares back to user via ShareOFTAdapter
///
/// CROSS-CHAIN WITHDRAWAL FLOW:
/// 1. User calls ShareOFT.send() on spoke chain with composeMsg
/// 2. Shares are bridged to hub chain (unlocked from adapter)
/// 3. This composer receives lzCompose() callback
/// 4. Composer redeems shares from VaultV2
/// 5. Vault burns shares and returns assets
/// 6. Composer sends assets back to user via AssetOFT
///
/// SLIPPAGE PROTECTION:
/// - Phase 1: Standard OFT transfer minimum amount (in transit)
/// - Phase 2: Vault conversion slippage via minAmountLD in compose message
///
/// FAILURE HANDLING:
/// - Insufficient gas: Automatic protocol-level refund
/// - Slippage exceeded: Manual refund from hub chain
/// - Invalid message: Revert (tokens stay on source chain)
contract VaultComposerSync is BaseVaultComposerSync {
    /// @notice Initializes the vault composer
    /// @param _vault VaultV2 contract address (ERC-4626 compliant)
    /// @param _assetOFT Asset OFT contract address
    /// @param _shareOFT Share OFT Adapter contract address (lockbox on hub)
    constructor(
        address _vault,
        address _assetOFT,
        address _shareOFT
    ) BaseVaultComposerSync(_vault, _assetOFT, _shareOFT) {}
}
