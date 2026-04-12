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
import {AsyncWithdrawalSettlementComposer} from "../ovault/AsyncWithdrawalSettlementComposer.sol";
import {ShareOFTAdapter} from "../ovault/ShareOFTAdapter.sol";
import {VaultComposerSync} from "../ovault/VaultComposerSync.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {
    StrategyKind,
    Deployment,
    ChainManifest,
    DeltaNeutralDeploymentParams,
    PTLoopDeploymentParams
} from "../strategies/StrategyTypes.sol";
import {VaultTimeLockWrapper} from "../VaultTimeLockWrapper.sol";

contract StrategyVaultFactory is ReentrancyGuard {
    error InvalidAddress();
    error InvalidConfig();
    error InvalidChainManifest();

    IVaultV2Factory public immutable vaultFactory;
    UniversalAdapterEscrowFactory public immutable adapterFactory;
    mapping(address vault => address wrapper) public timeLockWrapperOf;
    mapping(address vault => address gate) public depositGateOf;
    mapping(address vault => address queue) public withdrawalQueueOf;
    mapping(address vault => address composer) public withdrawalSettlementComposerOf;
    mapping(address vault => address shareAdapter) public shareOFTAdapterOf;
    mapping(address vault => address composer) public vaultComposerSyncOf;

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
    event AsyncWithdrawalQueueDeployed(address indexed vault, address indexed queue, address indexed composer);
    event OmnichainVaultInfrastructureDeployed(
        address indexed vault, address indexed assetOFT, address indexed shareAdapter, address vaultComposer
    );

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
            params.owner, params.asset, params.valuer, params.strategyIdData, params.absoluteCap, params.relativeCap
        );
        _validateChainManifests(params.venueConfig.usesLayerZero, params.enableOmnichainVault, params.chainManifests);

        bytes32 strategyId = keccak256(params.strategyIdData);
        bytes32 salt = _deriveSalt(StrategyKind.DeltaNeutral, params.owner, strategyId, params.salt);
        address vaultAddress = vaultFactory.createVaultV2(address(this), params.asset, salt);
        UniversalAdapterEscrow sleeve = UniversalAdapterEscrow(
            payable(adapterFactory.deployAdapter(vaultAddress, params.valuer, params.useOffchainValuer, salt))
        );

        DeltaNeutralController controller = new DeltaNeutralController(
            params.owner,
            vaultAddress,
            address(sleeve),
            params.valuer,
            strategyId,
            params.targetReserveBps,
            params.minReserveBps,
            params.venueConfig,
            _materializeManifests(params.chainManifests, address(sleeve)),
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
        (address shareAdapter, address vaultComposer) = _deployOmnichainVaultInfrastructure(
            vaultAddress, params.owner, params.enableOmnichainVault, params.chainManifests
        );

        _configureDeltaNeutralWhitelist(sleeve, params.venueConfig.venue);
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
            controller.liquidityData()
        );
        (address queue, address composer) = _deployAsyncWithdrawalQueue(
            vaultAddress,
            address(sleeve),
            address(controller),
            params.owner,
            true,
            params.venueConfig.usesLayerZero,
            params.chainManifests
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
        withdrawalSettlementComposerOf[vaultAddress] = composer;
        shareOFTAdapterOf[vaultAddress] = shareAdapter;
        vaultComposerSyncOf[vaultAddress] = vaultComposer;

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
            params.owner, params.asset, params.valuer, params.strategyIdData, params.absoluteCap, params.relativeCap
        );
        _validateChainManifests(params.venueConfig.usesLayerZero, params.enableOmnichainVault, params.chainManifests);

        bytes32 strategyId = keccak256(params.strategyIdData);
        bytes32 salt = _deriveSalt(StrategyKind.PTLoop, params.owner, strategyId, params.salt);
        address vaultAddress = vaultFactory.createVaultV2(address(this), params.asset, salt);
        UniversalAdapterEscrow sleeve = UniversalAdapterEscrow(
            payable(adapterFactory.deployAdapter(vaultAddress, params.valuer, params.useOffchainValuer, salt))
        );

        PTLoopController controller = new PTLoopController(
            params.owner,
            vaultAddress,
            address(sleeve),
            params.valuer,
            params.market,
            params.ptToken,
            strategyId,
            params.targetReserveBps,
            params.minReserveBps,
            params.venueConfig,
            _materializeManifests(params.chainManifests, address(sleeve)),
            params.automationConfig,
            params.maxUnwindSlippageBps
        );
        address wrapper;
        address depositGate;
        if (params.enableTimelock) {
            wrapper = address(new VaultTimeLockWrapper(vaultAddress));
            depositGate = address(new WrapperOnlySendAssetsGate(wrapper));
        }
        (address shareAdapter, address vaultComposer) = _deployOmnichainVaultInfrastructure(
            vaultAddress, params.owner, params.enableOmnichainVault, params.chainManifests
        );

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
            controller.liquidityData()
        );
        (address queue, address composer) = _deployAsyncWithdrawalQueue(
            vaultAddress,
            address(sleeve),
            address(controller),
            params.owner,
            params.venueConfig.usesLayerZero,
            params.venueConfig.usesLayerZero,
            params.chainManifests
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
        withdrawalSettlementComposerOf[vaultAddress] = composer;
        shareOFTAdapterOf[vaultAddress] = shareAdapter;
        vaultComposerSyncOf[vaultAddress] = vaultComposer;

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
        bytes memory liquidityData
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
        bool deployQueue,
        bool usesLayerZero,
        ChainManifest[] calldata manifests
    ) internal returns (address queue, address composer) {
        if (!deployQueue) return (address(0), address(0));

        AsyncWithdrawalQueue asyncQueue = new AsyncWithdrawalQueue(vault, controller, sleeve, address(this));
        AsyncWithdrawalSettlementComposer settlementComposer;
        if (usesLayerZero) {
            address homeAssetOFT = _homeAssetOFT(manifests);
            if (homeAssetOFT == address(0)) revert InvalidConfig();

            settlementComposer = new AsyncWithdrawalSettlementComposer(address(asyncQueue), sleeve, homeAssetOFT);
            asyncQueue.setSettlementHook(address(settlementComposer));
        }
        asyncQueue.transferOwnership(finalOwner);

        emit AsyncWithdrawalQueueDeployed(vault, address(asyncQueue), address(settlementComposer));
        return (address(asyncQueue), address(settlementComposer));
    }

    function _deployOmnichainVaultInfrastructure(
        address vault,
        address finalOwner,
        bool enableOmnichainVault,
        ChainManifest[] calldata manifests
    ) internal returns (address shareAdapter, address composer) {
        if (!enableOmnichainVault) return (address(0), address(0));

        address homeAssetOFT = _homeAssetOFT(manifests);
        if (homeAssetOFT == address(0)) revert InvalidConfig();

        shareAdapter = address(new ShareOFTAdapter(vault, address(IOAppCore(homeAssetOFT).endpoint()), finalOwner));
        composer = address(new VaultComposerSync(vault, homeAssetOFT, shareAdapter));

        emit OmnichainVaultInfrastructureDeployed(vault, homeAssetOFT, shareAdapter, composer);
    }

    function _materializeManifests(ChainManifest[] calldata manifests, address homeSleeve)
        internal
        view
        returns (ChainManifest[] memory materialized)
    {
        if (manifests.length == 0) {
            materialized = new ChainManifest[](1);
            materialized[0] = ChainManifest({
                chainId: block.chainid,
                lzEid: 0,
                sleeve: homeSleeve,
                assetOFT: address(0),
                shareOFT: address(0),
                isHomeChain: true
            });
            return materialized;
        }

        materialized = new ChainManifest[](manifests.length);
        for (uint256 i; i < manifests.length; i++) {
            materialized[i] = manifests[i];
            if (materialized[i].isHomeChain) {
                materialized[i].sleeve = homeSleeve;
            }
        }
    }

    function _validateCommon(
        address owner,
        address asset,
        address valuer,
        bytes calldata strategyIdData,
        uint256 absoluteCap,
        uint256 relativeCap
    ) internal pure {
        if (owner == address(0) || asset == address(0) || valuer == address(0)) revert InvalidAddress();
        if (strategyIdData.length == 0 || absoluteCap == 0 || relativeCap == 0) revert InvalidConfig();
    }

    function _validateChainManifests(bool usesLayerZero, bool enableOmnichainVault, ChainManifest[] calldata manifests)
        internal
        pure
    {
        if (manifests.length == 0) {
            if (usesLayerZero || enableOmnichainVault) revert InvalidChainManifest();
            return;
        }

        bool seenHomeChain;
        bool seenRemoteChain;
        for (uint256 i; i < manifests.length; i++) {
            ChainManifest calldata manifest = manifests[i];

            if (manifest.isHomeChain) {
                if (seenHomeChain) revert InvalidChainManifest();
                seenHomeChain = true;
                if ((usesLayerZero || enableOmnichainVault) && manifest.assetOFT == address(0)) {
                    revert InvalidChainManifest();
                }
                continue;
            }

            if (manifest.sleeve == address(0) || manifest.lzEid == 0) revert InvalidChainManifest();
            if ((usesLayerZero || enableOmnichainVault) && manifest.assetOFT == address(0)) {
                revert InvalidChainManifest();
            }
            if (enableOmnichainVault && manifest.shareOFT == address(0)) revert InvalidChainManifest();
            seenRemoteChain = true;
        }

        if (!seenHomeChain) revert InvalidChainManifest();
        if (usesLayerZero && !seenRemoteChain) revert InvalidChainManifest();
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

    function _homeAssetOFT(ChainManifest[] calldata manifests) internal pure returns (address) {
        if (manifests.length == 0) return address(0);

        for (uint256 i; i < manifests.length; i++) {
            if (manifests[i].isHomeChain) return manifests[i].assetOFT;
        }
        return address(0);
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
