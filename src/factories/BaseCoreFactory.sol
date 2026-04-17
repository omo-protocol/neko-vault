// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {VaultV2Factory} from "../VaultV2Factory.sol";
import {IVaultV2} from "../interfaces/IVaultV2.sol";
import {UniversalAdapterEscrow} from "../adapters/UniversalAdapterEscrow.sol";
import {UniversalAdapterEscrowFactory} from "../adapters/UniversalAdapterEscrowFactory.sol";
import {UniversalValuerOffchain} from "../valuers/UniversalValuerOffchain.sol";
import {NoOpStrategyAgent} from "../base/NoOpStrategyAgent.sol";

/// @title BaseCoreFactory
/// @notice Phase 1 of the split Base-custody deploy. Deploys vault + sleeve + valuer + NoOp
///         strategy agent, registers the sleeve on the vault, activates the strategy on the
///         sleeve, and transfers vault + sleeve ownership to `vaultOwner`.
///         Pair with `BaseExecFactory` for phase 2 (module + gateway + OFT sender).
contract BaseCoreFactory {
    error InvalidAddress();

    event BaseCoreDeployed(
        address indexed vaultOwner,
        address indexed asset,
        address vault,
        address sleeve,
        address valuer,
        address strategyAgent,
        bytes32 strategyId
    );

    VaultV2Factory public immutable vaultFactory;
    UniversalAdapterEscrowFactory public immutable adapterFactory;

    constructor(address vaultFactory_, address adapterFactory_) {
        if (vaultFactory_ == address(0) || adapterFactory_ == address(0)) revert InvalidAddress();
        vaultFactory = VaultV2Factory(vaultFactory_);
        adapterFactory = UniversalAdapterEscrowFactory(adapterFactory_);
    }

    struct CoreParams {
        address vaultOwner;
        address valuerOwner;
        address asset;
        bytes32 salt;
        bytes32 strategyId;
        uint256 strategyDailyLimit;
    }

    struct CoreDeployment {
        address vault;
        address sleeve;
        address valuer;
        address strategyAgent;
    }

    function deployCore(CoreParams calldata p) external returns (CoreDeployment memory d) {
        if (p.vaultOwner == address(0) || p.valuerOwner == address(0) || p.asset == address(0)) {
            revert InvalidAddress();
        }

        d.vault = vaultFactory.createVaultV2(address(this), p.asset, p.salt);
        d.sleeve = adapterFactory.deployAdapter(d.vault, p.salt);
        d.valuer = address(new UniversalValuerOffchain(p.valuerOwner, p.asset));
        d.strategyAgent = address(new NoOpStrategyAgent(d.valuer, p.strategyId));

        // Register sleeve as a vault adapter (factory-curator path, timelock default 0).
        IVaultV2 v = IVaultV2(d.vault);
        v.setCurator(address(this));
        bytes memory data = abi.encodeCall(IVaultV2.addAdapter, (d.sleeve));
        v.submit(data);
        v.addAdapter(d.sleeve);

        // Activate strategy on sleeve (factory is still sleeve owner).
        UniversalAdapterEscrow(payable(d.sleeve)).setStrategy(
            p.strategyId, d.strategyAgent, bytes(""), p.strategyDailyLimit
        );

        // Hand over vault + sleeve ownership to the final vaultOwner.
        UniversalAdapterEscrow(payable(d.sleeve)).transferOwnership(p.vaultOwner);
        v.setCurator(p.vaultOwner);
        v.setOwner(p.vaultOwner);

        emit BaseCoreDeployed(p.vaultOwner, p.asset, d.vault, d.sleeve, d.valuer, d.strategyAgent, p.strategyId);
    }
}
