// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {BaseExecutionGateway} from "../base/BaseExecutionGateway.sol";
import {BaseStrategyModule} from "../base/BaseStrategyModule.sol";
import {BaseOftSender} from "../base/BaseOftSender.sol";
import {CrossVenueCommandLib} from "../base/CrossVenueCommandLib.sol";

/// @title BaseExecFactory
/// @notice Phase 2 of the split deploy. Takes the core contracts from `BaseCoreFactory`, deploys
///         module + gateway + OFT sender, wires them, and transfers ownership of the full stack
///         (vault + sleeve + module + gateway + oftSender) to `vaultOwner`. Valuer is owned by
///         `valuerOwner` (set in phase 1).
contract BaseExecFactory {
    error InvalidConfig();
    error InvalidAddress();

    event BaseExecDeployed(
        address indexed vaultOwner,
        address indexed vault,
        address module,
        address gateway,
        address oftSender
    );

    struct ExecParams {
        address vaultOwner;
        address asset;
        address vault;
        address sleeve;
        address[] gatewaySigners;
        uint256 gatewayThreshold;
        uint256 capPmTopUp;
        uint256 capHlTopUp;
        uint256 capRefillReserve;
        uint256 dailyCap;
        string gatewayName;
        string gatewayVersion;
    }

    struct ExecDeployment {
        address module;
        address gateway;
        address oftSender;
    }

    function deployExec(ExecParams calldata p) external returns (ExecDeployment memory d) {
        if (p.vaultOwner == address(0) || p.asset == address(0) || p.vault == address(0) || p.sleeve == address(0)) {
            revert InvalidAddress();
        }
        if (p.gatewaySigners.length == 0 || p.gatewayThreshold == 0) revert InvalidConfig();
        if (p.gatewayThreshold > p.gatewaySigners.length) revert InvalidConfig();

        BaseStrategyModule module = new BaseStrategyModule(address(this), p.asset, p.sleeve);
        d.module = address(module);
        BaseExecutionGateway gateway = new BaseExecutionGateway(
            address(this), p.vault, p.asset, d.module, p.gatewayName, p.gatewayVersion
        );
        d.gateway = address(gateway);
        BaseOftSender oftSender = new BaseOftSender(p.asset, address(this));
        oftSender.setAuthorizedCaller(d.module, true);
        d.oftSender = address(oftSender);

        // Wire module: gateway, vault, oftSender, refillSource (module = OFT inbox for returns).
        module.setGateway(d.gateway);
        module.setVault(p.vault);
        module.setOftSender(d.oftSender);
        module.setRefillSource(d.module);

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

        // Hand over ownership of module + gateway + oftSender.
        module.transferOwnership(p.vaultOwner);
        gateway.transferOwnership(p.vaultOwner);
        oftSender.setOwner(p.vaultOwner);

        emit BaseExecDeployed(p.vaultOwner, p.vault, d.module, d.gateway, d.oftSender);
    }
}
