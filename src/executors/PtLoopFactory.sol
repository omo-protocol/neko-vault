// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PtLoopExecutor} from "./PtLoopExecutor.sol";

/// @title PtLoopFactory
/// @notice Deploys per-vault EIP-1167 clones of `PtLoopExecutor` on the chain where the PT loop
///         runs. One factory deployment per execution chain (Arb, OP, ETH, …), shared across
///         every vault that targets that chain.
///
/// @dev The factory bakes in the chain's constants (USDC, Pendle router, Balancer flash vault)
///      at construction, so each clone inherits the right addresses without per-call parameters.
///      Per-vault state (owner + strategyAgent) is set at `cloneFor` time.
///
///      Proxy addresses are deterministic via CREATE2 keyed on `(owner, strategyAgent)`, so the
///      operator can precompute the clone's address at vault-creation time and use it as the
///      CCTP `mintRecipient` on Base — no "deploy first, then route" chicken-and-egg.
contract PtLoopFactory {
    error CloneAlreadyDeployed();
    error ZeroAddress();

    /// Impl contract whose logic all clones share (immutable across the factory's lifetime).
    address public immutable impl;
    /// Chain-specific constants — all clones deployed by this factory use these.
    address public immutable usdc;
    address public immutable pendleRouter;
    address public immutable flashVault;

    event CloneDeployed(address indexed owner, address indexed strategyAgent, address clone);

    constructor(address impl_, address usdc_, address pendleRouter_, address flashVault_) {
        if (
            impl_ == address(0) || usdc_ == address(0) || pendleRouter_ == address(0)
                || flashVault_ == address(0)
        ) revert ZeroAddress();
        impl = impl_;
        usdc = usdc_;
        pendleRouter = pendleRouter_;
        flashVault = flashVault_;
    }

    /// @notice Deploy a per-vault clone at a deterministic CREATE2 address and initialize it.
    ///         Idempotent per (owner, strategyAgent) pair — calling twice reverts.
    function cloneFor(address owner, address strategyAgent) external returns (address proxy) {
        if (owner == address(0) || strategyAgent == address(0)) revert ZeroAddress();
        bytes32 salt = _saltFor(owner, strategyAgent);
        proxy = Clones.cloneDeterministic(impl, salt);
        PtLoopExecutor(proxy).initialize(usdc, pendleRouter, flashVault, owner, strategyAgent);
        emit CloneDeployed(owner, strategyAgent, proxy);
    }

    /// @notice Predict the clone address without deploying. FE uses this to configure the Base
    ///         CCTP sender's route (`dest:ptloop → (destDomain, clonePredicted, ...)`) before
    ///         first use.
    function predictClone(address owner, address strategyAgent) external view returns (address) {
        return Clones.predictDeterministicAddress(impl, _saltFor(owner, strategyAgent), address(this));
    }

    function _saltFor(address owner, address strategyAgent) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner, strategyAgent));
    }
}
