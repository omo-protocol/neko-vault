// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IUniversalAdapterEscrow} from "../adapters/interfaces/IUniversalAdapterEscrow.sol";
import {IVaultV2} from "../interfaces/IVaultV2.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {
    IAsyncWithdrawalController,
    IAutomatedWithdrawalController,
    IOnchainStrategyValuer
} from "./StrategyControllerInterfaces.sol";
import {ControllerLiquidityLib} from "./libraries/ControllerLiquidityLib.sol";
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
    VenueConfig
} from "../strategies/StrategyTypes.sol";

abstract contract DeltaNeutralControllerBase is
    ReentrancyGuard,
    IAutomatedWithdrawalController,
    IAsyncWithdrawalController,
    IOnchainStrategyValuer
{
    using ControllerLiquidityLib for address;

    bytes32 public constant HYPERLIQUID_VENUE_ID = keccak256("HYPERLIQUID");
    uint256 internal constant BPS = 10_000;

    error NotOwner();
    error NotVaultManager();
    error InvalidAddress();
    error InvalidReserveConfig();
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

    address public owner;
    address public vaultManager;
    IVaultV2 public vault;
    IUniversalAdapterEscrow public sleeve;
    address public asset;
    bytes32 public strategyId;
    uint256 public targetReserveBps;
    bytes32 public venueId;
    address public venue;
    address public helper;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyVaultManager() {
        if (msg.sender != vaultManager) revert NotVaultManager();
        _;
    }

    SpotSideMode public spotSideMode;
    uint256 public maxDeltaBps;
    uint256 public kellySpotYieldWad;
    uint256 public kellyMarginYieldWad;
    uint256 public kellyBaseFundingRateWad;
    uint256 public kellyEthVolatilityWad;
    uint256 public kellyLiquidationLossWad;
    uint256 public kellyRebalanceThresholdWad;
    uint256 public kellyMinBenefitWad;
    uint256 public kellyShortTakerFeeWad;
    uint256 public kellyEntrySlippageWad;
    uint256 public kellyExitSlippageWad;
    uint256 public kellyShortSlippageWad;
    uint256 public kellyBridgeSlippageWad;
    uint256 public kellySizeImpactThresholdAssets;
    uint256 public kellySizeImpactMultiplierWad;
    uint256 public kellyBridgeFeeAssets;
    uint256 public kellyGasSpotActionAssets;
    uint256 public kellyGasShortActionAssets;
    uint256 public kellyFixedRebalanceCostAssets;
    uint256 public kellyTimeYearsWad;
    uint256 public kellyPeriodVolWad;
    uint256 public kellySpotToPerpCostWad;
    uint256 public kellySpotToPerpCostHighWad;
    uint256 public kellyPerpToSpotCostWad;
    uint256 public kellyPerpToSpotCostHighWad;
    uint32 public kellyTimeHorizonDays;
    uint16 public kellyFundingDivisor;
    uint16 public kellyAsymmetricRebalanceThresholdBps;
    int256 public kellyLogLiquidationLossWad;
    uint32 public spotAssetIndex;
    uint32 public perpAssetIndex;
    uint32 public spotPriceIndex;
    uint32 public perpDexIndex;
    uint64 public spotToken;
    uint8 public spotTokenDecimals;
    uint8 public orderTif;
    address public hyperCoreVault;
    uint16 public maxOrderSlippageBps;
    uint16 public maxOracleDivergenceBps;
    uint16 public maxMarginUsageBps;
    bool private _initialized;

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
    ) {
        if (
            owner_ == address(0) && vaultManager_ == address(0) && vault_ == address(0) && sleeve_ == address(0)
                && strategyId_ == bytes32(0)
        ) {
            _initialized = true;
            return;
        }
        _initialize(
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
        );
    }

    function initialize(
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
    ) external {
        _initialize(
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
        );
    }

    function _initialize(
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
    ) internal {
        if (_initialized) revert NotOwner();
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

        _initialized = true;
        KellyLinearState memory derivedKellyState = DeltaNeutralKellyLib.deriveState(kellyConfig_);

        owner = owner_;
        vaultManager = vaultManager_;
        vault = IVaultV2(vault_);
        sleeve = IUniversalAdapterEscrow(sleeve_);
        asset = IVaultV2(vault_).asset();
        strategyId = strategyId_;
        targetReserveBps = targetReserveBps_;
        venueId = venueConfig_.venueId;
        venue = venueConfig_.venue;
        helper = venueConfig_.helper;

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
        return VenueConfig({venueId: venueId, venue: venue, helper: helper});
    }

    function reserveTarget(uint256 totalAssets) public view returns (uint256) {
        return ControllerLiquidityLib.reserveTarget(totalAssets, targetReserveBps);
    }

    function protectedWithdrawalLiquidity() public view returns (uint256 assets) {
        return address(sleeve).protectedWithdrawalLiquidity();
    }

    function requiredLocalLiquidity(uint256 totalAssets) public view returns (uint256) {
        return ControllerLiquidityLib.requiredLocalLiquidity(address(sleeve), totalAssets, targetReserveBps);
    }

    function availableToAllocate(uint256 idleAssets, uint256 totalAssets) public view returns (uint256) {
        return ControllerLiquidityLib.availableToAllocate(
            asset, address(vault), address(sleeve), idleAssets, totalAssets, targetReserveBps
        );
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
        if (shortfallAssets == 0) return false;

        HyperliquidLiveState memory live = _liveState();
        HyperliquidUnwindSizing memory sizing =
            _quoteUnwindExecution(0, shortfallAssets, live.spotAssets, live.hedgeCollateralAssets);
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
        if (shortfallAssets == 0) return new IUniversalAdapterEscrow.Call[](0);

        HyperliquidLiveState memory live = _liveState();
        HyperliquidUnwindSizing memory sizing =
            _quoteUnwindExecution(0, shortfallAssets, live.spotAssets, live.hedgeCollateralAssets);
        return _buildUnwindCalls(live, sizing);
    }

    function quoteCurrentAssets() external view override returns (uint256 assets, bool healthy) {
        HyperliquidLiveState memory live = _liveState();
        uint256 hedgeEquityAssets =
            live.marginSummary.accountValue > 0 ? uint256(uint64(live.marginSummary.accountValue)) : 0;
        return (live.idleAssets + live.spotAssets + hedgeEquityAssets, !_isRiskDegraded(live));
    }

    function quoteUnwindExecution(
        uint256 idleAssets,
        uint256 requestedAssets,
        uint256 spotAssets,
        uint256 hedgeCollateralAssets
    ) external view returns (HyperliquidUnwindSizing memory sizing) {
        return _quoteUnwindExecution(idleAssets, requestedAssets, spotAssets, hedgeCollateralAssets);
    }

    function withinDeltaBand(uint256 spotAssets, uint256 hedgeCollateralAssets) public view returns (bool) {
        if (spotAssets == 0 && hedgeCollateralAssets == 0) return true;

        uint256 larger = spotAssets > hedgeCollateralAssets ? spotAssets : hedgeCollateralAssets;
        uint256 smaller = spotAssets > hedgeCollateralAssets ? hedgeCollateralAssets : spotAssets;
        uint256 difference = larger - smaller;

        return difference * BPS <= larger * maxDeltaBps;
    }

    function quoteKellyRebalance(uint256 spotAssets, uint256 hedgeCollateralAssets)
        external
        view
        returns (DeltaNeutralKellyRebalanceQuote memory quote)
    {
        KellyLinearState memory state = _kellyState();
        return DeltaNeutralKellyLib.quoteRebalance(state, spotAssets, hedgeCollateralAssets);
    }

    function planWithdrawal(uint256 idleAssets, uint256 requestedAssets, uint256 spotAssets, uint256 hedgeCollateralAssets)
        external
        pure
        returns (DeltaNeutralUnwindPlan memory)
    {
        return _planWithdrawal(idleAssets, requestedAssets, spotAssets, hedgeCollateralAssets);
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
        uint256 hedgeCollateralAssets
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
            requiresEmergencyExit: unmetAssets > 0
        });
    }


    function _liveState() internal view virtual returns (HyperliquidLiveState memory state);
    function _buildUnwindCalls(HyperliquidLiveState memory live, HyperliquidUnwindSizing memory sizing)
        internal
        view
        virtual
        returns (IUniversalAdapterEscrow.Call[] memory calls);
    function _quoteUnwindExecution(
        uint256 idleAssets,
        uint256 requestedAssets,
        uint256 spotAssets,
        uint256 hedgeCollateralAssets
    ) internal view virtual returns (HyperliquidUnwindSizing memory sizing);
    function _kellyState() internal view virtual returns (KellyLinearState memory state);
    function _buildTargetCalls(HyperliquidLiveState memory live, uint256 targetSpotAssets, uint256 targetShortAssets)
        internal
        view
        virtual
        returns (IUniversalAdapterEscrow.Call[] memory calls);
    function _isRiskDegraded(HyperliquidLiveState memory live) internal view virtual returns (bool);
    function _withinBand(uint256 left, uint256 right, uint256 maxBandBps) internal pure virtual returns (bool);
    function _automationFlags() internal pure virtual returns (uint256);
}
