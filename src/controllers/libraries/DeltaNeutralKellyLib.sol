// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {KellyMathLib} from "./KellyMathLib.sol";
import {KellyLinearOptimizerLib} from "./KellyLinearOptimizerLib.sol";
import {
    DeltaNeutralKellyConfig,
    KellyLinearState,
    KellyOptimalWeight,
    KellyRebalanceQuote,
    KellyRebalanceDirection,
    DeltaNeutralKellyOptimalAlpha,
    DeltaNeutralKellyRebalanceQuote,
    DeltaNeutralRebalanceDirection
} from "../../strategies/StrategyTypes.sol";

library DeltaNeutralKellyLib {
    uint256 internal constant WAD = 1e18;

    function isValidConfig(DeltaNeutralKellyConfig memory config) internal pure returns (bool) {
        return config.fundingDivisor != 0 && config.timeHorizonDays != 0 && config.ethVolatilityWad != 0
            && config.liquidationLossWad < WAD && config.rebalanceThresholdWad <= WAD && config.minBenefitWad <= WAD
            && config.sizeImpactMultiplierWad >= WAD && config.asymmetricRebalanceThresholdBps <= 10_000;
    }

    function deriveState(DeltaNeutralKellyConfig memory config) internal pure returns (KellyLinearState memory state) {
        uint256 timeYearsWad = uint256(config.timeHorizonDays) * WAD / 365;

        return KellyLinearState({
            riskyYieldWad: config.spotYieldWad,
            residualYieldWad: config.marginYieldWad,
            carryRateWad: config.baseFundingRateWad,
            liquidationLossWad: config.liquidationLossWad,
            rebalanceThresholdWad: config.rebalanceThresholdWad,
            minBenefitWad: config.minBenefitWad,
            sizeImpactThresholdAssets: config.sizeImpactThresholdAssets,
            sizeImpactMultiplierWad: config.sizeImpactMultiplierWad,
            fixedRebalanceCostAssets: config.bridgeFeeAssets + config.gasSpotActionAssets + config.gasShortActionAssets,
            timeYearsWad: timeYearsWad,
            periodVolWad: KellyMathLib.mulWad(config.ethVolatilityWad, KellyMathLib.sqrtWad(timeYearsWad)),
            decreaseRiskCostWad: config.exitSlippageWad + config.shortTakerFeeWad + config.shortSlippageWad
                + config.bridgeSlippageWad,
            decreaseRiskCostHighWad: KellyMathLib.mulWad(config.exitSlippageWad, config.sizeImpactMultiplierWad)
                + config.shortTakerFeeWad + KellyMathLib.mulWad(config.shortSlippageWad, config.sizeImpactMultiplierWad)
                + config.bridgeSlippageWad,
            increaseRiskCostWad: config.entrySlippageWad + config.shortTakerFeeWad + config.shortSlippageWad
                + config.bridgeSlippageWad,
            increaseRiskCostHighWad: KellyMathLib.mulWad(config.entrySlippageWad, config.sizeImpactMultiplierWad)
                + config.shortTakerFeeWad + KellyMathLib.mulWad(config.shortSlippageWad, config.sizeImpactMultiplierWad)
                + config.bridgeSlippageWad,
            carryDivisor: config.fundingDivisor,
            asymmetricRebalanceThresholdBps: config.asymmetricRebalanceThresholdBps,
            logLiquidationLossWad: KellyMathLib.wadLn(int256(WAD - config.liquidationLossWad))
        });
    }

    function currentAlphaBps(uint256 spotAssets, uint256 hedgeCollateralAssets) internal pure returns (uint256) {
        return KellyLinearOptimizerLib.currentWeightBps(spotAssets, hedgeCollateralAssets);
    }

    function computeYieldWad(KellyLinearState memory state, uint256 alphaBps) internal pure returns (uint256) {
        return KellyLinearOptimizerLib.computeYieldWad(state, alphaBps);
    }

    function computeLiquidationProbabilityWad(KellyLinearState memory state, uint256 alphaBps)
        internal
        pure
        returns (uint256)
    {
        return KellyLinearOptimizerLib.computeLiquidationProbabilityWad(state, alphaBps);
    }

    function computeLiquidationThresholdWad(uint256 alphaBps) internal pure returns (uint256) {
        return KellyLinearOptimizerLib.computeLiquidationThresholdWad(alphaBps);
    }

    function computeExpectedLogReturnWad(KellyLinearState memory state, uint256 alphaBps)
        internal
        pure
        returns (int256)
    {
        return KellyLinearOptimizerLib.computeExpectedLogReturnWad(state, alphaBps);
    }

    function computeExpectedLogReturnAfterCostWad(
        KellyLinearState memory state,
        uint256 alphaBps,
        uint256 currentAlphaBps_,
        uint256 capitalAssets
    ) internal pure returns (int256) {
        return KellyLinearOptimizerLib.computeExpectedLogReturnAfterCostWad(
            state, alphaBps, currentAlphaBps_, capitalAssets
        );
    }

    function findOptimalAlpha(KellyLinearState memory state)
        internal
        pure
        returns (DeltaNeutralKellyOptimalAlpha memory optimal)
    {
        return _toDeltaOptimal(KellyLinearOptimizerLib.findOptimalWeight(state));
    }

    function findOptimalAlphaWithCost(KellyLinearState memory state, uint256 currentAlphaBps_, uint256 capitalAssets)
        internal
        pure
        returns (DeltaNeutralKellyOptimalAlpha memory optimal)
    {
        return
            _toDeltaOptimal(KellyLinearOptimizerLib.findOptimalWeightWithCost(state, currentAlphaBps_, capitalAssets));
    }

    function quoteRebalance(KellyLinearState memory state, uint256 spotAssets, uint256 hedgeCollateralAssets)
        internal
        pure
        returns (DeltaNeutralKellyRebalanceQuote memory quote)
    {
        KellyRebalanceQuote memory genericQuote =
            KellyLinearOptimizerLib.quoteRebalance(state, spotAssets, hedgeCollateralAssets);
        return DeltaNeutralKellyRebalanceQuote({
            currentAlphaBps: genericQuote.currentWeightBps,
            targetAlphaBps: genericQuote.targetWeightBps,
            capitalAssets: genericQuote.capitalAssets,
            amountToMoveAssets: genericQuote.amountToMoveAssets,
            targetSpotAssets: genericQuote.targetRiskyAssets,
            targetHedgeAssets: genericQuote.targetResidualAssets,
            estimatedCostWad: genericQuote.estimatedCostWad,
            liquidationProbWad: genericQuote.liquidationProbWad,
            liquidationThresholdWad: genericQuote.liquidationThresholdWad,
            currentExpectedLogReturnWad: genericQuote.currentExpectedLogReturnWad,
            targetExpectedLogReturnWad: genericQuote.targetExpectedLogReturnWad,
            netBenefitWad: genericQuote.netBenefitWad,
            passesAsymmetricThreshold: genericQuote.passesAsymmetricThreshold,
            shouldRebalance: genericQuote.shouldRebalance,
            direction: _toDeltaDirection(genericQuote.direction)
        });
    }

    function _toDeltaOptimal(KellyOptimalWeight memory optimal)
        private
        pure
        returns (DeltaNeutralKellyOptimalAlpha memory)
    {
        return DeltaNeutralKellyOptimalAlpha({
            alphaBps: optimal.weightBps,
            expectedLogReturnWad: optimal.expectedLogReturnWad,
            expectedYieldWad: optimal.expectedYieldWad,
            liquidationProbWad: optimal.liquidationProbWad,
            liquidationThresholdWad: optimal.liquidationThresholdWad
        });
    }

    function _toDeltaDirection(KellyRebalanceDirection direction)
        private
        pure
        returns (DeltaNeutralRebalanceDirection)
    {
        if (direction == KellyRebalanceDirection.DecreaseRisk) return DeltaNeutralRebalanceDirection.SpotToPerp;
        if (direction == KellyRebalanceDirection.IncreaseRisk) return DeltaNeutralRebalanceDirection.PerpToSpot;
        return DeltaNeutralRebalanceDirection.None;
    }
}
