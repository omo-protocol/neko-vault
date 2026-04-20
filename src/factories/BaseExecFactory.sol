// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {BaseExecutionGateway} from "../base/BaseExecutionGateway.sol";
import {BaseStrategyModule} from "../base/BaseStrategyModule.sol";
import {BaseCctpSender} from "../base/BaseCctpSender.sol";
import {CrossVenueCommandLib} from "../base/CrossVenueCommandLib.sol";

/// @title BaseExecFactory
/// @notice Phase 2 of the split deploy. EIP-1167-based: one sentinel of each (module + gateway +
///         cctp sender) is deployed at factory construction, and every user stack gets minimal
///         45-byte proxies cloned via CREATE2 — roughly 20× cheaper than `new` each.
///
///         Takes the core contracts from `BaseCoreFactory`, clones + initializes module +
///         gateway + CCTP sender, wires them, and transfers ownership of the full stack
///         (vault + sleeve + module + gateway + cctpSender) to `vaultOwner`.
contract BaseExecFactory {
    error InvalidConfig();
    error InvalidAddress();

    event BaseExecDeployed(
        address indexed vaultOwner,
        address indexed vault,
        address module,
        address gateway,
        address cctpSender
    );

    /// @notice Shared implementations cloned per-user. Deployed once at factory construction.
    address public immutable moduleImpl;
    address public immutable gatewayImpl;
    address public immutable cctpSenderImpl;

    constructor() {
        moduleImpl = address(new BaseStrategyModule());
        gatewayImpl = address(new BaseExecutionGateway());
        cctpSenderImpl = address(new BaseCctpSender());
    }

    struct ExecParams {
        address vaultOwner;
        address asset;
        address vault;
        address sleeve;
        bytes32 strategyId;
        address cctpTokenMessenger;
        address[] gatewaySigners;
        uint256 gatewayThreshold;
        uint256 capPmTopUp;
        uint256 capHlTopUp;
        uint256 capRefillReserve;
        uint256 dailyCap;
        string gatewayName;
        string gatewayVersion;
        /// @dev Deterministic CREATE2 salt for the three clones. Pass `keccak256(strategyId)`
        ///      or similar so per-user stack addresses are predictable.
        bytes32 salt;
    }

    struct ExecDeployment {
        address module;
        address gateway;
        address cctpSender;
    }

    function deployExec(ExecParams calldata p) external returns (ExecDeployment memory d) {
        if (p.vaultOwner == address(0) || p.asset == address(0) || p.vault == address(0) || p.sleeve == address(0)) {
            revert InvalidAddress();
        }
        if (p.cctpTokenMessenger == address(0)) revert InvalidAddress();
        if (p.gatewaySigners.length == 0 || p.gatewayThreshold == 0) revert InvalidConfig();
        if (p.gatewayThreshold > p.gatewaySigners.length) revert InvalidConfig();

        // Three cheap CREATE2 clones. Each ~45 bytes of proxy bytecode + init.
        d.module = Clones.cloneDeterministic(moduleImpl, keccak256(abi.encode(p.salt, "module")));
        d.gateway = Clones.cloneDeterministic(gatewayImpl, keccak256(abi.encode(p.salt, "gateway")));
        d.cctpSender = Clones.cloneDeterministic(cctpSenderImpl, keccak256(abi.encode(p.salt, "cctp")));

        BaseStrategyModule module = BaseStrategyModule(d.module);
        BaseExecutionGateway gateway = BaseExecutionGateway(d.gateway);
        BaseCctpSender cctpSender = BaseCctpSender(payable(d.cctpSender));

        // Init each proxy. Factory retains owner briefly to finish wiring.
        module.initialize(address(this), p.asset, p.sleeve);
        gateway.initialize(address(this), p.vault, p.asset, d.module, p.gatewayName, p.gatewayVersion);
        cctpSender.initialize(p.asset, p.cctpTokenMessenger, address(this));

        cctpSender.setAuthorizedCaller(d.module, true);

        // Wire module: gateway, vault, cctpSender, refillSource, and sleeve+strategyId binding.
        module.setGateway(d.gateway);
        module.setVault(p.vault);
        module.setCctpSender(d.cctpSender);
        module.setRefillSource(d.module);
        if (p.strategyId != bytes32(0)) {
            module.setSleeveAndStrategyId(p.sleeve, p.strategyId);
        }

        // Gateway: signers + threshold + caps.
        uint256 sl = p.gatewaySigners.length;
        for (uint256 i; i < sl; i++) {
            gateway.setSigner(p.gatewaySigners[i], true);
        }
        gateway.setThreshold(p.gatewayThreshold);
        if (p.capPmTopUp > 0) {
            gateway.setCommandCap(CrossVenueCommandLib.CommandType.TOPUP_PM_BUFFER, p.capPmTopUp);
        }
        if (p.capHlTopUp > 0) {
            gateway.setCommandCap(CrossVenueCommandLib.CommandType.TOPUP_HL_BUFFER, p.capHlTopUp);
        }
        if (p.capRefillReserve > 0) {
            gateway.setCommandCap(CrossVenueCommandLib.CommandType.REFILL_RESERVE, p.capRefillReserve);
        }
        if (p.dailyCap > 0) gateway.setDailyCap(p.dailyCap);

        // Hand over ownership of module + gateway + cctpSender.
        module.transferOwnership(p.vaultOwner);
        gateway.transferOwnership(p.vaultOwner);
        cctpSender.setOwner(p.vaultOwner);

        emit BaseExecDeployed(p.vaultOwner, p.vault, d.module, d.gateway, d.cctpSender);
    }

    /// @notice Predict CREATE2 addresses for a given salt. FE uses this to pre-wire routes
    ///         or CCTP destinations before the stack is deployed.
    function predict(bytes32 salt) external view returns (address module, address gateway, address cctpSender) {
        module = Clones.predictDeterministicAddress(moduleImpl, keccak256(abi.encode(salt, "module")), address(this));
        gateway = Clones.predictDeterministicAddress(gatewayImpl, keccak256(abi.encode(salt, "gateway")), address(this));
        cctpSender = Clones.predictDeterministicAddress(cctpSenderImpl, keccak256(abi.encode(salt, "cctp")), address(this));
    }
}
