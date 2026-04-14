// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
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
    VenueConfig,
    SpotSideMode,
    DeltaNeutralKellyConfig,
    DeltaNeutralAutomationConfig,
    PTLoopAutomationConfig,
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
    address public immutable deltaNeutralControllerImplementation;
    address public immutable ptLoopControllerImplementation;
    address public immutable vaultTimeLockWrapperImplementation;
    address public immutable wrapperOnlySendAssetsGateImplementation;
    address public immutable asyncWithdrawalQueueImplementation;
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
        deltaNeutralControllerImplementation = address(
            new DeltaNeutralController(
                address(0),
                address(0),
                address(0),
                address(0),
                bytes32(0),
                0,
                VenueConfig({venueId: bytes32(0), venue: address(0), helper: address(0)}),
                SpotSideMode.Hold,
                0,
                DeltaNeutralKellyConfig({
                    spotYieldWad: 0,
                    marginYieldWad: 0,
                    baseFundingRateWad: 0,
                    ethVolatilityWad: 0,
                    liquidationLossWad: 0,
                    rebalanceThresholdWad: 0,
                    minBenefitWad: 0,
                    shortTakerFeeWad: 0,
                    entrySlippageWad: 0,
                    exitSlippageWad: 0,
                    shortSlippageWad: 0,
                    bridgeSlippageWad: 0,
                    sizeImpactThresholdAssets: 0,
                    sizeImpactMultiplierWad: 0,
                    bridgeFeeAssets: 0,
                    gasSpotActionAssets: 0,
                    gasShortActionAssets: 0,
                    timeHorizonDays: 0,
                    fundingDivisor: 0,
                    asymmetricRebalanceThresholdBps: 0
                }),
                DeltaNeutralAutomationConfig({
                    spotAssetIndex: 0,
                    perpAssetIndex: 0,
                    spotPriceIndex: 0,
                    perpDexIndex: 0,
                    spotToken: 0,
                    spotTokenDecimals: 0,
                    encodedTif: 0,
                    hyperCoreVault: address(0),
                    maxOrderSlippageBps: 0,
                    maxOracleDivergenceBps: 0,
                    maxMarginUsageBps: 0
                })
            )
        );
        ptLoopControllerImplementation = address(
            new PTLoopController(
                address(0),
                address(0),
                address(0),
                address(0),
                address(0),
                address(0),
                bytes32(0),
                0,
                VenueConfig({venueId: bytes32(0), venue: address(0), helper: address(0)}),
                PTLoopAutomationConfig({maxEntrySlippageBps: 0}),
                0
            )
        );
        vaultTimeLockWrapperImplementation = address(new VaultTimeLockWrapper(address(0)));
        wrapperOnlySendAssetsGateImplementation = address(new WrapperOnlySendAssetsGate(address(0)));
        asyncWithdrawalQueueImplementation =
            address(new AsyncWithdrawalQueue(address(0), address(0), address(0), address(0)));
    }

    function createDeltaNeutralVault(DeltaNeutralDeploymentParams calldata params)
        external
        nonReentrant
        returns (Deployment memory deployment)
    {
        _validateCommon(
            params.owner,
            params.asset,
            params.strategyIdData,
            params.absoluteCap,
            params.relativeCap
        );

        bytes32 strategyId = keccak256(params.strategyIdData);
        bytes32 salt = _deriveSalt(StrategyKind.DeltaNeutral, params.owner, strategyId, params.salt);
        address vaultAddress = vaultFactory.createVaultV2(address(this), params.asset, salt);
        UniversalAdapterEscrow sleeve = UniversalAdapterEscrow(payable(adapterFactory.deployAdapter(vaultAddress, salt)));

        DeltaNeutralController controller = DeltaNeutralController(Clones.clone(deltaNeutralControllerImplementation));
        controller.initialize(
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
            wrapper = Clones.clone(vaultTimeLockWrapperImplementation);
            VaultTimeLockWrapper(wrapper).initialize(vaultAddress);
            depositGate = Clones.clone(wrapperOnlySendAssetsGateImplementation);
            WrapperOnlySendAssetsGate(depositGate).initialize(wrapper);
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
            params.strategyIdData,
            params.absoluteCap,
            params.relativeCap
        );

        bytes32 strategyId = keccak256(params.strategyIdData);
        bytes32 salt = _deriveSalt(StrategyKind.PTLoop, params.owner, strategyId, params.salt);
        address vaultAddress = vaultFactory.createVaultV2(address(this), params.asset, salt);
        UniversalAdapterEscrow sleeve = UniversalAdapterEscrow(payable(adapterFactory.deployAdapter(vaultAddress, salt)));

        PTLoopController controller = PTLoopController(Clones.clone(ptLoopControllerImplementation));
        controller.initialize(
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
            wrapper = Clones.clone(vaultTimeLockWrapperImplementation);
            VaultTimeLockWrapper(wrapper).initialize(vaultAddress);
            depositGate = Clones.clone(wrapperOnlySendAssetsGateImplementation);
            WrapperOnlySendAssetsGate(depositGate).initialize(wrapper);
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

        AsyncWithdrawalQueue asyncQueue = AsyncWithdrawalQueue(Clones.clone(asyncWithdrawalQueueImplementation));
        asyncQueue.initialize(vault, controller, sleeve, address(this));
        asyncQueue.transferOwnership(finalOwner);

        emit AsyncWithdrawalQueueDeployed(vault, address(asyncQueue));
        return address(asyncQueue);
    }

    function _validateCommon(
        address owner,
        address asset,
        bytes calldata strategyIdData,
        uint256 absoluteCap,
        uint256 relativeCap
    ) internal pure {
        if (owner == address(0) || asset == address(0)) {
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
