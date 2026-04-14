// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IUniversalAdapterEscrow} from "../adapters/interfaces/IUniversalAdapterEscrow.sol";
import {IVaultV2} from "../interfaces/IVaultV2.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {
    IAutomatedWithdrawalController,
    IOnchainStrategyValuer
} from "./StrategyControllerInterfaces.sol";
import {ControllerLiquidityLib} from "./libraries/ControllerLiquidityLib.sol";
import {
    PendleLib,
    IPendleStaticQuoter,
    PTLoopOpenRequest,
    PTLoopCloseRequest
} from "./venue_specific/pendle/PendleLib.sol";
import {
    StrategyKind,
    StrategySpec,
    PTLoopAutomationConfig,
    PTLoopUnwindPlan,
    PTLoopUnloopQuote,
    VenueConfig
} from "../strategies/StrategyTypes.sol";

contract PTLoopController is ReentrancyGuard, IAutomatedWithdrawalController, IOnchainStrategyValuer {
    using ControllerLiquidityLib for address;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    bytes32 public constant PENDLE_VENUE_ID = keccak256("PENDLE");

    error NotOwner();
    error NotVaultManager();
    error InvalidAddress();
    error InvalidReserveConfig();
    error InvalidVenue();
    error InvalidSlippageConfig();
    error InvalidMarketConfig();
    error InsufficientLocalLiquidity();
    error AutomaticSyncUnavailable();

    event LiquidityPrepared(uint256 minBalanceIncrease, uint256 deallocatedAssets, bool usedProtocolWithdraw);

    address public immutable owner;
    address public immutable vaultManager;
    IVaultV2 public immutable vault;
    IUniversalAdapterEscrow public immutable sleeve;
    address public immutable asset;
    bytes32 public immutable strategyId;
    uint256 public immutable targetReserveBps;
    bytes32 public immutable venueId;
    address public immutable venue;
    address public immutable helper;

    uint256 public immutable maxEntrySlippageBps;
    uint256 public immutable maxUnwindSlippageBps;
    address public immutable market;
    address public immutable ptToken;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyVaultManager() {
        if (msg.sender != vaultManager) revert NotVaultManager();
        _;
    }

    constructor(
        address owner_,
        address vaultManager_,
        address vault_,
        address sleeve_,
        address market_,
        address ptToken_,
        bytes32 strategyId_,
        uint256 targetReserveBps_,
        VenueConfig memory venueConfig_,
        PTLoopAutomationConfig memory automationConfig_,
        uint256 maxUnwindSlippageBps_
    ) {
        if (
            owner_ == address(0) || vaultManager_ == address(0) || vault_ == address(0) || sleeve_ == address(0)
                || strategyId_ == bytes32(0)
        ) revert InvalidAddress();
        if (targetReserveBps_ > BPS) revert InvalidReserveConfig();
        if (venueConfig_.venueId != PENDLE_VENUE_ID || venueConfig_.venue == address(0)) revert InvalidVenue();
        if (maxUnwindSlippageBps_ > BPS || automationConfig_.maxEntrySlippageBps > BPS) revert InvalidSlippageConfig();
        if (venueConfig_.helper == address(0) || market_ == address(0) || ptToken_ == address(0)) {
            revert InvalidMarketConfig();
        }

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

        maxEntrySlippageBps = automationConfig_.maxEntrySlippageBps;
        maxUnwindSlippageBps = maxUnwindSlippageBps_;
        market = market_;
        ptToken = ptToken_;
    }

    function getStrategySpec() external view returns (StrategySpec memory) {
        return StrategySpec({
            kind: StrategyKind.PTLoop,
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

    function prepareWithdrawal(
        IUniversalAdapterEscrow.Call[] calldata withdrawCalls,
        uint256 minBalanceIncrease,
        uint256 deallocatedAssets
    ) external onlyOwner nonReentrant {
        bool usedProtocolWithdraw = withdrawCalls.length > 0;
        if (usedProtocolWithdraw) {
            sleeve.withdrawFromStrategy(strategyId, withdrawCalls, minBalanceIncrease);
        }
        if (deallocatedAssets > 0) {
            vault.deallocate(address(sleeve), liquidityData(), deallocatedAssets);
        }

        emit LiquidityPrepared(minBalanceIncrease, deallocatedAssets, usedProtocolWithdraw);
    }

    function configureLiquidityAdapter() external onlyOwner nonReentrant {
        vault.setLiquidityAdapterAndData(address(sleeve), liquidityData());
    }

    function clearLiquidityAdapter() external onlyOwner nonReentrant {
        vault.setLiquidityAdapterAndData(address(0), "");
    }

    function sync() external onlyVaultManager nonReentrant returns (bool executed) {
        IUniversalAdapterEscrow.Call[] memory calls = _quoteAutomaticAllocation();
        if (calls.length == 0) return false;
        sleeve.executeStrategyBypassCircuitBreaker(strategyId, calls);
        return true;
    }

    function syncPPS() external onlyVaultManager nonReentrant returns (uint256 assets) {
        sleeve.refreshCachedValuation();
        (assets,,) = sleeve.getCachedValuation();
    }

    function quoteAutomaticAllocation(uint256) external view override returns (IUniversalAdapterEscrow.Call[] memory) {
        return _quoteAutomaticAllocation();
    }

    function quoteAutomaticWithdrawal(uint256 shortfallAssets)
        external
        view
        override
        returns (IUniversalAdapterEscrow.Call[] memory)
    {
        if (shortfallAssets == 0) return new IUniversalAdapterEscrow.Call[](0);

        PTLoopUnloopQuote memory quote = quoteUnloopForAssets(shortfallAssets);
        return _buildCloseLoopCalls(_automaticCloseRequest(quote));
    }

    function quoteCurrentAssets() external view override returns (uint256 assets, bool healthy) {
        assets = IERC20(asset).balanceOf(address(sleeve));
        uint256 ptBalance = IERC20(ptToken).balanceOf(address(sleeve));
        if (ptBalance == 0) return (assets, true);

        uint256 rate = IPendleStaticQuoter(helper).getPtToAssetRate(market);
        if (rate == 0) return (assets, false);

        uint256 ptAssets = ptBalance * rate / WAD;
        return (assets + ptAssets, true);
    }

    function quoteUnloopForAssets(uint256 requestedAssets) public view returns (PTLoopUnloopQuote memory quote) {
        if (requestedAssets == 0) return quote;

        uint256 grossAssetTarget = _mulDivUp(requestedAssets, BPS, BPS - maxUnwindSlippageBps);
        uint256 ptBalance = IERC20(ptToken).balanceOf(address(sleeve));
        if (ptBalance == 0) revert InsufficientLocalLiquidity();

        uint256 exactPtIn = _quoteExactPtInForAssets(grossAssetTarget, ptBalance);
        (uint256 expectedAssetOut,,,,) = IPendleStaticQuoter(helper).swapExactPtForTokenStatic(market, exactPtIn, asset);

        quote = PTLoopUnloopQuote({
            requestedAssets: requestedAssets,
            grossAssetTarget: grossAssetTarget,
            expectedAssetOut: expectedAssetOut,
            ptBalance: ptBalance,
            exactPtIn: exactPtIn
        });
    }

    function planWithdrawal(uint256 idleAssets, uint256 requestedAssets, uint256 localLoopAssets)
        external
        pure
        returns (PTLoopUnwindPlan memory)
    {
        uint256 shortfallAssets = requestedAssets > idleAssets ? requestedAssets - idleAssets : 0;
        if (shortfallAssets == 0) {
            return PTLoopUnwindPlan({
                idleAssets: idleAssets,
                requestedAssets: requestedAssets,
                shortfallAssets: 0,
                localReductionAssets: 0,
                releaseableAssets: 0,
                unmetAssets: 0,
                requiresEmergencyExit: false
            });
        }

        uint256 totalReleasable = localLoopAssets;
        uint256 releaseableAssets = shortfallAssets > totalReleasable ? totalReleasable : shortfallAssets;
        uint256 unmetAssets = shortfallAssets - releaseableAssets;

        return PTLoopUnwindPlan({
            idleAssets: idleAssets,
            requestedAssets: requestedAssets,
            shortfallAssets: shortfallAssets,
            localReductionAssets: releaseableAssets,
            releaseableAssets: releaseableAssets,
            unmetAssets: unmetAssets,
            requiresEmergencyExit: unmetAssets > 0
        });
    }

    function withinUnwindSlippage(uint256 expectedAssets, uint256 actualAssets) external view returns (bool) {
        if (expectedAssets == 0) return actualAssets == 0;
        if (actualAssets >= expectedAssets) return true;

        uint256 slippageBps = (expectedAssets - actualAssets) * BPS / expectedAssets;
        return slippageBps <= maxUnwindSlippageBps;
    }

    function _quoteExactPtInForAssets(uint256 grossAssetTarget, uint256 ptBalance) internal view returns (uint256) {
        uint256 rate = IPendleStaticQuoter(helper).getPtToAssetRate(market);
        if (rate == 0) revert InsufficientLocalLiquidity();

        uint256 initialGuess = _mulDivUp(grossAssetTarget, WAD, rate);
        if (initialGuess == 0) initialGuess = 1;
        if (initialGuess > ptBalance) initialGuess = ptBalance;

        return _quotePtInForTargetAssetOut(grossAssetTarget, initialGuess, ptBalance);
    }

    function _quoteAutomaticAllocation() internal view returns (IUniversalAdapterEscrow.Call[] memory) {
        uint256 idleAssets = IERC20(asset).balanceOf(address(sleeve));
        if (idleAssets == 0) return new IUniversalAdapterEscrow.Call[](0);

        uint256 rate = IPendleStaticQuoter(helper).getPtToAssetRate(market);
        if (rate == 0) revert InsufficientLocalLiquidity();

        uint256 ptBalance = IERC20(ptToken).balanceOf(address(sleeve));
        uint256 totalAssets = idleAssets + (ptBalance * rate / WAD);
        uint256 allocatableAssets = availableToAllocate(idleAssets, totalAssets);
        if (allocatableAssets == 0) return new IUniversalAdapterEscrow.Call[](0);

        uint256 minPtOut = _quoteConservativeMinPtOut(allocatableAssets, rate);
        if (minPtOut == 0) revert InsufficientLocalLiquidity();

        PTLoopOpenRequest memory request = PTLoopOpenRequest({
            inputToken: asset,
            receiver: address(sleeve),
            market: market,
            minPtOut: minPtOut,
            guessPtOut: PendleLib.createDefaultApproxParams(),
            input: PendleLib.createTokenInputSimple(asset, allocatableAssets),
            limit: PendleLib.createEmptyLimitOrderData()
        });

        return PendleLib.buildOpenLoopCalls(venue, request);
    }

    function _automaticCloseRequest(PTLoopUnloopQuote memory quote) internal view returns (PTLoopCloseRequest memory) {
        return PTLoopCloseRequest({
            ptToken: ptToken,
            receiver: address(sleeve),
            market: market,
            exactPtIn: quote.exactPtIn,
            output: PendleLib.createTokenOutputSimple(asset, quote.requestedAssets),
            limit: PendleLib.createEmptyLimitOrderData()
        });
    }

    function _buildCloseLoopCalls(PTLoopCloseRequest memory request)
        internal
        view
        returns (IUniversalAdapterEscrow.Call[] memory)
    {
        return PendleLib.buildCloseLoopCalls(venue, request);
    }

    function _quoteConservativeMinPtOut(uint256 assetIn, uint256 rate) internal view returns (uint256 minPtOut) {
        uint256 targetAssetOut = assetIn * (BPS - maxEntrySlippageBps) / BPS;
        if (targetAssetOut == 0) revert InsufficientLocalLiquidity();

        uint256 initialGuess = _mulDivUp(targetAssetOut, WAD, rate);
        if (initialGuess == 0) initialGuess = 1;

        return _quotePtInForTargetAssetOut(targetAssetOut, initialGuess, type(uint256).max);
    }

    function _quotePtInForTargetAssetOut(uint256 targetAssetOut, uint256 initialGuess, uint256 maxPtIn)
        internal
        view
        returns (uint256 ptIn)
    {
        uint256 low;
        uint256 high = initialGuess;

        while (true) {
            (uint256 netTokenOut,,,,) = IPendleStaticQuoter(helper).swapExactPtForTokenStatic(market, high, asset);
            if (netTokenOut >= targetAssetOut) break;

            low = high;
            if (high == maxPtIn) revert InsufficientLocalLiquidity();

            uint256 nextHigh = high * 2;
            if (nextHigh <= high) revert InsufficientLocalLiquidity();
            high = nextHigh > maxPtIn ? maxPtIn : nextHigh;
        }

        while (low + 1 < high) {
            uint256 mid = low + (high - low) / 2;
            (uint256 netTokenOut,,,,) = IPendleStaticQuoter(helper).swapExactPtForTokenStatic(market, mid, asset);
            if (netTokenOut >= targetAssetOut) {
                high = mid;
            } else {
                low = mid;
            }
        }

        return high;
    }

    function _automationFlags() internal pure returns (uint256) {
        return 3;
    }

    function _settlementQueue() internal view returns (address queue) {
        return ControllerLiquidityLib.settlementQueue(address(sleeve));
    }

    function _mulDivUp(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256) {
        return x == 0 || y == 0 ? 0 : (x * y - 1) / denominator + 1;
    }
}
