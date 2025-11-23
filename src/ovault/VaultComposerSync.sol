// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {VaultComposerSync as BaseVaultComposerSync} from "@layerzerolabs/ovault-evm/contracts/VaultComposerSync.sol";
import {IOFT, SendParam, MessagingFee} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

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

    /// @notice Get quote for cross-chain vault operation
    /// @dev SECURITY FIX: Overrides base implementation to remove max* checks
    ///      VaultV2 returns 0 for maxDeposit/maxRedeem due to gate unpredictability
    ///      (gates can arbitrarily revert, so conservative design returns 0)
    ///      
    ///      Quote is an ESTIMATE only. Actual execution may fail if:
    ///      - Gates block the operation (validated at execution time in deposit/redeem)
    ///      - Insufficient balance/allowance
    ///      - Share price changes significantly (use slippage protection in composeMsg)
    ///      - LayerZero message fails (out of gas, DVN unavailable, etc.)
    ///      
    ///      This is acceptable because cross-chain operations already have many
    ///      potential failure points. Quote provides messaging fee estimate for UX.
    ///      Actual validation happens atomically during send() execution.
    ///
    /// @param _targetOFT Target OFT to send (ASSET_OFT or SHARE_OFT)
    /// @param _vaultInAmount Amount in vault terms (shares for redeem, assets for deposit)
    /// @param _sendParam OFT send parameters (will be modified with correct amountLD)
    /// @return MessagingFee Cross-chain messaging fee estimate
    function quoteSend(
        address /* _from */,
        address _targetOFT,
        uint256 _vaultInAmount,
        SendParam memory _sendParam
    ) external view override returns (MessagingFee memory) {
        // SECURITY FIX: Removed max* checks - incompatible with VaultV2's conservative design
        // VaultV2.maxDeposit/maxRedeem return 0 to maintain ERC-4626 revert-free guarantee
        // Actual gate validation happens at execution time (deposit/redeem calls)
        
        if (_targetOFT == ASSET_OFT) {
            // Withdrawing: Convert shares to assets estimate
            // VaultV2.previewRedeem calculates assets user would receive for given shares
            _sendParam.amountLD = VAULT.previewRedeem(_vaultInAmount);
        } else {
            // Depositing: Convert assets to shares estimate  
            // VaultV2.previewDeposit calculates shares user would receive for given assets
            _sendParam.amountLD = VAULT.previewDeposit(_vaultInAmount);
        }
        
        // Get LayerZero messaging fee for the cross-chain send
        return IOFT(_targetOFT).quoteSend(_sendParam, false);
    }
}
