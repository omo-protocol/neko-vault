// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {StrategyVaultFactory} from "../../src/factories/StrategyVaultFactory.sol";
import {
    DeltaNeutralAutomationConfig,
    DeltaNeutralKellyConfig,
    DeltaNeutralDeploymentParams,
    Deployment,
    PTLoopAutomationConfig,
    PTLoopDeploymentParams,
    SpotSideMode,
    VenueConfig
} from "../../src/strategies/StrategyTypes.sol";

abstract contract StrategyLaunchpadScriptBase is Script {
    function _loadVenueConfig() internal view returns (VenueConfig memory) {
        return VenueConfig({
            venueId: vm.envBytes32("VENUE_ID"),
            venue: vm.envAddress("VENUE"),
            helper: vm.envOr("VENUE_HELPER", address(0))
        });
    }

    function _deployDeltaNeutralStrategy()
        internal
        returns (StrategyVaultFactory factory, Deployment memory deployment)
    {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("OWNER");
        factory = StrategyVaultFactory(vm.envAddress("STRATEGY_FACTORY"));

        DeltaNeutralDeploymentParams memory params = DeltaNeutralDeploymentParams({
            owner: owner,
            vaultManager: vm.envOr("VAULT_MANAGER", owner),
            curator: vm.envOr("CURATOR", owner),
            enableTimelock: vm.envOr("ENABLE_TIMELOCK", false),
            asset: vm.envAddress("ASSET"),
            valuer: vm.envOr("VALUER", address(0)),
            name: vm.envString("NAME"),
            symbol: vm.envString("SYMBOL"),
            strategyIdData: bytes(vm.envString("STRATEGY_ID_DATA")),
            spotSideMode: SpotSideMode(vm.envUint("SPOT_SIDE_MODE")),
            targetReserveBps: vm.envUint("TARGET_RESERVE_BPS"),
            maxDeltaBps: vm.envUint("MAX_DELTA_BPS"),
            kellyConfig: _loadKellyConfig(),
            automationConfig: _loadDeltaAutomationConfig(),
            absoluteCap: vm.envUint("ABSOLUTE_CAP"),
            relativeCap: vm.envUint("RELATIVE_CAP"),
            salt: vm.envOr("SALT", bytes32(0)),
            useOffchainValuer: vm.envOr("USE_OFFCHAIN_VALUER", false),
            venueConfig: _loadVenueConfig()
        });

        vm.startBroadcast(privateKey);
        deployment = factory.createDeltaNeutralVault(params);
        vm.stopBroadcast();
    }

    function _deployPTLoopStrategy() internal returns (StrategyVaultFactory factory, Deployment memory deployment) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("OWNER");
        factory = StrategyVaultFactory(vm.envAddress("STRATEGY_FACTORY"));

        PTLoopDeploymentParams memory params = PTLoopDeploymentParams({
            owner: owner,
            vaultManager: vm.envOr("VAULT_MANAGER", owner),
            curator: vm.envOr("CURATOR", owner),
            enableTimelock: vm.envOr("ENABLE_TIMELOCK", false),
            asset: vm.envAddress("ASSET"),
            market: vm.envAddress("MARKET"),
            ptToken: vm.envAddress("PT_TOKEN"),
            valuer: vm.envOr("VALUER", address(0)),
            name: vm.envString("NAME"),
            symbol: vm.envString("SYMBOL"),
            strategyIdData: bytes(vm.envString("STRATEGY_ID_DATA")),
            targetReserveBps: vm.envUint("TARGET_RESERVE_BPS"),
            maxUnwindSlippageBps: vm.envUint("MAX_UNWIND_SLIPPAGE_BPS"),
            automationConfig: _loadPTAutomationConfig(),
            absoluteCap: vm.envUint("ABSOLUTE_CAP"),
            relativeCap: vm.envUint("RELATIVE_CAP"),
            salt: vm.envOr("SALT", bytes32(0)),
            useOffchainValuer: vm.envOr("USE_OFFCHAIN_VALUER", false),
            venueConfig: _loadVenueConfig()
        });

        vm.startBroadcast(privateKey);
        deployment = factory.createPTLoopVault(params);
        vm.stopBroadcast();
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
        return PTLoopAutomationConfig({
            maxEntrySlippageBps: uint16(vm.envUint("AUTOMATION_MAX_ENTRY_SLIPPAGE_BPS"))
        });
    }
}
