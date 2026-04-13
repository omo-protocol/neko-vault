// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IUniversalAdapterEscrow} from "../adapters/interfaces/IUniversalAdapterEscrow.sol";
import {IVaultV2} from "../interfaces/IVaultV2.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {
    IAsyncWithdrawalController,
    IAutomatedWithdrawalController,
    IOnchainStrategyValuer,
    IRemotePpsSnapshotStore,
    IWithdrawalReserveSource
} from "./StrategyControllerInterfaces.sol";
import {DeltaNeutralKellyLib} from "./libraries/DeltaNeutralKellyLib.sol";
import {L1Read} from "./venue_specific/hyperliquid/L1Read.sol";
import {
    HyperliquidLib,
    HyperliquidOrderRequest,
    HyperliquidUnwindSizing
} from "./venue_specific/hyperliquid/HyperliquidLib.sol";
import {
    StrategyKind,
    StrategySpec,
    SpotSideMode,
    DeltaNeutralKellyConfig,
    DeltaNeutralAutomationConfig,
    KellyLinearState,
    DeltaNeutralKellyRebalanceQuote,
    DeltaNeutralUnwindPlan,
    ChainManifest,
    VenueConfig
} from "../strategies/StrategyTypes.sol";

contract DeltaNeutralController is
    ReentrancyGuard,
    IAutomatedWithdrawalController,
    IAsyncWithdrawalController,
    IOnchainStrategyValuer
{
    bytes32 public constant HYPERLIQUID_VENUE_ID = keccak256("HYPERLIQUID");
    uint256 internal constant BPS = 10_000;

    error NotOwner();
    error NotVaultManager();
    error InvalidAddress();
    error InvalidReserveConfig();
    error InvalidChainManifest();
    error InvalidVenue();
    error InvalidDeltaConfig();
    error InvalidKellyConfig();
    error InvalidAutomationConfig();
    error AutomaticSyncUnavailable();

    struct HyperliquidLiveState {
        uint64 oraclePx;
        uint64 markPx;
        uint64 spotPx;
        uint256 spotAssets;
        uint256 shortAssets;
        uint256 hedgeCollateralAssets;
        uint256 idleAssets;
        uint256 spotBaseUnits;
        uint256 perpBaseUnits;
        L1Read.AccountMarginSummary marginSummary;
    }

    address public immutable owner;
    address public immutable vaultManager;
    IVaultV2 public immutable vault;
    IUniversalAdapterEscrow public immutable sleeve;
    address public immutable remotePpsSnapshotStore;
    address public immutable asset;
    bytes32 public immutable strategyId;
    uint256 public immutable targetReserveBps;
    bytes32 public immutable venueId;
    address public immutable venue;
    address public immutable helper;
    bool public immutable venueUsesLayerZero;

    ChainManifest[] internal _chainManifests;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyVaultManager() {
        if (msg.sender != vaultManager) revert NotVaultManager();
        _;
    }

    SpotSideMode public immutable spotSideMode;
    uint256 public immutable maxDeltaBps;
    uint256 public immutable kellySpotYieldWad;
    uint256 public immutable kellyMarginYieldWad;
    uint256 public immutable kellyBaseFundingRateWad;
    uint256 public immutable kellyEthVolatilityWad;
    uint256 public immutable kellyLiquidationLossWad;
    uint256 public immutable kellyRebalanceThresholdWad;
    uint256 public immutable kellyMinBenefitWad;
    uint256 public immutable kellyShortTakerFeeWad;
    uint256 public immutable kellyEntrySlippageWad;
    uint256 public immutable kellyExitSlippageWad;
    uint256 public immutable kellyShortSlippageWad;
    uint256 public immutable kellyBridgeSlippageWad;
    uint256 public immutable kellySizeImpactThresholdAssets;
    uint256 public immutable kellySizeImpactMultiplierWad;
    uint256 public immutable kellyBridgeFeeAssets;
    uint256 public immutable kellyGasSpotActionAssets;
    uint256 public immutable kellyGasShortActionAssets;
    uint256 public immutable kellyFixedRebalanceCostAssets;
    uint256 public immutable kellyTimeYearsWad;
    uint256 public immutable kellyPeriodVolWad;
    uint256 public immutable kellySpotToPerpCostWad;
    uint256 public immutable kellySpotToPerpCostHighWad;
    uint256 public immutable kellyPerpToSpotCostWad;
    uint256 public immutable kellyPerpToSpotCostHighWad;
    uint32 public immutable kellyTimeHorizonDays;
    uint16 public immutable kellyFundingDivisor;
    uint16 public immutable kellyAsymmetricRebalanceThresholdBps;
    int256 public immutable kellyLogLiquidationLossWad;
    uint32 public immutable spotAssetIndex;
    uint32 public immutable perpAssetIndex;
    uint32 public immutable spotPriceIndex;
    uint32 public immutable perpDexIndex;
    uint64 public immutable spotToken;
    uint8 public immutable spotTokenDecimals;
    uint8 public immutable orderTif;
    address public immutable hyperCoreVault;
    uint16 public immutable maxOrderSlippageBps;
    uint16 public immutable maxOracleDivergenceBps;
    uint16 public immutable maxMarginUsageBps;

    constructor(
        address owner_,
        address vaultManager_,
        address vault_,
        address sleeve_,
        address remotePpsSnapshotStore_,
        bytes32 strategyId_,
        uint256 targetReserveBps_,
        VenueConfig memory venueConfig_,
        ChainManifest[] memory chainManifests_,
        SpotSideMode spotSideMode_,
        uint256 maxDeltaBps_,
        DeltaNeutralKellyConfig memory kellyConfig_,
        DeltaNeutralAutomationConfig memory automationConfig_
    ) {
        if (
            owner_ == address(0) || vaultManager_ == address(0) || vault_ == address(0) || sleeve_ == address(0)
                || strategyId_ == bytes32(0)
        ) revert InvalidAddress();
        if (targetReserveBps_ > BPS) revert InvalidReserveConfig();
        if (
            venueConfig_.venueId != HYPERLIQUID_VENUE_ID || venueConfig_.venue == address(0)
                || venueConfig_.helper == address(0)
        ) revert InvalidVenue();
        if (maxDeltaBps_ > BPS) revert InvalidDeltaConfig();
        if (!DeltaNeutralKellyLib.isValidConfig(kellyConfig_)) revert InvalidKellyConfig();
        if (
            automationConfig_.spotToken == 0 || automationConfig_.spotTokenDecimals == 0
                || automationConfig_.maxOrderSlippageBps > BPS || automationConfig_.maxOracleDivergenceBps > BPS
                || automationConfig_.maxMarginUsageBps == 0 || automationConfig_.maxMarginUsageBps > BPS
        ) revert InvalidAutomationConfig();

        KellyLinearState memory derivedKellyState = DeltaNeutralKellyLib.deriveState(kellyConfig_);

        owner = owner_;
        vaultManager = vaultManager_;
        vault = IVaultV2(vault_);
        sleeve = IUniversalAdapterEscrow(sleeve_);
        remotePpsSnapshotStore = remotePpsSnapshotStore_;
        asset = IVaultV2(vault_).asset();
        strategyId = strategyId_;
        targetReserveBps = targetReserveBps_;
        venueId = venueConfig_.venueId;
        venue = venueConfig_.venue;
        helper = venueConfig_.helper;
        venueUsesLayerZero = venueConfig_.usesLayerZero;
        _storeChainManifests(chainManifests_, sleeve_);

        spotSideMode = spotSideMode_;
        maxDeltaBps = maxDeltaBps_;
        kellySpotYieldWad = kellyConfig_.spotYieldWad;
        kellyMarginYieldWad = kellyConfig_.marginYieldWad;
        kellyBaseFundingRateWad = kellyConfig_.baseFundingRateWad;
        kellyEthVolatilityWad = kellyConfig_.ethVolatilityWad;
        kellyLiquidationLossWad = kellyConfig_.liquidationLossWad;
        kellyRebalanceThresholdWad = kellyConfig_.rebalanceThresholdWad;
        kellyMinBenefitWad = kellyConfig_.minBenefitWad;
        kellyShortTakerFeeWad = kellyConfig_.shortTakerFeeWad;
        kellyEntrySlippageWad = kellyConfig_.entrySlippageWad;
        kellyExitSlippageWad = kellyConfig_.exitSlippageWad;
        kellyShortSlippageWad = kellyConfig_.shortSlippageWad;
        kellyBridgeSlippageWad = kellyConfig_.bridgeSlippageWad;
        kellySizeImpactThresholdAssets = kellyConfig_.sizeImpactThresholdAssets;
        kellySizeImpactMultiplierWad = kellyConfig_.sizeImpactMultiplierWad;
        kellyBridgeFeeAssets = kellyConfig_.bridgeFeeAssets;
        kellyGasSpotActionAssets = kellyConfig_.gasSpotActionAssets;
        kellyGasShortActionAssets = kellyConfig_.gasShortActionAssets;
        kellyFixedRebalanceCostAssets = derivedKellyState.fixedRebalanceCostAssets;
        kellyTimeHorizonDays = kellyConfig_.timeHorizonDays;
        kellyFundingDivisor = kellyConfig_.fundingDivisor;
        kellyAsymmetricRebalanceThresholdBps = kellyConfig_.asymmetricRebalanceThresholdBps;
        kellyTimeYearsWad = derivedKellyState.timeYearsWad;
        kellyPeriodVolWad = derivedKellyState.periodVolWad;
        kellySpotToPerpCostWad = derivedKellyState.decreaseRiskCostWad;
        kellySpotToPerpCostHighWad = derivedKellyState.decreaseRiskCostHighWad;
        kellyPerpToSpotCostWad = derivedKellyState.increaseRiskCostWad;
        kellyPerpToSpotCostHighWad = derivedKellyState.increaseRiskCostHighWad;
        kellyLogLiquidationLossWad = derivedKellyState.logLiquidationLossWad;
        spotAssetIndex = automationConfig_.spotAssetIndex;
        perpAssetIndex = automationConfig_.perpAssetIndex;
        spotPriceIndex = automationConfig_.spotPriceIndex;
        perpDexIndex = automationConfig_.perpDexIndex;
        spotToken = automationConfig_.spotToken;
        spotTokenDecimals = automationConfig_.spotTokenDecimals;
        orderTif = automationConfig_.encodedTif;
        hyperCoreVault = automationConfig_.hyperCoreVault;
        maxOrderSlippageBps = automationConfig_.maxOrderSlippageBps;
        maxOracleDivergenceBps = automationConfig_.maxOracleDivergenceBps;
        maxMarginUsageBps = automationConfig_.maxMarginUsageBps;
    }

    function getStrategySpec() external view returns (StrategySpec memory) {
        return StrategySpec({
            kind: StrategyKind.DeltaNeutral,
            asset: asset,
            strategyId: strategyId,
            targetReserveBps: targetReserveBps
        });
    }

    function getVenueConfig() external view returns (VenueConfig memory) {
        return VenueConfig({venueId: venueId, venue: venue, helper: helper, usesLayerZero: venueUsesLayerZero});
    }

    function chainManifestCount() external view returns (uint256) {
        return _chainManifests.length;
    }

    function getChainManifest(uint256 index) external view returns (ChainManifest memory) {
        return _chainManifests[index];
    }

    function remoteChainCount() external view returns (uint256 count) {
        for (uint256 i; i < _chainManifests.length; i++) {
            if (!_chainManifests[i].isHomeChain) count++;
        }
    }

    function reserveTarget(uint256 totalAssets) public view returns (uint256) {
        return totalAssets * targetReserveBps / BPS;
    }

    function protectedWithdrawalLiquidity() public view returns (uint256 assets) {
        address queue = _settlementQueue();
        if (queue == address(0)) return 0;

        (bool success, bytes memory data) =
            queue.staticcall(abi.encodeWithSelector(IWithdrawalReserveSource.totalProtectedAssets.selector));
        if (!success || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    function requiredLocalLiquidity(uint256 totalAssets) public view returns (uint256) {
        uint256 targetReserve = reserveTarget(totalAssets);
        uint256 protectedAssets = protectedWithdrawalLiquidity();
        return targetReserve > protectedAssets ? targetReserve : protectedAssets;
    }

    function availableToAllocate(uint256 idleAssets, uint256 totalAssets) public view returns (uint256) {
        uint256 requiredLiquidity = requiredLocalLiquidity(totalAssets);
        uint256 totalLiquidAssets = IERC20(asset).balanceOf(address(vault)) + idleAssets;
        if (totalLiquidAssets <= requiredLiquidity) return 0;

        uint256 allocatableAssets = totalLiquidAssets - requiredLiquidity;
        return allocatableAssets < idleAssets ? allocatableAssets : idleAssets;
    }

    function liquidityData() public view returns (bytes memory) {
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](0);
        return abi.encode(strategyId, _automationFlags(), calls);
    }

    function allocateIdle(uint256 assets) external onlyOwner nonReentrant {
        vault.allocate(address(sleeve), liquidityData(), assets);
    }

    function executeStrategy(IUniversalAdapterEscrow.Call[] calldata calls) external onlyOwner nonReentrant {
        sleeve.executeStrategy(strategyId, calls);
    }

    function executeStrategyBypassCircuitBreaker(IUniversalAdapterEscrow.Call[] calldata calls)
        external
        onlyOwner
        nonReentrant
    {
        sleeve.executeStrategyBypassCircuitBreaker(strategyId, calls);
    }

    function configureLiquidityAdapter() external onlyOwner nonReentrant {
        vault.setLiquidityAdapterAndData(address(sleeve), liquidityData());
    }

    function clearLiquidityAdapter() external onlyOwner nonReentrant {
        vault.setLiquidityAdapterAndData(address(0), "");
    }

    function sync() external onlyVaultManager nonReentrant returns (bool executed) {
        IUniversalAdapterEscrow.Call[] memory calls = _quoteSync(_liveState());
        if (calls.length == 0) return false;
        sleeve.executeStrategyBypassCircuitBreaker(strategyId, calls);
        return true;
    }

    function syncPPS() external onlyVaultManager nonReentrant returns (uint256 assets) {
        sleeve.refreshCachedValuation();
        (assets,,) = sleeve.getCachedValuation();
    }

    function initiateAsyncWithdrawal(uint256 shortfallAssets) external nonReentrant returns (bool initiated) {
        if (_hasRemoteChain()) revert AutomaticSyncUnavailable();
        if (shortfallAssets == 0) return false;

        HyperliquidLiveState memory live = _liveState();
        HyperliquidUnwindSizing memory sizing =
            _quoteUnwindExecution(0, shortfallAssets, live.spotAssets, live.hedgeCollateralAssets, false);
        IUniversalAdapterEscrow.Call[] memory calls = _buildUnwindCalls(live, sizing);
        if (calls.length == 0) return false;

        sleeve.executeStrategyBypassCircuitBreaker(strategyId, calls);
        return true;
    }

    function quoteAutomaticAllocation(uint256) external view override returns (IUniversalAdapterEscrow.Call[] memory) {
        HyperliquidLiveState memory live = _liveState();
        if (_isRiskDegraded(live)) return new IUniversalAdapterEscrow.Call[](0);
        uint256 totalAssets = live.spotAssets + live.hedgeCollateralAssets + live.idleAssets;
        live.idleAssets = availableToAllocate(live.idleAssets, totalAssets);
        if (live.idleAssets == 0) return new IUniversalAdapterEscrow.Call[](0);
        return _quoteTargetCalls(live);
    }

    function quoteAutomaticWithdrawal(uint256 shortfallAssets)
        external
        view
        override
        returns (IUniversalAdapterEscrow.Call[] memory)
    {
        if (_hasRemoteChain()) revert AutomaticSyncUnavailable();
        if (shortfallAssets == 0) return new IUniversalAdapterEscrow.Call[](0);

        HyperliquidLiveState memory live = _liveState();
        HyperliquidUnwindSizing memory sizing =
            _quoteUnwindExecution(0, shortfallAssets, live.spotAssets, live.hedgeCollateralAssets, false);
        return _buildUnwindCalls(live, sizing);
    }

    function quoteCurrentAssets() external view override returns (uint256 assets, bool healthy) {
        HyperliquidLiveState memory live = _liveState();
        (uint256 remoteAssets, bool remoteHealthy) = _quoteRemoteAssets();
        if (!remoteHealthy) {
            return (0, false);
        }
        uint256 hedgeEquityAssets =
            live.marginSummary.accountValue > 0 ? uint256(uint64(live.marginSummary.accountValue)) : 0;
        return (
            live.idleAssets + live.spotAssets + hedgeEquityAssets + remoteAssets,
            !_isRiskDegraded(live) && remoteHealthy
        );
    }

    function quoteUnwindExecution(
        uint256 idleAssets,
        uint256 requestedAssets,
        uint256 spotAssets,
        uint256 hedgeCollateralAssets,
        bool remoteHedge
    ) external view returns (HyperliquidUnwindSizing memory sizing) {
        return _quoteUnwindExecution(idleAssets, requestedAssets, spotAssets, hedgeCollateralAssets, remoteHedge);
    }

    function withinDeltaBand(uint256 spotAssets, uint256 hedgeCollateralAssets) public view returns (bool) {
        if (spotAssets == 0 && hedgeCollateralAssets == 0) return true;

        uint256 larger = spotAssets > hedgeCollateralAssets ? spotAssets : hedgeCollateralAssets;
        uint256 smaller = spotAssets > hedgeCollateralAssets ? hedgeCollateralAssets : spotAssets;
        uint256 difference = larger - smaller;

        return difference * BPS <= larger * maxDeltaBps;
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

    function quoteKellyRebalance(uint256 spotAssets, uint256 hedgeCollateralAssets)
        external
        view
        returns (DeltaNeutralKellyRebalanceQuote memory quote)
    {
        KellyLinearState memory state = _kellyState();
        return DeltaNeutralKellyLib.quoteRebalance(state, spotAssets, hedgeCollateralAssets);
    }

    function planWithdrawal(
        uint256 idleAssets,
        uint256 requestedAssets,
        uint256 spotAssets,
        uint256 hedgeCollateralAssets,
        bool remoteHedge
    ) external pure returns (DeltaNeutralUnwindPlan memory) {
        return _planWithdrawal(idleAssets, requestedAssets, spotAssets, hedgeCollateralAssets, remoteHedge);
    }

    function _quoteSync(HyperliquidLiveState memory live)
        internal
        view
        returns (IUniversalAdapterEscrow.Call[] memory)
    {
        if (_isRiskDegraded(live)) {
            return _buildTargetCalls(live, 0, 0);
        }

        return _quoteTargetCalls(live);
    }

    function _quoteTargetCalls(HyperliquidLiveState memory live)
        internal
        view
        returns (IUniversalAdapterEscrow.Call[] memory)
    {
        uint256 residualAssets = live.hedgeCollateralAssets + live.idleAssets;
        DeltaNeutralKellyRebalanceQuote memory quote =
            DeltaNeutralKellyLib.quoteRebalance(_kellyState(), live.spotAssets, residualAssets);

        bool shortOutOfBand = !_withinBand(live.shortAssets, quote.targetSpotAssets, maxDeltaBps);
        if (!quote.shouldRebalance && !shortOutOfBand) {
            return new IUniversalAdapterEscrow.Call[](0);
        }

        return _buildTargetCalls(live, quote.targetSpotAssets, quote.targetSpotAssets);
    }

    function _planWithdrawal(
        uint256 idleAssets,
        uint256 requestedAssets,
        uint256 spotAssets,
        uint256 hedgeCollateralAssets,
        bool remoteHedge
    ) internal pure returns (DeltaNeutralUnwindPlan memory) {
        uint256 shortfallAssets = requestedAssets > idleAssets ? requestedAssets - idleAssets : 0;
        if (shortfallAssets == 0) {
            return DeltaNeutralUnwindPlan({
                idleAssets: idleAssets,
                requestedAssets: requestedAssets,
                shortfallAssets: 0,
                spotReductionAssets: 0,
                hedgeReductionAssets: 0,
                releaseableAssets: 0,
                unmetAssets: 0,
                requiresLayerZero: false,
                requiresEmergencyExit: false
            });
        }

        uint256 totalReleasable = spotAssets + hedgeCollateralAssets;
        uint256 releaseableAssets = shortfallAssets > totalReleasable ? totalReleasable : shortfallAssets;
        uint256 unmetAssets = shortfallAssets - releaseableAssets;

        uint256 spotReductionAssets;
        uint256 hedgeReductionAssets;

        if (releaseableAssets > 0 && totalReleasable > 0) {
            spotReductionAssets = releaseableAssets * spotAssets / totalReleasable;
            hedgeReductionAssets = releaseableAssets - spotReductionAssets;

            if (hedgeReductionAssets > hedgeCollateralAssets) {
                hedgeReductionAssets = hedgeCollateralAssets;
                spotReductionAssets = releaseableAssets - hedgeReductionAssets;
            }
        }

        return DeltaNeutralUnwindPlan({
            idleAssets: idleAssets,
            requestedAssets: requestedAssets,
            shortfallAssets: shortfallAssets,
            spotReductionAssets: spotReductionAssets,
            hedgeReductionAssets: hedgeReductionAssets,
            releaseableAssets: releaseableAssets,
            unmetAssets: unmetAssets,
            requiresLayerZero: remoteHedge && hedgeReductionAssets > 0,
            requiresEmergencyExit: unmetAssets > 0
        });
    }

    function _quoteUnwindExecution(
        uint256 idleAssets,
        uint256 requestedAssets,
        uint256 spotAssets,
        uint256 hedgeCollateralAssets,
        bool remoteHedge
    ) internal view returns (HyperliquidUnwindSizing memory sizing) {
        DeltaNeutralUnwindPlan memory plan =
            _planWithdrawal(idleAssets, requestedAssets, spotAssets, hedgeCollateralAssets, remoteHedge);

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
            requiresLayerZero: plan.requiresLayerZero,
            requiresEmergencyExit: plan.requiresEmergencyExit
        });
    }

    function _kellyState() internal view returns (KellyLinearState memory state) {
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

    function _liveState() internal view returns (HyperliquidLiveState memory state) {
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

    function _isRiskDegraded(HyperliquidLiveState memory live) internal view returns (bool) {
        return !_withinBand(live.oraclePx, live.markPx, maxOracleDivergenceBps) || _marginStressed(live);
    }

    function _marginStressed(HyperliquidLiveState memory live) internal view returns (bool) {
        if (live.marginSummary.accountValue <= 0) return true;
        return uint256(live.marginSummary.marginUsed) * BPS
            > uint256(int256(live.marginSummary.accountValue)) * maxMarginUsageBps;
    }

    function _withinBand(uint256 left, uint256 right, uint256 maxBandBps) internal pure returns (bool) {
        if (left == 0 && right == 0) return true;
        uint256 larger = left > right ? left : right;
        uint256 smaller = left > right ? right : left;
        return (larger - smaller) * BPS <= larger * maxBandBps;
    }

    function _hasRemoteChain() internal view returns (bool hasRemote) {
        for (uint256 i; i < _chainManifests.length; i++) {
            if (!_chainManifests[i].isHomeChain) return true;
        }
    }

    function _quoteRemoteAssets() internal view returns (uint256 assets, bool healthy) {
        if (remotePpsSnapshotStore == address(0)) return (0, true);
        return IRemotePpsSnapshotStore(remotePpsSnapshotStore).quoteRemoteAssets();
    }

    function _settlementQueue() internal view returns (address queue) {
        (bool success, bytes memory data) = address(sleeve).staticcall(abi.encodeWithSignature("settlementQueue()"));
        if (!success || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }

    function _orderCloid(uint128 salt) internal view returns (uint128) {
        return uint128(uint256(keccak256(abi.encodePacked(strategyId, salt))));
    }

    function _automationFlags() internal pure returns (uint256) {
        return 1;
    }

    function _storeChainManifests(ChainManifest[] memory manifests, address homeSleeve) internal {
        if (manifests.length == 0) {
            if (venueUsesLayerZero) revert InvalidChainManifest();
            _chainManifests.push(
                ChainManifest({
                    chainId: block.chainid,
                    lzEid: 0,
                    sleeve: homeSleeve,
                    assetOFT: address(0),
                    shareOFT: address(0),
                    isHomeChain: true
                })
            );
            return;
        }

        bool seenHomeChain;
        bool seenRemoteChain;
        for (uint256 i; i < manifests.length; i++) {
            if (manifests[i].isHomeChain) {
                if (seenHomeChain) revert InvalidChainManifest();
                seenHomeChain = true;
                manifests[i].sleeve = homeSleeve;
            } else {
                if (manifests[i].sleeve == address(0) || manifests[i].lzEid == 0) revert InvalidChainManifest();
                seenRemoteChain = true;
            }
            _chainManifests.push(manifests[i]);
        }

        if (!seenHomeChain) revert InvalidChainManifest();
        if (venueUsesLayerZero && !seenRemoteChain) revert InvalidChainManifest();
    }

    function _mulDivUp(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256) {
        return x == 0 || y == 0 ? 0 : (x * y - 1) / denominator + 1;
    }
}
