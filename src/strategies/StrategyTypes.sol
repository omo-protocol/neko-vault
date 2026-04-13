// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

enum StrategyKind {
    DeltaNeutral,
    PTLoop
}

enum SpotSideMode {
    Hold,
    Lend,
    LP
}

enum DeltaNeutralRebalanceDirection {
    None,
    SpotToPerp,
    PerpToSpot
}

enum KellyRebalanceDirection {
    None,
    DecreaseRisk,
    IncreaseRisk
}

enum WithdrawalRequestStatus {
    Pending,
    PartiallyFunded,
    Claimable,
    Claimed,
    Cancelled
}

struct StrategySpec {
    StrategyKind kind;
    address asset;
    bytes32 strategyId;
    uint256 targetReserveBps;
}

struct ChainManifest {
    uint256 chainId;
    uint32 lzEid;
    address sleeve;
    address assetOFT;
    address shareOFT;
    bool isHomeChain;
}

struct VenueConfig {
    bytes32 venueId;
    address venue;
    address helper;
    bool usesLayerZero;
}

struct DeltaNeutralKellyConfig {
    uint256 spotYieldWad;
    uint256 marginYieldWad;
    uint256 baseFundingRateWad;
    uint256 ethVolatilityWad;
    uint256 liquidationLossWad;
    uint256 rebalanceThresholdWad;
    uint256 minBenefitWad;
    uint256 shortTakerFeeWad;
    uint256 entrySlippageWad;
    uint256 exitSlippageWad;
    uint256 shortSlippageWad;
    uint256 bridgeSlippageWad;
    uint256 sizeImpactThresholdAssets;
    uint256 sizeImpactMultiplierWad;
    uint256 bridgeFeeAssets;
    uint256 gasSpotActionAssets;
    uint256 gasShortActionAssets;
    uint32 timeHorizonDays;
    uint16 fundingDivisor;
    uint16 asymmetricRebalanceThresholdBps;
}

struct KellyLinearState {
    uint256 riskyYieldWad;
    uint256 residualYieldWad;
    uint256 carryRateWad;
    uint256 liquidationLossWad;
    uint256 rebalanceThresholdWad;
    uint256 minBenefitWad;
    uint256 sizeImpactThresholdAssets;
    uint256 sizeImpactMultiplierWad;
    uint256 fixedRebalanceCostAssets;
    uint256 timeYearsWad;
    uint256 periodVolWad;
    uint256 decreaseRiskCostWad;
    uint256 decreaseRiskCostHighWad;
    uint256 increaseRiskCostWad;
    uint256 increaseRiskCostHighWad;
    uint16 carryDivisor;
    uint16 asymmetricRebalanceThresholdBps;
    int256 logLiquidationLossWad;
}

struct DeltaNeutralAutomationConfig {
    uint32 spotAssetIndex;
    uint32 perpAssetIndex;
    uint32 spotPriceIndex;
    uint32 perpDexIndex;
    uint64 spotToken;
    uint8 spotTokenDecimals;
    uint8 encodedTif;
    address hyperCoreVault;
    uint16 maxOrderSlippageBps;
    uint16 maxOracleDivergenceBps;
    uint16 maxMarginUsageBps;
}

struct PTLoopAutomationConfig {
    uint16 maxEntrySlippageBps;
}

struct Deployment {
    address vault;
    address sleeve;
    address controller;
    address wrapper;
    bytes32 strategyId;
}

struct DeltaNeutralDeploymentParams {
    address owner;
    address vaultManager;
    address curator;
    bool enableTimelock;
    bool enableOmnichainVault;
    address asset;
    address valuer;
    string name;
    string symbol;
    bytes strategyIdData;
    SpotSideMode spotSideMode;
    uint256 targetReserveBps;
    uint256 maxDeltaBps;
    DeltaNeutralKellyConfig kellyConfig;
    DeltaNeutralAutomationConfig automationConfig;
    uint256 absoluteCap;
    uint256 relativeCap;
    bytes32 salt;
    bool useOffchainValuer;
    VenueConfig venueConfig;
    ChainManifest[] chainManifests;
}

struct PTLoopDeploymentParams {
    address owner;
    address vaultManager;
    address curator;
    bool enableTimelock;
    bool enableOmnichainVault;
    address asset;
    address market;
    address ptToken;
    address valuer;
    string name;
    string symbol;
    bytes strategyIdData;
    uint256 targetReserveBps;
    uint256 maxUnwindSlippageBps;
    PTLoopAutomationConfig automationConfig;
    uint256 absoluteCap;
    uint256 relativeCap;
    bytes32 salt;
    bool useOffchainValuer;
    VenueConfig venueConfig;
    ChainManifest[] chainManifests;
}

struct DeltaNeutralUnwindPlan {
    uint256 idleAssets;
    uint256 requestedAssets;
    uint256 shortfallAssets;
    uint256 spotReductionAssets;
    uint256 hedgeReductionAssets;
    uint256 releaseableAssets;
    uint256 unmetAssets;
    bool requiresLayerZero;
    bool requiresEmergencyExit;
}

struct DeltaNeutralKellyOptimalAlpha {
    uint256 alphaBps;
    int256 expectedLogReturnWad;
    uint256 expectedYieldWad;
    uint256 liquidationProbWad;
    uint256 liquidationThresholdWad;
}

struct KellyOptimalWeight {
    uint256 weightBps;
    int256 expectedLogReturnWad;
    uint256 expectedYieldWad;
    uint256 liquidationProbWad;
    uint256 liquidationThresholdWad;
}

struct KellyRebalanceQuote {
    uint256 currentWeightBps;
    uint256 targetWeightBps;
    uint256 capitalAssets;
    uint256 amountToMoveAssets;
    uint256 targetRiskyAssets;
    uint256 targetResidualAssets;
    uint256 estimatedCostWad;
    uint256 liquidationProbWad;
    uint256 liquidationThresholdWad;
    int256 currentExpectedLogReturnWad;
    int256 targetExpectedLogReturnWad;
    int256 netBenefitWad;
    bool passesAsymmetricThreshold;
    bool shouldRebalance;
    KellyRebalanceDirection direction;
}

struct DeltaNeutralKellyRebalanceQuote {
    uint256 currentAlphaBps;
    uint256 targetAlphaBps;
    uint256 capitalAssets;
    uint256 amountToMoveAssets;
    uint256 targetSpotAssets;
    uint256 targetHedgeAssets;
    uint256 estimatedCostWad;
    uint256 liquidationProbWad;
    uint256 liquidationThresholdWad;
    int256 currentExpectedLogReturnWad;
    int256 targetExpectedLogReturnWad;
    int256 netBenefitWad;
    bool passesAsymmetricThreshold;
    bool shouldRebalance;
    DeltaNeutralRebalanceDirection direction;
}

struct PTLoopUnwindPlan {
    uint256 idleAssets;
    uint256 requestedAssets;
    uint256 shortfallAssets;
    uint256 localReductionAssets;
    uint256 remoteReductionAssets;
    uint256 releaseableAssets;
    uint256 unmetAssets;
    bool requiresLayerZero;
    bool requiresEmergencyExit;
}

struct PTLoopUnloopQuote {
    uint256 requestedAssets;
    uint256 grossAssetTarget;
    uint256 expectedAssetOut;
    uint256 ptBalance;
    uint256 exactPtIn;
}

struct WithdrawalRequest {
    address owner;
    address receiver;
    uint256 sharesEscrowed;
    uint256 assetEstimate;
    uint256 reservedLocalAssets;
    uint256 assetsFunded;
    uint64 createdAt;
    WithdrawalRequestStatus status;
}
