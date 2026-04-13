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
    error MintDisabled();

    uint8 internal constant SHARED_DECIMALS = 4;

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

    /// @notice Disabled owner mint hook kept only for ABI compatibility
    function mint(address, uint256) external pure {
        revert MintDisabled();
    }

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
