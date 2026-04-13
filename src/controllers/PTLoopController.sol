// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {BaseStrategyController} from "./BaseStrategyController.sol";
import {IUniversalAdapterEscrow} from "../adapters/interfaces/IUniversalAdapterEscrow.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IAutomatedWithdrawalController} from "./interfaces/IAutomatedWithdrawalController.sol";
import {IOnchainStrategyValuer} from "./interfaces/IOnchainStrategyValuer.sol";
import {
    PendleLib,
    IPendleStaticQuoter,
    PTLoopOpenRequest,
    PTLoopCloseRequest
} from "./venue_specific/pendle/PendleLib.sol";
import {
    StrategyKind,
    PTLoopAutomationConfig,
    PTLoopUnwindPlan,
    PTLoopUnloopQuote,
    ChainManifest,
    VenueConfig
} from "../strategies/StrategyTypes.sol";

contract PTLoopController is BaseStrategyController, IAutomatedWithdrawalController, IOnchainStrategyValuer {
    uint256 internal constant WAD = 1e18;

    bytes32 public constant PENDLE_VENUE_ID = keccak256("PENDLE");

    error InvalidVenue();
    error InvalidSlippageConfig();
    error InvalidMarketConfig();
    error InsufficientLocalLiquidity();
    error AutomaticSyncUnavailable();

    uint256 public immutable maxEntrySlippageBps;
    uint256 public immutable maxUnwindSlippageBps;
    address public immutable market;
    address public immutable ptToken;

    constructor(
        address owner_,
        address vaultManager_,
        address vault_,
        address sleeve_,
        address remotePpsSnapshotStore_,
        address market_,
        address ptToken_,
        bytes32 strategyId_,
        uint256 targetReserveBps_,
        uint256 minReserveBps_,
        VenueConfig memory venueConfig_,
        ChainManifest[] memory chainManifests_,
        PTLoopAutomationConfig memory automationConfig_,
        uint256 maxUnwindSlippageBps_
    )
        BaseStrategyController(
            StrategyKind.PTLoop,
            owner_,
            vaultManager_,
            vault_,
            sleeve_,
            remotePpsSnapshotStore_,
            strategyId_,
            targetReserveBps_,
            minReserveBps_,
            venueConfig_,
            chainManifests_
        )
    {
        if (venueConfig_.venueId != PENDLE_VENUE_ID || venueConfig_.venue == address(0)) revert InvalidVenue();
        if (maxUnwindSlippageBps_ > BPS || automationConfig_.maxEntrySlippageBps > BPS) revert InvalidSlippageConfig();
        if (venueConfig_.helper == address(0) || market_ == address(0) || ptToken_ == address(0)) {
            revert InvalidMarketConfig();
        }

        maxEntrySlippageBps = automationConfig_.maxEntrySlippageBps;
        maxUnwindSlippageBps = maxUnwindSlippageBps_;
        market = market_;
        ptToken = ptToken_;
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
        if (_hasRemoteChain()) revert AutomaticSyncUnavailable();
        if (shortfallAssets == 0) return new IUniversalAdapterEscrow.Call[](0);

        PTLoopUnloopQuote memory quote = quoteUnloopForAssets(shortfallAssets);
        return _buildCloseLoopCalls(_automaticCloseRequest(quote));
    }

    function quoteCurrentAssets() external view override returns (uint256 assets, bool healthy) {
        assets = IERC20(asset).balanceOf(address(sleeve));
        (uint256 remoteAssets, bool remoteHealthy) = _quoteRemoteAssets();
        uint256 ptBalance = IERC20(ptToken).balanceOf(address(sleeve));
        if (ptBalance == 0) return (assets + remoteAssets, remoteHealthy);

        try IPendleStaticQuoter(helper).swapExactPtForTokenStatic(market, ptBalance, asset) returns (
            uint256 netTokenOut,
            uint256,
            uint256,
            uint256,
            uint256
        ) {
            return (assets + netTokenOut + remoteAssets, remoteHealthy);
        } catch {
            return (assets + remoteAssets, false);
        }
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

    function withinUnwindSlippage(uint256 expectedAssets, uint256 actualAssets) external view returns (bool) {
        if (expectedAssets == 0) return actualAssets == 0;
        if (actualAssets >= expectedAssets) return true;

        uint256 slippageBps = (expectedAssets - actualAssets) * BPS / expectedAssets;
        return slippageBps <= maxUnwindSlippageBps;
    }

    function planWithdrawal(
        uint256 idleAssets,
        uint256 requestedAssets,
        uint256 localLoopAssets,
        uint256 remoteLoopAssets
    ) external pure returns (PTLoopUnwindPlan memory) {
        uint256 shortfallAssets = requestedAssets > idleAssets ? requestedAssets - idleAssets : 0;
        if (shortfallAssets == 0) {
            return PTLoopUnwindPlan({
                idleAssets: idleAssets,
                requestedAssets: requestedAssets,
                shortfallAssets: 0,
                localReductionAssets: 0,
                remoteReductionAssets: 0,
                releaseableAssets: 0,
                unmetAssets: 0,
                requiresLayerZero: false,
                requiresEmergencyExit: false
            });
        }

        uint256 totalReleasable = localLoopAssets + remoteLoopAssets;
        uint256 releaseableAssets = shortfallAssets > totalReleasable ? totalReleasable : shortfallAssets;
        uint256 unmetAssets = shortfallAssets - releaseableAssets;

        uint256 localReductionAssets;
        uint256 remoteReductionAssets;

        if (releaseableAssets > 0 && totalReleasable > 0) {
            localReductionAssets = releaseableAssets * localLoopAssets / totalReleasable;
            remoteReductionAssets = releaseableAssets - localReductionAssets;

            if (remoteReductionAssets > remoteLoopAssets) {
                remoteReductionAssets = remoteLoopAssets;
                localReductionAssets = releaseableAssets - remoteReductionAssets;
            }
        }

        return PTLoopUnwindPlan({
            idleAssets: idleAssets,
            requestedAssets: requestedAssets,
            shortfallAssets: shortfallAssets,
            localReductionAssets: localReductionAssets,
            remoteReductionAssets: remoteReductionAssets,
            releaseableAssets: releaseableAssets,
            unmetAssets: unmetAssets,
            requiresLayerZero: remoteReductionAssets > 0,
            requiresEmergencyExit: unmetAssets > 0
        });
    }

    function _quoteExactPtInForAssets(uint256 grossAssetTarget, uint256 ptBalance) internal view returns (uint256) {
        uint256 rate = IPendleStaticQuoter(helper).getPtToAssetRate(market);
        if (rate == 0) revert InsufficientLocalLiquidity();

        uint256 high = _mulDivUp(grossAssetTarget, WAD, rate);
        if (high == 0) high = 1;
        if (high > ptBalance) high = ptBalance;

        while (high < ptBalance) {
            (uint256 netTokenOut,,,,) = IPendleStaticQuoter(helper).swapExactPtForTokenStatic(market, high, asset);
            if (netTokenOut >= grossAssetTarget) break;
            uint256 nextHigh = high * 2;
            high = nextHigh > ptBalance ? ptBalance : nextHigh;
        }

        (uint256 maxTokenOut,,,,) = IPendleStaticQuoter(helper).swapExactPtForTokenStatic(market, high, asset);
        if (maxTokenOut < grossAssetTarget) revert InsufficientLocalLiquidity();

        uint256 low;
        while (low < high) {
            uint256 mid = low + (high - low) / 2;
            (uint256 netTokenOut,,,,) = IPendleStaticQuoter(helper).swapExactPtForTokenStatic(market, mid, asset);
            if (netTokenOut >= grossAssetTarget) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        return low;
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

        uint256 expectedPtOut = allocatableAssets * WAD / rate;
        uint256 minPtOut = expectedPtOut * (BPS - maxEntrySlippageBps) / BPS;
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

    function _autoUnwindEnabled() internal pure override returns (bool) {
        return true;
    }

    function _autoAllocationEnabled() internal pure override returns (bool) {
        return true;
    }

    function _hasRemoteChain() internal view returns (bool hasRemote) {
        for (uint256 i; i < _chainManifests.length; i++) {
            if (!_chainManifests[i].isHomeChain) return true;
        }
    }

    function _mulDivUp(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256) {
        return x == 0 || y == 0 ? 0 : (x * y - 1) / denominator + 1;
    }
}
