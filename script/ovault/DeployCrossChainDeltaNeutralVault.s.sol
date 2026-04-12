// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {StrategyVaultFactory} from "../../src/factories/StrategyVaultFactory.sol";
import {
    DeltaNeutralAutomationConfig,
    DeltaNeutralKellyConfig,
    DeltaNeutralDeploymentParams,
    Deployment,
    SpotSideMode
} from "../../src/strategies/StrategyTypes.sol";
import {StrategyLaunchpadScriptBase} from "./StrategyLaunchpadScriptBase.s.sol";

contract DeployCrossChainDeltaNeutralVault is StrategyLaunchpadScriptBase {
    function run() external {
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
            automationConfig: _loadAutomationConfig(),
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

        console2.log("Delta-neutral cross-chain vault deployed");
        _logDeployment(factory, deployment);
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

    function _loadAutomationConfig() internal view returns (DeltaNeutralAutomationConfig memory) {
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
}
