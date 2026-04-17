// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {VaultV2Factory} from "../VaultV2Factory.sol";
import {IVaultV2} from "../interfaces/IVaultV2.sol";
import {UniversalAdapterEscrow} from "../adapters/UniversalAdapterEscrow.sol";
import {UniversalAdapterEscrowFactory} from "../adapters/UniversalAdapterEscrowFactory.sol";
import {UniversalValuerOffchain} from "../valuers/UniversalValuerOffchain.sol";
import {BaseExecutionGateway} from "../base/BaseExecutionGateway.sol";
import {BaseStrategyModule} from "../base/BaseStrategyModule.sol";
import {BaseOftSender} from "../base/BaseOftSender.sol";
import {NoOpStrategyAgent} from "../base/NoOpStrategyAgent.sol";
import {CrossVenueCommandLib} from "../base/CrossVenueCommandLib.sol";

/// @title BaseCustodyFactory
/// @notice One-tx Base-side deploy: VaultV2 + sleeve + valuer + gateway + module + OFT sender
///         + NoOp strategy agent, fully wired. Registers sleeve as vault adapter, activates the
///         strategy on the sleeve, and transfers ownership of each component to `vaultOwner` at
///         the end.
///
///         **Post-deploy steps left to the operator (valuer is owned by `valuerOwner`, not the
///         factory, so the factory can't configure it):**
///           1. `valuer.initiateSignerChange(<adapter Base EOA>, true, weight)` for each signer
///           2. `valuer.setRequiredWeight(<M>)`
///           3. (optional) vault curator sets `liquidityAdapter = sleeve` if auto-allocation desired
///           4. `oftSender.configureRoute(<destRef>, <Route>)` per venue
///           5. Fund `oftSender` with native for LZ fees
contract BaseCustodyFactory {
    error InvalidAddress();
    error InvalidConfig();

    event BaseCustodyDeployed(
        address indexed vaultOwner,
        address indexed asset,
        address vault,
        address sleeve,
        address valuer,
        address gateway,
        address module,
        address oftSender,
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

    struct DeployParams {
        address vaultOwner; // final owner of vault / module / gateway / oftSender / sleeve
        address valuerOwner; // final owner of UniversalValuerOffchain; typically adapter's Base EOA
        address asset;
        bytes32 salt;
        bytes32 strategyId; // strategy identifier used by sleeve + valuer
        uint256 strategyDailyLimit; // sleeve per-strategy daily spending cap
        // Gateway quorum & caps
        address[] gatewaySigners;
        uint256 gatewayThreshold;
        uint256 capPmTopUp;
        uint256 capHlTopUp;
        uint256 capRefillReserve;
        uint256 dailyCap;
        // Gateway EIP-712 domain
        string gatewayName;
        string gatewayVersion;
    }

    struct Deployment {
        address vault;
        address sleeve;
        address valuer;
        address gateway;
        address module;
        address oftSender;
        address strategyAgent;
    }

    function deploy(DeployParams calldata params) external returns (Deployment memory d) {
        if (params.vaultOwner == address(0) || params.asset == address(0) || params.valuerOwner == address(0)) {
            revert InvalidAddress();
        }
        if (params.gatewaySigners.length == 0 || params.gatewayThreshold == 0) revert InvalidConfig();
        if (params.gatewayThreshold > params.gatewaySigners.length) revert InvalidConfig();

        // 1. Vault (factory as interim owner).
        d.vault = vaultFactory.createVaultV2(address(this), params.asset, params.salt);

        // 2. Sleeve (inherits factory as owner from vault).
        d.sleeve = adapterFactory.deployAdapter(d.vault, params.salt);

        // 3. Valuer owned by `valuerOwner` (immutable). Operator configures signers post-deploy.
        d.valuer = address(new UniversalValuerOffchain(params.valuerOwner, params.asset));

        // 4. NoOp strategy agent (interface-conformance only).
        d.strategyAgent = address(new NoOpStrategyAgent(d.valuer, params.strategyId));

        // 5. Module, gateway, OFT sender (factory as interim owner on each).
        BaseStrategyModule module = new BaseStrategyModule(address(this), params.asset, d.sleeve);
        d.module = address(module);
        BaseExecutionGateway gateway = new BaseExecutionGateway(
            address(this), d.vault, params.asset, d.module, params.gatewayName, params.gatewayVersion
        );
        d.gateway = address(gateway);
        BaseOftSender oftSender = new BaseOftSender(params.asset, address(this));
        oftSender.setAuthorizedCaller(d.module, true);
        d.oftSender = address(oftSender);

        // 6. Register sleeve as a vault adapter. Flow: factory becomes curator → submit → execute.
        _registerVaultAdapter(d.vault, d.sleeve);

        // 7. Activate strategy on sleeve (factory is still sleeve owner).
        UniversalAdapterEscrow(payable(d.sleeve)).setStrategy(
            params.strategyId, d.strategyAgent, bytes(""), params.strategyDailyLimit
        );

        // 8. Wire module: gateway, vault, oftSender, refillSource (module = OFT inbox for returns).
        module.setGateway(d.gateway);
        module.setVault(d.vault);
        module.setOftSender(d.oftSender);
        module.setRefillSource(d.module);

        // 9. Gateway: signers + threshold + caps.
        for (uint256 i; i < params.gatewaySigners.length; i++) {
            gateway.setSigner(params.gatewaySigners[i], true);
        }
        gateway.setThreshold(params.gatewayThreshold);
        if (params.capPmTopUp > 0) {
            gateway.setCommandCap(CrossVenueCommandLib.CommandType.TOPUP_PM_BUFFER, params.capPmTopUp);
        }
        if (params.capHlTopUp > 0) {
            gateway.setCommandCap(CrossVenueCommandLib.CommandType.TOPUP_HL_BUFFER, params.capHlTopUp);
        }
        if (params.capRefillReserve > 0) {
            gateway.setCommandCap(CrossVenueCommandLib.CommandType.REFILL_RESERVE, params.capRefillReserve);
        }
        if (params.dailyCap > 0) gateway.setDailyCap(params.dailyCap);

        // 10. Hand over ownership to vaultOwner.
        module.transferOwnership(params.vaultOwner);
        gateway.transferOwnership(params.vaultOwner);
        oftSender.setOwner(params.vaultOwner);
        // Sleeve + vault: factory is still owner. Transfer.
        UniversalAdapterEscrow(payable(d.sleeve)).transferOwnership(params.vaultOwner);
        IVaultV2(d.vault).setCurator(params.vaultOwner);
        IVaultV2(d.vault).setOwner(params.vaultOwner);

        emit BaseCustodyDeployed(
            params.vaultOwner,
            params.asset,
            d.vault,
            d.sleeve,
            d.valuer,
            d.gateway,
            d.module,
            d.oftSender,
            d.strategyAgent,
            params.strategyId
        );
    }

    /// @dev Register `sleeve` as a vault adapter via the vault's submit/timelocked pattern.
    ///      Factory is vault owner, sets itself as curator, submits, executes (timelock defaults to 0).
    function _registerVaultAdapter(address vault, address sleeve) internal {
        IVaultV2 v = IVaultV2(vault);
        v.setCurator(address(this));
        bytes memory data = abi.encodeCall(IVaultV2.addAdapter, (sleeve));
        v.submit(data);
        v.addAdapter(sleeve);
    }
}
