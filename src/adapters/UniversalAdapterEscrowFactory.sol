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
        bytes32 salt
    );

    /* ERRORS */

    error InvalidVault();
    error OnlyVaultOwnerCanDeploy();

    /* STATE */

    address public immutable adapterImplementation;
    mapping(address => address[]) public vaultAdapters;
    mapping(address => bool) public isAdapter;

    constructor() {
        adapterImplementation = address(new UniversalAdapterEscrow(address(0)));
    }

    /* EXTERNAL FUNCTIONS */

    /// @notice Deploy a new UniversalAdapterEscrow
    /// @param parentVault The parent vault address
    /// @return adapter The deployed adapter address
    function deployAdapter(address parentVault, bytes32 salt) external returns (address adapter) {
        if (parentVault == address(0)) revert InvalidVault();
        if (IVaultV2(parentVault).owner() != msg.sender) revert OnlyVaultOwnerCanDeploy();

        adapter = Clones.clone(adapterImplementation);
        UniversalAdapterEscrow(payable(adapter)).initialize(parentVault);

        vaultAdapters[parentVault].push(adapter);
        isAdapter[adapter] = true;

        emit AdapterDeployed(adapter, parentVault, salt);
    }

    /// @notice Get all adapters deployed for a vault
    /// @param vault The vault address
    /// @return Array of adapter addresses
    function getVaultAdapters(address vault) external view returns (address[] memory) {
        return vaultAdapters[vault];
    }
}