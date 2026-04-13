// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {UniversalAdapterEscrow} from "./UniversalAdapterEscrow.sol";
import {IVaultV2} from "../interfaces/IVaultV2.sol";

/// @title UniversalAdapterEscrowFactory
/// @notice Factory contract for deploying UniversalAdapterEscrow instances with deterministic addresses
/// @dev Uses CREATE2 for predictable deployment addresses
contract UniversalAdapterEscrowFactory {
    /* EVENTS */

    event AdapterDeployed(
        address indexed adapter,
        address indexed parentVault,
        address indexed valuer,
        bool useOffchainValuer,
        bytes32 salt
    );

    /* ERRORS */

    error DeploymentFailed();
    error InvalidVault();
    error InvalidValuer();
    error OnlyVaultOwnerCanDeploy();

    /* STATE */

    mapping(address => address[]) public vaultAdapters;
    mapping(address => bool) public isAdapter;

    /* EXTERNAL FUNCTIONS */

    /// @notice Deploy a new UniversalAdapterEscrow
    /// @param parentVault The parent vault address
    /// @param valuer The valuer contract address
    /// @param useOffchainValuer Whether to use offchain valuation
    /// @param salt Salt for CREATE2 deployment
    /// @return adapter The deployed adapter address
    function deployAdapter(
        address parentVault,
        address valuer,
        bool useOffchainValuer,
        bytes32 salt
    ) external returns (address adapter) {
        if (parentVault == address(0)) revert InvalidVault();
        if (useOffchainValuer && valuer == address(0)) revert InvalidValuer();
        if (IVaultV2(parentVault).owner() != msg.sender) revert OnlyVaultOwnerCanDeploy();

        adapter = _deploy(parentVault, valuer, useOffchainValuer, salt);

        vaultAdapters[parentVault].push(adapter);
        isAdapter[adapter] = true;

        emit AdapterDeployed(adapter, parentVault, valuer, useOffchainValuer, salt);
    }

    /// @notice Compute the address of a adapter before deployment
    /// @param parentVault The parent vault address
    /// @param valuer The valuer contract address
    /// @param useOffchainValuer Whether to use offchain valuation
    /// @param salt Salt for CREATE2 deployment
    /// @return The computed address
    function computeAddress(
        address parentVault,
        address valuer,
        bool useOffchainValuer,
        bytes32 salt
    ) external view returns (address) {
        bytes memory bytecode = _getBytecode(parentVault, valuer, useOffchainValuer);
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(bytecode)
            )
        );
        return address(uint160(uint256(hash)));
    }

    /// @notice Get all adapters deployed for a vault
    /// @param vault The vault address
    /// @return Array of adapter addresses
    function getVaultAdapters(address vault) external view returns (address[] memory) {
        return vaultAdapters[vault];
    }

    /* INTERNAL FUNCTIONS */

    /// @notice Deploy the adapter using CREATE2
    /// @param parentVault The parent vault address
    /// @param valuer The valuer contract address
    /// @param useOffchainValuer Whether to use offchain valuation
    /// @param salt Salt for CREATE2 deployment
    /// @return adapter The deployed adapter address
    function _deploy(
        address parentVault,
        address valuer,
        bool useOffchainValuer,
        bytes32 salt
    ) internal returns (address adapter) {
        bytes memory bytecode = _getBytecode(parentVault, valuer, useOffchainValuer);

        assembly {
            adapter := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }

        if (adapter == address(0)) revert DeploymentFailed();
    }

    /// @notice Get the bytecode for deployment
    /// @param parentVault The parent vault address
    /// @param valuer The valuer contract address
    /// @param useOffchainValuer Whether to use offchain valuation
    /// @return The contract bytecode
    function _getBytecode(
        address parentVault,
        address valuer,
        bool useOffchainValuer
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(UniversalAdapterEscrow).creationCode,
            abi.encode(parentVault, valuer, useOffchainValuer)
        );
    }
}