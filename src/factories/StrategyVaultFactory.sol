// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IVaultV2} from "../interfaces/IVaultV2.sol";
import {IVaultV2Factory} from "../interfaces/IVaultV2Factory.sol";
import {UniversalAdapterEscrow} from "../adapters/UniversalAdapterEscrow.sol";
import {UniversalAdapterEscrowFactory} from "../adapters/UniversalAdapterEscrowFactory.sol";
import {DeltaNeutralController} from "../controllers/DeltaNeutralController.sol";
import {PTLoopController} from "../controllers/PTLoopController.sol";
import {CoreWriter} from "../controllers/venue_specific/hyperliquid/CoreWriter.sol";
import {IPendleRouter} from "../controllers/venue_specific/pendle/PendleLib.sol";
import {WrapperOnlySendAssetsGate} from "../gates/WrapperOnlySendAssetsGate.sol";
import {AsyncWithdrawalQueue} from "../queues/AsyncWithdrawalQueue.sol";
import {
    StrategyKind,
    Deployment,
    DeltaNeutralDeploymentParams,
    PTLoopDeploymentParams
} from "../strategies/StrategyTypes.sol";
import {VaultTimeLockWrapper} from "../VaultTimeLockWrapper.sol";

contract StrategyVaultFactory is ReentrancyGuard {
    uint256 internal constant DEFAULT_TIMELOCK_FORCE_DEALLOCATE_PENALTY = 0.01e18;

    error InvalidAddress();
    error InvalidConfig();

    IVaultV2Factory public immutable vaultFactory;
    UniversalAdapterEscrowFactory public immutable adapterFactory;
    mapping(address vault => address wrapper) public timeLockWrapperOf;
    mapping(address vault => address gate) public depositGateOf;
    mapping(address vault => address queue) public withdrawalQueueOf;

    event StrategyVaultDeployed(
        StrategyKind indexed kind,
        address indexed owner,
        address indexed vault,
        address controller,
        address sleeve,
        address wrapper,
        bytes32 strategyId,
        bytes32 salt
    );
    event AsyncWithdrawalQueueDeployed(address indexed vault, address indexed queue);

    constructor(address vaultFactory_, address adapterFactory_) {
        if (vaultFactory_ == address(0) || adapterFactory_ == address(0)) revert InvalidAddress();
        vaultFactory = IVaultV2Factory(vaultFactory_);
        adapterFactory = UniversalAdapterEscrowFactory(adapterFactory_);
    }

    function createDeltaNeutralVault(DeltaNeutralDeploymentParams calldata params)
        external
        nonReentrant
        returns (Deployment memory deployment)
    {
        _validateCommon(
            params.owner,
            params.asset,
            params.valuer,
            params.useOffchainValuer,
            params.strategyIdData,
            params.absoluteCap,
            params.relativeCap
        );

        bytes32 strategyId = keccak256(params.strategyIdData);
        bytes32 salt = _deriveSalt(StrategyKind.DeltaNeutral, params.owner, strategyId, params.salt);
        address vaultAddress = vaultFactory.createVaultV2(address(this), params.asset, salt);
        UniversalAdapterEscrow sleeve = UniversalAdapterEscrow(
            payable(adapterFactory.deployAdapter(vaultAddress, params.valuer, params.useOffchainValuer, salt))
        );

        DeltaNeutralController controller = new DeltaNeutralController(
            params.owner,
            _finalVaultManager(params.owner, params.vaultManager),
            vaultAddress,
            address(sleeve),
            strategyId,
            params.targetReserveBps,
            params.venueConfig,
            params.spotSideMode,
            params.maxDeltaBps,
            params.kellyConfig,
            params.automationConfig
        );

        address wrapper;
        address depositGate;
        if (params.enableTimelock) {
            wrapper = address(new VaultTimeLockWrapper(vaultAddress));
            depositGate = address(new WrapperOnlySendAssetsGate(wrapper));
        }

        _configureDeltaNeutralWhitelist(sleeve, params.venueConfig.venue);
        address queue = _deployAsyncWithdrawalQueue(vaultAddress, address(sleeve), address(controller), params.owner, true);
        if (queue != address(0)) {
            sleeve.setSettlementQueue(queue);
        }
        _configureVault(
            IVaultV2(vaultAddress),
            sleeve,
            address(controller),
            wrapper,
            depositGate,
            params.owner,
            _finalCurator(params.owner, params.curator),
            params.name,
            params.symbol,
            params.strategyIdData,
            strategyId,
            params.absoluteCap,
            params.relativeCap,
            address(sleeve),
            controller.liquidityData(),
            params.enableTimelock
        );

        deployment = Deployment({
            vault: vaultAddress,
            sleeve: address(sleeve),
            controller: address(controller),
            wrapper: wrapper,
            strategyId: strategyId
        });
        timeLockWrapperOf[vaultAddress] = wrapper;
        depositGateOf[vaultAddress] = depositGate;
        withdrawalQueueOf[vaultAddress] = queue;

        emit StrategyVaultDeployed(
            StrategyKind.DeltaNeutral,
            params.owner,
            vaultAddress,
            address(controller),
            address(sleeve),
            wrapper,
            strategyId,
            salt
        );
    }

    function createPTLoopVault(PTLoopDeploymentParams calldata params)
        external
        nonReentrant
        returns (Deployment memory deployment)
    {
        _validateCommon(
            params.owner,
            params.asset,
            params.valuer,
            params.useOffchainValuer,
            params.strategyIdData,
            params.absoluteCap,
            params.relativeCap
        );

        bytes32 strategyId = keccak256(params.strategyIdData);
        bytes32 salt = _deriveSalt(StrategyKind.PTLoop, params.owner, strategyId, params.salt);
        address vaultAddress = vaultFactory.createVaultV2(address(this), params.asset, salt);
        UniversalAdapterEscrow sleeve = UniversalAdapterEscrow(
            payable(adapterFactory.deployAdapter(vaultAddress, params.valuer, params.useOffchainValuer, salt))
        );

        PTLoopController controller = new PTLoopController(
            params.owner,
            _finalVaultManager(params.owner, params.vaultManager),
            vaultAddress,
            address(sleeve),
            params.market,
            params.ptToken,
            strategyId,
            params.targetReserveBps,
            params.venueConfig,
            params.automationConfig,
            params.maxUnwindSlippageBps
        );

        address wrapper;
        address depositGate;
        if (params.enableTimelock) {
            wrapper = address(new VaultTimeLockWrapper(vaultAddress));
            depositGate = address(new WrapperOnlySendAssetsGate(wrapper));
        }

        _configurePTLoopWhitelist(sleeve, params.asset, params.ptToken, params.venueConfig.venue);
        _configureVault(
            IVaultV2(vaultAddress),
            sleeve,
            address(controller),
            wrapper,
            depositGate,
            params.owner,
            _finalCurator(params.owner, params.curator),
            params.name,
            params.symbol,
            params.strategyIdData,
            strategyId,
            params.absoluteCap,
            params.relativeCap,
            address(sleeve),
            controller.liquidityData(),
            params.enableTimelock
        );

        deployment = Deployment({
            vault: vaultAddress,
            sleeve: address(sleeve),
            controller: address(controller),
            wrapper: wrapper,
            strategyId: strategyId
        });
        timeLockWrapperOf[vaultAddress] = wrapper;
        depositGateOf[vaultAddress] = depositGate;

        emit StrategyVaultDeployed(
            StrategyKind.PTLoop,
            params.owner,
            vaultAddress,
            address(controller),
            address(sleeve),
            wrapper,
            strategyId,
            salt
        );
    }

    function _configureVault(
        IVaultV2 vault,
        UniversalAdapterEscrow sleeve,
        address controller,
        address wrapper,
        address depositGate,
        address finalOwner,
        address finalCurator,
        string memory name,
        string memory symbol,
        bytes memory strategyIdData,
        bytes32 strategyId,
        uint256 absoluteCap,
        uint256 relativeCap,
        address liquidityAdapter,
        bytes memory liquidityData,
        bool enableTimelock
    ) internal {
        vault.setCurator(address(this));

        vault.submit(abi.encodeCall(IVaultV2.addAdapter, (address(sleeve))));
        vault.addAdapter(address(sleeve));

        vault.submit(abi.encodeCall(IVaultV2.setIsAllocator, (controller, true)));
        vault.setIsAllocator(controller, true);

        if (liquidityAdapter != address(0)) {
            vault.submit(abi.encodeCall(IVaultV2.setIsAllocator, (address(this), true)));
            vault.setIsAllocator(address(this), true);
            vault.setLiquidityAdapterAndData(liquidityAdapter, liquidityData);
            vault.submit(abi.encodeCall(IVaultV2.setIsAllocator, (address(this), false)));
            vault.setIsAllocator(address(this), false);
        }

        vault.submit(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (strategyIdData, absoluteCap)));
        vault.increaseAbsoluteCap(strategyIdData, absoluteCap);

        vault.submit(abi.encodeCall(IVaultV2.increaseRelativeCap, (strategyIdData, relativeCap)));
        vault.increaseRelativeCap(strategyIdData, relativeCap);

        if (depositGate != address(0)) {
            vault.submit(abi.encodeCall(IVaultV2.setSendAssetsGate, (depositGate)));
            vault.setSendAssetsGate(depositGate);
        }
        if (enableTimelock) {
            vault.submit(
                abi.encodeCall(
                    IVaultV2.setForceDeallocatePenalty, (address(sleeve), DEFAULT_TIMELOCK_FORCE_DEALLOCATE_PENALTY)
                )
            );
            vault.setForceDeallocatePenalty(address(sleeve), DEFAULT_TIMELOCK_FORCE_DEALLOCATE_PENALTY);
        }

        if (bytes(name).length != 0) vault.setName(name);
        if (bytes(symbol).length != 0) vault.setSymbol(symbol);

        sleeve.setStrategy(strategyId, controller, "", 0);
        if (wrapper != address(0)) {
            require(VaultTimeLockWrapper(wrapper).vault() == vault, "wrapper mismatch");
        }
        sleeve.transferOwnership(finalOwner);

        vault.setCurator(finalCurator);
        vault.setOwner(finalOwner);
    }

    function _deployAsyncWithdrawalQueue(
        address vault,
        address sleeve,
        address controller,
        address finalOwner,
        bool deployQueue
    ) internal returns (address queue) {
        if (!deployQueue) return address(0);

        AsyncWithdrawalQueue asyncQueue = new AsyncWithdrawalQueue(vault, controller, sleeve, address(this));
        asyncQueue.transferOwnership(finalOwner);

        emit AsyncWithdrawalQueueDeployed(vault, address(asyncQueue));
        return address(asyncQueue);
    }

    function _validateCommon(
        address owner,
        address asset,
        address valuer,
        bool valuerRequired,
        bytes calldata strategyIdData,
        uint256 absoluteCap,
        uint256 relativeCap
    ) internal pure {
        if (owner == address(0) || asset == address(0) || (valuerRequired && valuer == address(0))) {
            revert InvalidAddress();
        }
        if (strategyIdData.length == 0 || absoluteCap == 0 || relativeCap == 0) revert InvalidConfig();
    }

    function _finalVaultManager(address owner, address vaultManager) internal pure returns (address) {
        return vaultManager == address(0) ? owner : vaultManager;
    }

    function _deriveSalt(StrategyKind kind, address owner, bytes32 strategyId, bytes32 userSalt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(kind, owner, strategyId, userSalt));
    }

    function _finalCurator(address owner, address curator) internal pure returns (address) {
        return curator == address(0) ? owner : curator;
    }

    function _configureDeltaNeutralWhitelist(UniversalAdapterEscrow sleeve, address venue) internal {
        sleeve.updateWhitelist(venue, CoreWriter.sendRawAction.selector, true, type(uint256).max);
    }

    function _configurePTLoopWhitelist(UniversalAdapterEscrow sleeve, address asset, address ptToken, address venue)
        internal
    {
        sleeve.updateWhitelist(asset, bytes4(keccak256("approve(address,uint256)")), true, type(uint256).max);
        sleeve.updateWhitelist(ptToken, bytes4(keccak256("approve(address,uint256)")), true, type(uint256).max);
        sleeve.updateWhitelist(venue, IPendleRouter.swapExactTokenForPt.selector, true, type(uint256).max);
        sleeve.updateWhitelist(venue, IPendleRouter.swapExactPtForToken.selector, true, type(uint256).max);
    }
}
