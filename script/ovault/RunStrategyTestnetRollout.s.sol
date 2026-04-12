// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {AssetOFT} from "../../src/ovault/AssetOFT.sol";
import {ShareOFT} from "../../src/ovault/ShareOFT.sol";
import {StrategyVaultFactory} from "../../src/factories/StrategyVaultFactory.sol";
import {
    DeltaNeutralAutomationConfig,
    DeltaNeutralKellyConfig,
    DeltaNeutralDeploymentParams,
    Deployment,
    PTLoopAutomationConfig,
    PTLoopDeploymentParams,
    SpotSideMode,
    StrategyKind
} from "../../src/strategies/StrategyTypes.sol";
import {StrategyLaunchpadScriptBase} from "./StrategyLaunchpadScriptBase.s.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {
    EnforcedOptionParam,
    IOAppOptionsType3
} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import {ExecutorOptions} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/libs/ExecutorOptions.sol";

contract RunStrategyTestnetRollout is StrategyLaunchpadScriptBase {
    uint256 internal constant ACTION_DEPLOY_STRATEGY = 0;
    uint256 internal constant ACTION_DEPLOY_SPOKE_OFT = 1;
    uint256 internal constant ACTION_CONFIGURE_OMNICHAIN = 2;

    uint16 internal constant SEND = 1;
    uint16 internal constant SEND_AND_CALL = 2;
    uint16 internal constant TYPE_3 = 3;

    error InvalidRolloutAction();
    error InvalidStrategyKind();
    error InvalidPeerConfig();

    function run() external {
        uint256 action = vm.envUint("ROLLOUT_ACTION");

        if (action == ACTION_DEPLOY_STRATEGY) {
            _deployStrategy();
            return;
        }

        if (action == ACTION_DEPLOY_SPOKE_OFT) {
            _deploySpokeOFT();
            return;
        }

        if (action == ACTION_CONFIGURE_OMNICHAIN) {
            _configureOmnichain();
            return;
        }

        revert InvalidRolloutAction();
    }

    function _deployStrategy() internal {
        uint256 strategyKind = vm.envUint("STRATEGY_KIND");

        if (strategyKind == uint256(StrategyKind.DeltaNeutral)) {
            _deployDeltaNeutral();
            return;
        }

        if (strategyKind == uint256(StrategyKind.PTLoop)) {
            _deployPTLoop();
            return;
        }

        revert InvalidStrategyKind();
    }

    function _deployDeltaNeutral() internal {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("OWNER");
        StrategyVaultFactory factory = StrategyVaultFactory(vm.envAddress("STRATEGY_FACTORY"));

        DeltaNeutralDeploymentParams memory params = DeltaNeutralDeploymentParams({
            owner: owner,
            curator: vm.envOr("CURATOR", owner),
            enableTimelock: vm.envOr("ENABLE_TIMELOCK", false),
            enableOmnichainVault: vm.envOr("ENABLE_OMNICHAIN_VAULT", false),
            asset: vm.envAddress("ASSET"),
            valuer: vm.envAddress("VALUER"),
            name: vm.envString("NAME"),
            symbol: vm.envString("SYMBOL"),
            strategyIdData: bytes(vm.envString("STRATEGY_ID_DATA")),
            spotSideMode: SpotSideMode(vm.envUint("SPOT_SIDE_MODE")),
            targetReserveBps: vm.envUint("TARGET_RESERVE_BPS"),
            minReserveBps: vm.envUint("MIN_RESERVE_BPS"),
            maxDeltaBps: vm.envUint("MAX_DELTA_BPS"),
            kellyConfig: _loadKellyConfig(),
            automationConfig: _loadDeltaAutomationConfig(),
            absoluteCap: vm.envUint("ABSOLUTE_CAP"),
            relativeCap: vm.envUint("RELATIVE_CAP"),
            salt: vm.envOr("SALT", bytes32(0)),
            useOffchainValuer: vm.envOr("USE_OFFCHAIN_VALUER", false),
            venueConfig: _loadVenueConfig(),
            chainManifests: _loadChainManifests()
        });

        vm.startBroadcast(privateKey);
        Deployment memory deployment = factory.createDeltaNeutralVault(params);
        vm.stopBroadcast();

        console2.log("Rollout action complete: deploy delta-neutral strategy");
        _logDeployment(factory, deployment);
        _logNextPhaseHint();
    }

    function _deployPTLoop() internal {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("OWNER");
        StrategyVaultFactory factory = StrategyVaultFactory(vm.envAddress("STRATEGY_FACTORY"));

        PTLoopDeploymentParams memory params = PTLoopDeploymentParams({
            owner: owner,
            curator: vm.envOr("CURATOR", owner),
            enableTimelock: vm.envOr("ENABLE_TIMELOCK", false),
            enableOmnichainVault: vm.envOr("ENABLE_OMNICHAIN_VAULT", false),
            asset: vm.envAddress("ASSET"),
            market: vm.envAddress("MARKET"),
            ptToken: vm.envAddress("PT_TOKEN"),
            valuer: vm.envAddress("VALUER"),
            name: vm.envString("NAME"),
            symbol: vm.envString("SYMBOL"),
            strategyIdData: bytes(vm.envString("STRATEGY_ID_DATA")),
            targetReserveBps: vm.envUint("TARGET_RESERVE_BPS"),
            minReserveBps: vm.envUint("MIN_RESERVE_BPS"),
            maxUnwindSlippageBps: vm.envUint("MAX_UNWIND_SLIPPAGE_BPS"),
            automationConfig: _loadPTAutomationConfig(),
            absoluteCap: vm.envUint("ABSOLUTE_CAP"),
            relativeCap: vm.envUint("RELATIVE_CAP"),
            salt: vm.envOr("SALT", bytes32(0)),
            useOffchainValuer: vm.envOr("USE_OFFCHAIN_VALUER", false),
            venueConfig: _loadVenueConfig(),
            chainManifests: _loadChainManifests()
        });

        vm.startBroadcast(privateKey);
        Deployment memory deployment = factory.createPTLoopVault(params);
        vm.stopBroadcast();

        console2.log("Rollout action complete: deploy PT-loop strategy");
        _logDeployment(factory, deployment);
        _logNextPhaseHint();
    }

    function _deploySpokeOFT() internal {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address delegate = vm.envOr("DELEGATE", vm.addr(privateKey));
        address endpoint = vm.envAddress("LZ_ENDPOINT");
        bool deployAssetOFT = vm.envOr("DEPLOY_ASSET_OFT", true);

        address assetOFTAddress = vm.envOr("EXISTING_ASSET_OFT", address(0));
        address shareOFTAddress;

        vm.startBroadcast(privateKey);

        if (deployAssetOFT) {
            assetOFTAddress =
                address(new AssetOFT(vm.envString("ASSET_NAME"), vm.envString("ASSET_SYMBOL"), endpoint, delegate));
        }

        shareOFTAddress =
            address(new ShareOFT(vm.envString("SHARE_NAME"), vm.envString("SHARE_SYMBOL"), endpoint, delegate));

        vm.stopBroadcast();

        console2.log("Rollout action complete: deploy spoke OFTs");
        console2.log("AssetOFT:", assetOFTAddress);
        console2.log("ShareOFT:", shareOFTAddress);
        _logNextPhaseHint();
    }

    function _configureOmnichain() internal {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address localAssetOFT = vm.envAddress("LOCAL_ASSET_OFT");
        bool configureShare = vm.envExists("LOCAL_SHARE_OFT");
        address localShareOFT = configureShare ? vm.envAddress("LOCAL_SHARE_OFT") : address(0);
        uint32[] memory remoteEids = _loadUint32Array("REMOTE_EIDS");
        address[] memory remoteAssetOFTs = vm.envAddress("REMOTE_ASSET_OFTS", ",");
        address[] memory remoteShareOFTs = configureShare ? vm.envAddress("REMOTE_SHARE_OFTS", ",") : new address[](0);

        uint256 length = remoteEids.length;
        if (length == 0 || remoteAssetOFTs.length != length) revert InvalidPeerConfig();
        if (configureShare && remoteShareOFTs.length != length) revert InvalidPeerConfig();

        bytes memory sendOptions = _newOptions();
        sendOptions = _addExecutorOption(
            sendOptions,
            ExecutorOptions.OPTION_TYPE_LZRECEIVE,
            ExecutorOptions.encodeLzReceiveOption(
                uint128(vm.envUint("LZ_RECEIVE_GAS")), uint128(vm.envOr("LZ_RECEIVE_VALUE", uint256(0)))
            )
        );

        bytes memory sendAndCallOptions = sendOptions;
        uint256 composeGas = vm.envOr("LZ_COMPOSE_GAS", uint256(0));
        uint256 composeValue = vm.envOr("LZ_COMPOSE_VALUE", uint256(0));
        if (composeGas != 0 || composeValue != 0) {
            sendAndCallOptions = _addExecutorOption(
                sendAndCallOptions,
                ExecutorOptions.OPTION_TYPE_LZCOMPOSE,
                ExecutorOptions.encodeLzComposeOption(0, uint128(composeGas), uint128(composeValue))
            );
        }

        vm.startBroadcast(privateKey);

        _setPeers(localAssetOFT, remoteEids, remoteAssetOFTs);
        _setOptions(localAssetOFT, remoteEids, sendOptions, sendAndCallOptions);

        if (configureShare) {
            _setPeers(localShareOFT, remoteEids, remoteShareOFTs);
            _setOptions(localShareOFT, remoteEids, sendOptions, sendAndCallOptions);
        }

        vm.stopBroadcast();

        console2.log("Rollout action complete: configure omnichain peers/options");
        console2.log("LocalAssetOFT:", localAssetOFT);
        console2.log("LocalShareOFT:", localShareOFT);
        console2.log("ConfiguredRemoteCount:", length);
    }

    function _setPeers(address localOApp, uint32[] memory remoteEids, address[] memory remotes) internal {
        for (uint256 i; i < remoteEids.length; i++) {
            if (remotes[i] == address(0)) revert InvalidPeerConfig();
            IOAppCore(localOApp).setPeer(remoteEids[i], bytes32(uint256(uint160(remotes[i]))));
        }
    }

    function _setOptions(
        address localOApp,
        uint32[] memory remoteEids,
        bytes memory sendOptions,
        bytes memory sendAndCallOptions
    ) internal {
        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](remoteEids.length * 2);
        for (uint256 i; i < remoteEids.length; i++) {
            uint256 baseIndex = i * 2;
            options[baseIndex] = EnforcedOptionParam(remoteEids[i], SEND, sendOptions);
            options[baseIndex + 1] = EnforcedOptionParam(remoteEids[i], SEND_AND_CALL, sendAndCallOptions);
        }
        IOAppOptionsType3(localOApp).setEnforcedOptions(options);
    }

    function _loadKellyConfig() internal view returns (DeltaNeutralKellyConfig memory) {
        return DeltaNeutralKellyConfig({
            spotYieldWad: vm.envUint("KELLY_SPOT_YIELD_WAD"),
            marginYieldWad: vm.envUint("KELLY_MARGIN_YIELD_WAD"),
            baseFundingRateWad: vm.envUint("KELLY_BASE_FUNDING_RATE_WAD"),
            ethVolatilityWad: vm.envUint("KELLY_ETH_VOLATILITY_WAD"),
            liquidationLossWad: vm.envUint("KELLY_LIQUIDATION_LOSS_WAD"),
            rebalanceThresholdWad: vm.envUint("KELLY_REBALANCE_THRESHOLD_WAD"),
            minBenefitWad: vm.envUint("KELLY_MIN_BENEFIT_WAD"),
            shortTakerFeeWad: vm.envUint("KELLY_SHORT_TAKER_FEE_WAD"),
            entrySlippageWad: vm.envUint("KELLY_ENTRY_SLIPPAGE_WAD"),
            exitSlippageWad: vm.envUint("KELLY_EXIT_SLIPPAGE_WAD"),
            shortSlippageWad: vm.envUint("KELLY_SHORT_SLIPPAGE_WAD"),
            bridgeSlippageWad: vm.envUint("KELLY_BRIDGE_SLIPPAGE_WAD"),
            sizeImpactThresholdAssets: vm.envUint("KELLY_SIZE_IMPACT_THRESHOLD_ASSETS"),
            sizeImpactMultiplierWad: vm.envUint("KELLY_SIZE_IMPACT_MULTIPLIER_WAD"),
            bridgeFeeAssets: vm.envUint("KELLY_BRIDGE_FEE_ASSETS"),
            gasSpotActionAssets: vm.envUint("KELLY_GAS_SPOT_ACTION_ASSETS"),
            gasShortActionAssets: vm.envUint("KELLY_GAS_SHORT_ACTION_ASSETS"),
            timeHorizonDays: uint32(vm.envUint("KELLY_TIME_HORIZON_DAYS")),
            fundingDivisor: uint16(vm.envUint("KELLY_FUNDING_DIVISOR")),
            asymmetricRebalanceThresholdBps: uint16(vm.envUint("KELLY_ASYMMETRIC_REBALANCE_THRESHOLD_BPS"))
        });
    }

    function _loadDeltaAutomationConfig() internal view returns (DeltaNeutralAutomationConfig memory) {
        return DeltaNeutralAutomationConfig({
            spotAssetIndex: uint32(vm.envUint("AUTOMATION_SPOT_ASSET_INDEX")),
            perpAssetIndex: uint32(vm.envUint("AUTOMATION_PERP_ASSET_INDEX")),
            spotPriceIndex: uint32(vm.envUint("AUTOMATION_SPOT_PRICE_INDEX")),
            perpDexIndex: uint32(vm.envUint("AUTOMATION_PERP_DEX_INDEX")),
            spotToken: uint64(vm.envUint("AUTOMATION_SPOT_TOKEN")),
            spotTokenDecimals: uint8(vm.envUint("AUTOMATION_SPOT_TOKEN_DECIMALS")),
            encodedTif: uint8(vm.envUint("AUTOMATION_ENCODED_TIF")),
            hyperCoreVault: vm.envAddress("AUTOMATION_HYPER_CORE_VAULT"),
            maxOrderSlippageBps: uint16(vm.envUint("AUTOMATION_MAX_ORDER_SLIPPAGE_BPS")),
            maxOracleDivergenceBps: uint16(vm.envUint("AUTOMATION_MAX_ORACLE_DIVERGENCE_BPS")),
            maxMarginUsageBps: uint16(vm.envUint("AUTOMATION_MAX_MARGIN_USAGE_BPS"))
        });
    }

    function _loadPTAutomationConfig() internal view returns (PTLoopAutomationConfig memory) {
        return PTLoopAutomationConfig({maxEntrySlippageBps: uint16(vm.envUint("AUTOMATION_MAX_ENTRY_SLIPPAGE_BPS"))});
    }

    function _loadUint32Array(string memory key) internal view returns (uint32[] memory values) {
        uint256[] memory rawValues = vm.envUint(key, ",");
        values = new uint32[](rawValues.length);
        for (uint256 i; i < rawValues.length; i++) {
            values[i] = uint32(rawValues[i]);
        }
    }

    function _newOptions() internal pure returns (bytes memory) {
        return abi.encodePacked(TYPE_3);
    }

    function _addExecutorOption(bytes memory options, uint8 optionType, bytes memory option)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(options, ExecutorOptions.WORKER_ID, uint16(option.length + 1), optionType, option);
    }

    function _logNextPhaseHint() internal pure {
        console2.log("Next rollout step suggestion:");
        console2.log(
            "Set ROLLOUT_ACTION to 1 for spoke OFT deployment or 2 for peer/options wiring on the active chain."
        );
    }
}
