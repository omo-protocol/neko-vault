// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IUniversalAdapterEscrow} from "../adapters/interfaces/IUniversalAdapterEscrow.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {ControllerLiquidityLib} from "./libraries/ControllerLiquidityLib.sol";
import {L1Read} from "./venue_specific/hyperliquid/L1Read.sol";
import {HyperliquidLib, HyperliquidOrderRequest, HyperliquidUnwindSizing} from "./venue_specific/hyperliquid/HyperliquidLib.sol";
import {
    KellyLinearState,
    DeltaNeutralUnwindPlan,
    VenueConfig,
    SpotSideMode,
    DeltaNeutralKellyConfig,
    DeltaNeutralAutomationConfig
} from "../strategies/StrategyTypes.sol";
import {DeltaNeutralControllerBase} from "./DeltaNeutralControllerBase.sol";

contract DeltaNeutralController is DeltaNeutralControllerBase {
    constructor(
        address owner_,
        address vaultManager_,
        address vault_,
        address sleeve_,
        bytes32 strategyId_,
        uint256 targetReserveBps_,
        VenueConfig memory venueConfig_,
        SpotSideMode spotSideMode_,
        uint256 maxDeltaBps_,
        DeltaNeutralKellyConfig memory kellyConfig_,
        DeltaNeutralAutomationConfig memory automationConfig_
    )
        DeltaNeutralControllerBase(
            owner_,
            vaultManager_,
            vault_,
            sleeve_,
            strategyId_,
            targetReserveBps_,
            venueConfig_,
            spotSideMode_,
            maxDeltaBps_,
            kellyConfig_,
            automationConfig_
        )
    {}

    function _quoteUnwindExecution(
        uint256 idleAssets,
        uint256 requestedAssets,
        uint256 spotAssets,
        uint256 hedgeCollateralAssets
    ) internal view override returns (HyperliquidUnwindSizing memory sizing) {
        DeltaNeutralUnwindPlan memory plan = _planWithdrawal(idleAssets, requestedAssets, spotAssets, hedgeCollateralAssets);

        uint64 liveSpotPx = L1Read(helper).spotPx(spotPriceIndex);
        uint64 liveMarkPx = L1Read(helper).markPx(perpAssetIndex);
        uint256 perpBaseUnits = 10 ** L1Read(helper).perpAssetInfo(perpAssetIndex).szDecimals;
        uint256 spotBaseUnits = 10 ** spotTokenDecimals;

        sizing = HyperliquidUnwindSizing({
            requestedAssets: requestedAssets,
            shortfallAssets: plan.shortfallAssets,
            spotReductionAssets: plan.spotReductionAssets,
            hedgeReductionAssets: plan.hedgeReductionAssets,
            spotPx: liveSpotPx,
            markPx: liveMarkPx,
            spotSizeToSell: uint64(_mulDivUp(plan.spotReductionAssets, spotBaseUnits, liveSpotPx)),
            perpSizeToClose: uint64(_mulDivUp(plan.hedgeReductionAssets, perpBaseUnits, liveMarkPx)),
            requiresEmergencyExit: plan.requiresEmergencyExit
        });
    }

    function getKellyConfig() external view returns (DeltaNeutralKellyConfig memory) {
        return DeltaNeutralKellyConfig({
            spotYieldWad: kellySpotYieldWad,
            marginYieldWad: kellyMarginYieldWad,
            baseFundingRateWad: kellyBaseFundingRateWad,
            ethVolatilityWad: kellyEthVolatilityWad,
            liquidationLossWad: kellyLiquidationLossWad,
            rebalanceThresholdWad: kellyRebalanceThresholdWad,
            minBenefitWad: kellyMinBenefitWad,
            shortTakerFeeWad: kellyShortTakerFeeWad,
            entrySlippageWad: kellyEntrySlippageWad,
            exitSlippageWad: kellyExitSlippageWad,
            shortSlippageWad: kellyShortSlippageWad,
            bridgeSlippageWad: kellyBridgeSlippageWad,
            sizeImpactThresholdAssets: kellySizeImpactThresholdAssets,
            sizeImpactMultiplierWad: kellySizeImpactMultiplierWad,
            bridgeFeeAssets: kellyBridgeFeeAssets,
            gasSpotActionAssets: kellyGasSpotActionAssets,
            gasShortActionAssets: kellyGasShortActionAssets,
            timeHorizonDays: kellyTimeHorizonDays,
            fundingDivisor: kellyFundingDivisor,
            asymmetricRebalanceThresholdBps: kellyAsymmetricRebalanceThresholdBps
        });
    }

    function _kellyState() internal view override returns (KellyLinearState memory state) {
        state = KellyLinearState({
            riskyYieldWad: kellySpotYieldWad,
            residualYieldWad: kellyMarginYieldWad,
            carryRateWad: kellyBaseFundingRateWad,
            liquidationLossWad: kellyLiquidationLossWad,
            rebalanceThresholdWad: kellyRebalanceThresholdWad,
            minBenefitWad: kellyMinBenefitWad,
            sizeImpactThresholdAssets: kellySizeImpactThresholdAssets,
            sizeImpactMultiplierWad: kellySizeImpactMultiplierWad,
            fixedRebalanceCostAssets: kellyFixedRebalanceCostAssets,
            timeYearsWad: kellyTimeYearsWad,
            periodVolWad: kellyPeriodVolWad,
            decreaseRiskCostWad: kellySpotToPerpCostWad,
            decreaseRiskCostHighWad: kellySpotToPerpCostHighWad,
            increaseRiskCostWad: kellyPerpToSpotCostWad,
            increaseRiskCostHighWad: kellyPerpToSpotCostHighWad,
            carryDivisor: kellyFundingDivisor,
            asymmetricRebalanceThresholdBps: kellyAsymmetricRebalanceThresholdBps,
            logLiquidationLossWad: kellyLogLiquidationLossWad
        });
    }

    function _liveState() internal view override returns (HyperliquidLiveState memory state) {
        state.oraclePx = L1Read(helper).oraclePx(perpAssetIndex);
        state.markPx = L1Read(helper).markPx(perpAssetIndex);
        state.spotPx = L1Read(helper).spotPx(spotPriceIndex);
        state.idleAssets = IERC20(asset).balanceOf(address(sleeve));
        state.spotBaseUnits = 10 ** spotTokenDecimals;
        state.perpBaseUnits = 10 ** L1Read(helper).perpAssetInfo(perpAssetIndex).szDecimals;

        L1Read.Position memory position = L1Read(helper).position2(address(sleeve), perpAssetIndex);
        if (position.szi < 0) {
            state.shortAssets = uint256(uint64(-position.szi)) * state.markPx / state.perpBaseUnits;
        }

        L1Read.SpotBalance memory spotBalance = L1Read(helper).spotBalance(address(sleeve), spotToken);
        state.spotAssets = uint256(spotBalance.total) * state.spotPx / state.spotBaseUnits;
        state.hedgeCollateralAssets = L1Read(helper).withdrawable(address(sleeve)).withdrawable;
        state.marginSummary = L1Read(helper).accountMarginSummary(perpDexIndex, address(sleeve));
    }

    function _buildTargetCalls(HyperliquidLiveState memory live, uint256 targetSpotAssets, uint256 targetShortAssets)
        internal
        view
        override
        returns (IUniversalAdapterEscrow.Call[] memory calls)
    {
        uint64 spotBuySize = targetSpotAssets > live.spotAssets
            ? uint64(_mulDivUp(targetSpotAssets - live.spotAssets, live.spotBaseUnits, live.spotPx))
            : 0;
        uint64 spotSellSize = live.spotAssets > targetSpotAssets
            ? uint64((live.spotAssets - targetSpotAssets) * live.spotBaseUnits / live.spotPx)
            : 0;
        uint64 shortOpenSize = targetShortAssets > live.shortAssets
            ? uint64(_mulDivUp(targetShortAssets - live.shortAssets, live.perpBaseUnits, live.markPx))
            : 0;
        uint64 shortCloseSize = live.shortAssets > targetShortAssets
            ? uint64(_mulDivUp(live.shortAssets - targetShortAssets, live.perpBaseUnits, live.markPx))
            : 0;

        uint256 count;
        if (spotBuySize > 0) count++;
        if (spotSellSize > 0) count++;
        if (shortOpenSize > 0) count++;
        if (shortCloseSize > 0) count++;
        if (count == 0) return new IUniversalAdapterEscrow.Call[](0);

        calls = new IUniversalAdapterEscrow.Call[](count);
        uint256 index;

        if (spotBuySize > 0) {
            calls[index++] = _buildOrderCall(
                spotAssetIndex, true, _applyBuySlippage(live.spotPx), spotBuySize, false, _orderCloid(1)
            );
        }
        if (spotSellSize > 0) {
            calls[index++] = _buildOrderCall(
                spotAssetIndex, false, _applySellSlippage(live.spotPx), spotSellSize, false, _orderCloid(2)
            );
        }
        if (shortOpenSize > 0) {
            calls[index++] = _buildOrderCall(
                perpAssetIndex, false, _applySellSlippage(live.markPx), shortOpenSize, false, _orderCloid(3)
            );
        }
        if (shortCloseSize > 0) {
            calls[index] = _buildOrderCall(
                perpAssetIndex, true, _applyBuySlippage(live.markPx), shortCloseSize, true, _orderCloid(4)
            );
        }
    }

    function _buildUnwindCalls(HyperliquidLiveState memory live, HyperliquidUnwindSizing memory sizing)
        internal
        view
        override
        returns (IUniversalAdapterEscrow.Call[] memory calls)
    {
        uint256 count;
        if (sizing.spotSizeToSell > 0) count++;
        if (sizing.perpSizeToClose > 0) count++;
        if (count == 0) return new IUniversalAdapterEscrow.Call[](0);

        calls = new IUniversalAdapterEscrow.Call[](count);
        uint256 index;

        if (sizing.spotSizeToSell > 0) {
            calls[index++] = _buildOrderCall(
                spotAssetIndex, false, _applySellSlippage(live.spotPx), sizing.spotSizeToSell, false, _orderCloid(5)
            );
        }
        if (sizing.perpSizeToClose > 0) {
            calls[index] = _buildOrderCall(
                perpAssetIndex, true, _applyBuySlippage(live.markPx), sizing.perpSizeToClose, true, _orderCloid(6)
            );
        }
    }

    function _buildOrderCall(
        uint32 assetIndex_,
        bool isBuy,
        uint64 limitPx,
        uint64 size,
        bool reduceOnly,
        uint128 cloid
    ) internal view returns (IUniversalAdapterEscrow.Call memory) {
        return HyperliquidLib.buildOrderCall(
            venue,
            HyperliquidOrderRequest({
                assetIndex: assetIndex_,
                isBuy: isBuy,
                limitPx: limitPx,
                size: size,
                reduceOnly: reduceOnly,
                encodedTif: orderTif,
                cloid: cloid
            })
        );
    }

    function _applyBuySlippage(uint64 price) internal view returns (uint64) {
        return uint64(_mulDivUp(price, BPS + maxOrderSlippageBps, BPS));
    }

    function _applySellSlippage(uint64 price) internal view returns (uint64 limitPx) {
        limitPx = uint64(uint256(price) * (BPS - maxOrderSlippageBps) / BPS);
        if (limitPx == 0) limitPx = 1;
    }

    function _isRiskDegraded(HyperliquidLiveState memory live) internal view override returns (bool) {
        return !_withinBand(live.oraclePx, live.markPx, maxOracleDivergenceBps) || _marginStressed(live);
    }

    function _marginStressed(HyperliquidLiveState memory live) internal view returns (bool) {
        if (live.marginSummary.accountValue <= 0) return true;
        return uint256(live.marginSummary.marginUsed) * BPS
            > uint256(int256(live.marginSummary.accountValue)) * maxMarginUsageBps;
    }

    function _withinBand(uint256 left, uint256 right, uint256 maxBandBps) internal pure override returns (bool) {
        if (left == 0 && right == 0) return true;
        uint256 larger = left > right ? left : right;
        uint256 smaller = left > right ? right : left;
        return (larger - smaller) * BPS <= larger * maxBandBps;
    }

    function _settlementQueue() internal view returns (address queue) {
        return ControllerLiquidityLib.settlementQueue(address(sleeve));
    }

    function _orderCloid(uint128 salt) internal view returns (uint128) {
        return uint128(uint256(keccak256(abi.encodePacked(strategyId, salt))));
    }

    function _automationFlags() internal pure override returns (uint256) {
        return 1;
    }

    function _mulDivUp(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256) {
        return x == 0 || y == 0 ? 0 : (x * y - 1) / denominator + 1;
    }
}
