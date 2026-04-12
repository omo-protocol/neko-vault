// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {KellyMathLib} from "./KellyMathLib.sol";
import {
    KellyLinearState,
    KellyOptimalWeight,
    KellyRebalanceQuote,
    KellyRebalanceDirection
} from "../../strategies/StrategyTypes.sol";

library KellyLinearOptimizerLib {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    function currentWeightBps(uint256 riskyAssets, uint256 residualAssets) internal pure returns (uint256) {
        uint256 capitalAssets = riskyAssets + residualAssets;
        if (capitalAssets == 0) return 0;
        return riskyAssets * BPS / capitalAssets;
    }

    function computeYieldWad(KellyLinearState memory state, uint256 weightBps) internal pure returns (uint256) {
        uint256 weightWad = _weightBpsToWad(_clampWeightBps(weightBps));
        return KellyMathLib.mulWad(weightWad, state.riskyYieldWad)
            + KellyMathLib.mulWad(WAD - weightWad, state.residualYieldWad)
            + KellyMathLib.mulWad(weightWad, state.carryRateWad) / state.carryDivisor;
    }

    function computeLiquidationProbabilityWad(KellyLinearState memory state, uint256 weightBps)
        internal
        pure
        returns (uint256)
    {
        uint256 clampedWeightBps = _clampWeightBps(weightBps);
        if (clampedWeightBps >= 9_990) return WAD;
        if (clampedWeightBps <= 10) return 0;

        uint256 weightWad = _weightBpsToWad(clampedWeightBps);
        uint256 thresholdWad = KellyMathLib.divWad(WAD - weightWad, weightWad);
        int256 zScoreWad =
            KellyMathLib.divWadSigned(KellyMathLib.wadLn(int256(WAD + thresholdWad)), int256(state.periodVolWad));

        return WAD - KellyMathLib.normalCdfWad(zScoreWad);
    }

    function computeLiquidationThresholdWad(uint256 weightBps) internal pure returns (uint256) {
        uint256 clampedWeightBps = _clampWeightBps(weightBps);
        if (clampedWeightBps >= 9_990) return 0;
        if (clampedWeightBps <= 10) return type(uint256).max;

        uint256 weightWad = _weightBpsToWad(clampedWeightBps);
        return KellyMathLib.divWad(WAD - weightWad, weightWad);
    }

    function computeExpectedLogReturnWad(KellyLinearState memory state, uint256 weightBps)
        internal
        pure
        returns (int256)
    {
        return _computeExpectedLogReturnWad(state, _clampWeightBps(weightBps), 0, 0, false);
    }

    function computeExpectedLogReturnAfterCostWad(
        KellyLinearState memory state,
        uint256 weightBps,
        uint256 currentWeightBps_,
        uint256 capitalAssets
    ) internal pure returns (int256) {
        return _computeExpectedLogReturnWad(
            state, _clampWeightBps(weightBps), _clampWeightBps(currentWeightBps_), capitalAssets, true
        );
    }

    function findOptimalWeight(KellyLinearState memory state)
        internal
        pure
        returns (KellyOptimalWeight memory optimal)
    {
        return _findOptimalWeight(state, 0, 0, false);
    }

    function findOptimalWeightWithCost(KellyLinearState memory state, uint256 currentWeightBps_, uint256 capitalAssets)
        internal
        pure
        returns (KellyOptimalWeight memory optimal)
    {
        return _findOptimalWeight(state, _clampWeightBps(currentWeightBps_), capitalAssets, true);
    }

    function quoteRebalance(KellyLinearState memory state, uint256 riskyAssets, uint256 residualAssets)
        internal
        pure
        returns (KellyRebalanceQuote memory quote)
    {
        uint256 capitalAssets = riskyAssets + residualAssets;
        uint256 currentWeight = currentWeightBps(riskyAssets, residualAssets);
        KellyOptimalWeight memory optimal =
            _findOptimalWeight(state, _clampWeightBps(currentWeight), capitalAssets, true);

        uint256 targetRiskyAssets = capitalAssets * optimal.weightBps / BPS;
        uint256 targetResidualAssets = capitalAssets - targetRiskyAssets;
        uint256 amountToMoveAssets =
            riskyAssets > targetRiskyAssets ? riskyAssets - targetRiskyAssets : targetRiskyAssets - riskyAssets;
        uint256 estimatedCostWad = _rebalanceCostWad(state, currentWeight, optimal.weightBps, capitalAssets);
        int256 currentExpectedLogReturnWad =
            _computeExpectedLogReturnWad(state, _clampWeightBps(currentWeight), 0, 0, false);
        bool passesAsymmetricThreshold = currentWeight > state.asymmetricRebalanceThresholdBps;
        int256 netBenefitWad = optimal.expectedLogReturnWad - currentExpectedLogReturnWad;

        KellyRebalanceDirection direction = KellyRebalanceDirection.None;
        if (optimal.weightBps < currentWeight) direction = KellyRebalanceDirection.DecreaseRisk;
        else if (optimal.weightBps > currentWeight) direction = KellyRebalanceDirection.IncreaseRisk;

        quote = KellyRebalanceQuote({
            currentWeightBps: currentWeight,
            targetWeightBps: optimal.weightBps,
            capitalAssets: capitalAssets,
            amountToMoveAssets: amountToMoveAssets,
            targetRiskyAssets: targetRiskyAssets,
            targetResidualAssets: targetResidualAssets,
            estimatedCostWad: estimatedCostWad,
            liquidationProbWad: optimal.liquidationProbWad,
            liquidationThresholdWad: optimal.liquidationThresholdWad,
            currentExpectedLogReturnWad: currentExpectedLogReturnWad,
            targetExpectedLogReturnWad: optimal.expectedLogReturnWad,
            netBenefitWad: netBenefitWad,
            passesAsymmetricThreshold: passesAsymmetricThreshold,
            shouldRebalance: passesAsymmetricThreshold
                && _weightBpsToWad(_absDiff(currentWeight, optimal.weightBps)) >= state.rebalanceThresholdWad
                && netBenefitWad >= int256(state.minBenefitWad),
            direction: direction
        });
    }

    function _findOptimalWeight(
        KellyLinearState memory state,
        uint256 currentWeightBps_,
        uint256 capitalAssets,
        bool includeCost
    ) private pure returns (KellyOptimalWeight memory optimal) {
        optimal.expectedLogReturnWad = type(int256).min;

        for (uint256 weightBps = 100; weightBps <= 9_900; weightBps += 100) {
            int256 candidateExpectedLogReturnWad =
                _computeExpectedLogReturnWad(state, weightBps, currentWeightBps_, capitalAssets, includeCost);

            if (candidateExpectedLogReturnWad > optimal.expectedLogReturnWad) {
                optimal = KellyOptimalWeight({
                    weightBps: weightBps,
                    expectedLogReturnWad: candidateExpectedLogReturnWad,
                    expectedYieldWad: computeYieldWad(state, weightBps),
                    liquidationProbWad: computeLiquidationProbabilityWad(state, weightBps),
                    liquidationThresholdWad: computeLiquidationThresholdWad(weightBps)
                });
            }
        }
    }

    function _computeExpectedLogReturnWad(
        KellyLinearState memory state,
        uint256 weightBps,
        uint256 currentWeightBps_,
        uint256 capitalAssets,
        bool includeCost
    ) private pure returns (int256) {
        uint256 clampedWeightBps = _clampWeightBps(weightBps);
        uint256 periodYieldWad = KellyMathLib.mulWad(computeYieldWad(state, clampedWeightBps), state.timeYearsWad);
        uint256 costWad = includeCost ? _rebalanceCostWad(state, currentWeightBps_, clampedWeightBps, capitalAssets) : 0;
        int256 netReturnWad = int256(periodYieldWad) - int256(costWad);
        uint256 liquidationProbWad = computeLiquidationProbabilityWad(state, clampedWeightBps);

        if (liquidationProbWad >= 999e15) return -1_000 * int256(WAD);

        int256 logNormalWad =
            netReturnWad > -int256(WAD) ? KellyMathLib.wadLn(int256(WAD) + netReturnWad) : -1_000 * int256(WAD);

        return KellyMathLib.mulWadSigned(int256(WAD - liquidationProbWad), logNormalWad)
            + KellyMathLib.mulWadSigned(int256(liquidationProbWad), state.logLiquidationLossWad);
    }

    function _rebalanceCostWad(
        KellyLinearState memory state,
        uint256 currentWeightBps_,
        uint256 targetWeightBps,
        uint256 capitalAssets
    ) private pure returns (uint256) {
        if (capitalAssets == 0) return 0;

        uint256 weightDeltaBps = _absDiff(currentWeightBps_, targetWeightBps);
        uint256 amountToMoveAssets = capitalAssets * weightDeltaBps / BPS;
        if (amountToMoveAssets == 0) return 0;

        bool increasingRisk = targetWeightBps > currentWeightBps_;
        uint256 variableCostRateWad = amountToMoveAssets > state.sizeImpactThresholdAssets
            ? (increasingRisk ? state.increaseRiskCostHighWad : state.decreaseRiskCostHighWad)
            : (increasingRisk ? state.increaseRiskCostWad : state.decreaseRiskCostWad);

        uint256 totalCostAssets =
            KellyMathLib.mulWad(amountToMoveAssets, variableCostRateWad) + state.fixedRebalanceCostAssets;

        return KellyMathLib.divWad(totalCostAssets, capitalAssets);
    }

    function _clampWeightBps(uint256 weightBps) private pure returns (uint256) {
        if (weightBps < 10) return 10;
        if (weightBps > 9_990) return 9_990;
        return weightBps;
    }

    function _weightBpsToWad(uint256 weightBps) private pure returns (uint256) {
        return weightBps * 1e14;
    }

    function _absDiff(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
