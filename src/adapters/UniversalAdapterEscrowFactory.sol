// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {UniversalAdapterEscrow} from "./UniversalAdapterEscrow.sol";
import {IVaultV2} from "../interfaces/IVaultV2.sol";

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

    error InvalidVault();
    error InvalidValuer();
    error OnlyVaultOwnerCanDeploy();

    /* STATE */

    address public immutable adapterImplementation;
    mapping(address => address[]) public vaultAdapters;
    mapping(address => bool) public isAdapter;

    constructor() {
        adapterImplementation = address(new UniversalAdapterEscrow(address(0), address(0), false));
    }

    /* EXTERNAL FUNCTIONS */

    /// @notice Deploy a new UniversalAdapterEscrow
    /// @param parentVault The parent vault address
    /// @param valuer The valuer contract address
    /// @param useOffchainValuer Whether to use offchain valuation
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

        adapter = Clones.clone(adapterImplementation);
        UniversalAdapterEscrow(payable(adapter)).initialize(parentVault, valuer, useOffchainValuer);

        vaultAdapters[parentVault].push(adapter);
        isAdapter[adapter] = true;

        emit AdapterDeployed(adapter, parentVault, valuer, useOffchainValuer, salt);
    }

    /// @notice Get all adapters deployed for a vault
    /// @param vault The vault address
    /// @return Array of adapter addresses
    function getVaultAdapters(address vault) external view returns (address[] memory) {
        return vaultAdapters[vault];
    }
}