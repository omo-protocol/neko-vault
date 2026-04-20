// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {VaultV2Factory} from "../VaultV2Factory.sol";
import {IVaultV2} from "../interfaces/IVaultV2.sol";
import {UniversalAdapterEscrow} from "../adapters/UniversalAdapterEscrow.sol";
import {UniversalAdapterEscrowFactory} from "../adapters/UniversalAdapterEscrowFactory.sol";
import {IUniversalAdapterEscrow} from "../adapters/interfaces/IUniversalAdapterEscrow.sol";
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

        // Wire vault → sleeve: auto-allocate user deposits into the sleeve against strategyId.
        // Without this, deposits sit idle in the vault and top-up commands revert
        // `TransferFromReverted` because the module tries to pull from an empty sleeve.
        // Flags: 1 = AUTO_ALLOCATION, 2 = AUTO_WITHDRAW. Both on → full auto round-trip.
        // Both setters are timelocked — use the factory-curator submit() trick (timelock=0 default).
        bytes memory liquidityData = abi.encode(p.strategyId, uint256(3), new IUniversalAdapterEscrow.Call[](0));
        v.submit(abi.encodeCall(IVaultV2.setIsAllocator, (address(this), true)));
        v.setIsAllocator(address(this), true);
        v.submit(abi.encodeCall(IVaultV2.setLiquidityAdapterAndData, (d.sleeve, liquidityData)));
        v.setLiquidityAdapterAndData(d.sleeve, liquidityData);
        // Sleeve returns `keccak256(liquidityData)` as the cap id (Morpho V2 pattern), so
        // cap setters receive the same liquidityData blob.
        v.submit(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (liquidityData, type(uint128).max)));
        v.increaseAbsoluteCap(liquidityData, type(uint128).max);
        v.submit(abi.encodeCall(IVaultV2.increaseRelativeCap, (liquidityData, 1e18)));
        v.increaseRelativeCap(liquidityData, 1e18);
        v.submit(abi.encodeCall(IVaultV2.setIsAllocator, (address(this), false)));
        v.setIsAllocator(address(this), false);

        // NOTE: sleeve ownership is NOT transferred here. The deploy script calls
        // `approveModuleAndTransferOwnership(sleeve, strategyId, asset, module, vaultOwner)`
        // after exec deploys the module, so sleeve approves USDC → module for top-up pulls
        // and THEN transfers ownership. One-shot, no user-visible manual step.
        v.setCurator(p.vaultOwner);
        v.setOwner(p.vaultOwner);

        emit BaseCoreDeployed(p.vaultOwner, p.asset, d.vault, d.sleeve, d.valuer, d.strategyAgent, p.strategyId);
    }

    /// @notice Post-exec step: approve module to pull USDC from sleeve, then transfer sleeve
    ///         ownership to the final vaultOwner. Must be called in the same deploy tx as
    ///         `deployCore`+`deployExec` (factory must still own sleeve).
    function approveModuleAndTransferOwnership(
        address sleeve,
        bytes32 strategyId,
        address asset,
        address module,
        address vaultOwner
    ) external {
        UniversalAdapterEscrow s = UniversalAdapterEscrow(payable(sleeve));
        // Whitelist USDC.approve(...) so we can call it from the strategy multicall path.
        // `updateWhitelistUnsafe` because USDC is a canonical proxy implementation.
        bytes4 approveSelector = bytes4(keccak256("approve(address,uint256)"));
        s.updateWhitelistUnsafe(asset, approveSelector, true, type(uint256).max);
        // Approve TWO spenders from sleeve's USDC:
        //  1. module → for outbound top-up pulls (safeTransferFrom sleeve→cctpSender)
        //  2. vault  → for withdrawal deallocations (safeTransferFrom sleeve→vault)
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](2);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: asset,
            data: abi.encodeWithSignature("approve(address,uint256)", module, type(uint256).max),
            value: 0
        });
        calls[1] = IUniversalAdapterEscrow.Call({
            target: asset,
            data: abi.encodeWithSignature("approve(address,uint256)", s.parentVault(), type(uint256).max),
            value: 0
        });
        s.executeStrategy(strategyId, calls);
        // Register module as the sleeve's settlement queue so `refillReserve` can call
        // `sleeve.recordSettlement` to reduce externalDeposits on CCTP-inbound refunds.
        // (Module's counterpart `setSleeveAndStrategyId` is wired inside `BaseExecFactory.deployExec`
        // before module ownership transfers to vaultOwner.)
        s.setSettlementQueue(module);
        s.transferOwnership(vaultOwner);
    }
}
