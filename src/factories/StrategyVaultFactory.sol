// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {BaseCoreFactory} from "./BaseCoreFactory.sol";
import {BaseExecFactory} from "./BaseExecFactory.sol";

/// @title StrategyVaultFactory
/// @notice User-facing one-click factory: one transaction deploys an entire isolated Base-side
///         strategy stack — vault + sleeve + valuer + strategy agent + module + gateway + CCTP
///         sender — all wired together and owned by the caller's chosen `vaultOwner`.
///
///         Composes the two existing phase factories (`BaseCoreFactory.deployCore` + the
///         post-exec `approveModuleAndTransferOwnership` step + `BaseExecFactory.deployExec`)
///         into one atomic user flow. Each user gets a full isolated stack keyed on their own
///         `strategyId` — no shared state, no per-strategy Base deploy needed by the operator.
///
///         After this runs, the user calls `ArchetypeFactory.createMultiLeg` (or `createPtLoop`)
///         on Ritual with the SAME `strategyId`, and the two halves recognize each other through
///         the envelope's strategy-keyed sleeve accounting.
contract StrategyVaultFactory {
    error InvalidAddress();
    error InvalidConfig();

    event StrategyStackDeployed(
        address indexed vaultOwner,
        bytes32 indexed strategyId,
        address vault,
        address sleeve,
        address valuer,
        address strategyAgent,
        address module,
        address gateway,
        address cctpSender
    );

    BaseCoreFactory public immutable coreFactory;
    BaseExecFactory public immutable execFactory;

    constructor(address coreFactory_, address execFactory_) {
        if (coreFactory_ == address(0) || execFactory_ == address(0)) revert InvalidAddress();
        coreFactory = BaseCoreFactory(coreFactory_);
        execFactory = BaseExecFactory(execFactory_);
    }

    /// @notice Params for a full-stack deployment.
    struct DeployParams {
        /// @dev Ends up owning vault + sleeve + module + gateway + cctpSender after deployment.
        address vaultOwner;
        /// @dev Owns the valuer (for rotating valuer signers). Typically the same as `vaultOwner`,
        ///      or the adapter's Base EOA so the adapter can autonomously rotate.
        address valuerOwner;
        /// @dev USDC on this chain (0x833…2913 on Base mainnet).
        address asset;
        /// @dev Deterministic salt for CREATE2 addresses. Let the caller pick so predicted vault
        ///      address is available before tx lands (useful for off-chain prewiring).
        bytes32 salt;
        /// @dev Unique id for this strategy. Must match the Ritual controller clone's strategyId.
        bytes32 strategyId;
        /// @dev Per-strategy daily cap (sleeve-level, USDC micros).
        uint256 strategyDailyLimit;
        /// @dev Circle CCTP V2 TokenMessenger on this chain (0x28b5…cf5d cross-chain).
        address cctpTokenMessenger;
        /// @dev EIP-712 gateway signers. Typically `[adapter's Base EOA]` for single-sig demo.
        address[] gatewaySigners;
        uint256 gatewayThreshold;
        /// @dev Per-command and daily caps. Zero disables the specific cap (no limit).
        uint256 capPmTopUp;
        uint256 capHlTopUp;
        uint256 capRefillReserve;
        uint256 dailyCap;
        string gatewayName;
        string gatewayVersion;
    }

    /// @notice Full-stack deployment addresses.
    struct Deployment {
        address vault;
        address sleeve;
        address valuer;
        address strategyAgent;
        address module;
        address gateway;
        address cctpSender;
    }

    /// @notice Deploy a complete Base-side strategy stack in one transaction.
    ///         Caller provides `strategyId` + signers + caps; everything else is derived. All
    ///         ownership + wiring happens inside this function — no post-deploy admin calls
    ///         needed except configuring CCTP routes (see `configureCctpRoutes`).
    function deployStack(DeployParams calldata p) external returns (Deployment memory d) {
        if (p.vaultOwner == address(0) || p.valuerOwner == address(0) || p.asset == address(0)) {
            revert InvalidAddress();
        }
        if (p.gatewaySigners.length == 0 || p.gatewayThreshold == 0) revert InvalidConfig();
        if (p.strategyId == bytes32(0)) revert InvalidConfig();

        // Phase 1: core (vault + sleeve + valuer + NoOp agent). Ownership of vault transferred
        // to `vaultOwner`; sleeve ownership is RETAINED by coreFactory temporarily — we need
        // it in phase 2's `approveModuleAndTransferOwnership` below.
        BaseCoreFactory.CoreDeployment memory core = coreFactory.deployCore(
            BaseCoreFactory.CoreParams({
                vaultOwner: p.vaultOwner,
                valuerOwner: p.valuerOwner,
                asset: p.asset,
                salt: p.salt,
                strategyId: p.strategyId,
                strategyDailyLimit: p.strategyDailyLimit
            })
        );

        // Phase 2: exec (module + gateway + cctpSender). Ownership transferred to `vaultOwner`
        // inside deployExec.
        BaseExecFactory.ExecDeployment memory exec = execFactory.deployExec(
            BaseExecFactory.ExecParams({
                vaultOwner: p.vaultOwner,
                asset: p.asset,
                vault: core.vault,
                sleeve: core.sleeve,
                strategyId: p.strategyId,
                cctpTokenMessenger: p.cctpTokenMessenger,
                gatewaySigners: p.gatewaySigners,
                gatewayThreshold: p.gatewayThreshold,
                capPmTopUp: p.capPmTopUp,
                capHlTopUp: p.capHlTopUp,
                capRefillReserve: p.capRefillReserve,
                dailyCap: p.dailyCap,
                gatewayName: p.gatewayName,
                gatewayVersion: p.gatewayVersion,
                salt: p.salt
            })
        );

        // Phase 3: approve module to pull USDC from sleeve, register module as sleeve's
        // settlement queue, transfer sleeve ownership to vaultOwner. Atomic.
        coreFactory.approveModuleAndTransferOwnership(
            core.sleeve, p.strategyId, p.asset, exec.module, p.vaultOwner
        );

        d = Deployment({
            vault: core.vault,
            sleeve: core.sleeve,
            valuer: core.valuer,
            strategyAgent: core.strategyAgent,
            module: exec.module,
            gateway: exec.gateway,
            cctpSender: exec.cctpSender
        });

        emit StrategyStackDeployed(
            p.vaultOwner, p.strategyId,
            d.vault, d.sleeve, d.valuer, d.strategyAgent, d.module, d.gateway, d.cctpSender
        );
    }
}
