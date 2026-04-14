// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IUniversalAdapterEscrow} from "../adapters/interfaces/IUniversalAdapterEscrow.sol";
import {IVaultV2} from "../interfaces/IVaultV2.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {
    IAutomatedWithdrawalController,
    IOnchainStrategyValuer,
    IRemotePpsSnapshotStore
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
    ChainManifest,
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
    error InvalidChainManifest();
    error InvalidVenue();
    error InvalidSlippageConfig();
    error InvalidMarketConfig();
    error InsufficientLocalLiquidity();
    error AutomaticSyncUnavailable();

    event LiquidityPrepared(uint256 minBalanceIncrease, uint256 deallocatedAssets, bool usedProtocolWithdraw);

    address public owner;
    address public vaultManager;
    IVaultV2 public vault;
    IUniversalAdapterEscrow public sleeve;
    address public remotePpsSnapshotStore;
    address public asset;
    bytes32 public strategyId;
    uint256 public targetReserveBps;
    bytes32 public venueId;
    address public venue;
    address public helper;
    bool public venueUsesLayerZero;

    uint256 public maxEntrySlippageBps;
    uint256 public maxUnwindSlippageBps;
    address public market;
    address public ptToken;
    bool private _initialized;

    ChainManifest[] internal _chainManifests;

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
        address remotePpsSnapshotStore_,
        address market_,
        address ptToken_,
        bytes32 strategyId_,
        uint256 targetReserveBps_,
        VenueConfig memory venueConfig_,
        ChainManifest[] memory chainManifests_,
        PTLoopAutomationConfig memory automationConfig_,
        uint256 maxUnwindSlippageBps_
    ) {
        if (
            owner_ == address(0) && vaultManager_ == address(0) && vault_ == address(0) && sleeve_ == address(0)
                && remotePpsSnapshotStore_ == address(0) && market_ == address(0) && ptToken_ == address(0)
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
            remotePpsSnapshotStore_,
            market_,
            ptToken_,
            strategyId_,
            targetReserveBps_,
            venueConfig_,
            chainManifests_,
            automationConfig_,
            maxUnwindSlippageBps_
        );
    }

    function initialize(
        address owner_,
        address vaultManager_,
        address vault_,
        address sleeve_,
        address remotePpsSnapshotStore_,
        address market_,
        address ptToken_,
        bytes32 strategyId_,
        uint256 targetReserveBps_,
        VenueConfig memory venueConfig_,
        ChainManifest[] memory chainManifests_,
        PTLoopAutomationConfig memory automationConfig_,
        uint256 maxUnwindSlippageBps_
    ) external {
        _initialize(
            owner_,
            vaultManager_,
            vault_,
            sleeve_,
            remotePpsSnapshotStore_,
            market_,
            ptToken_,
            strategyId_,
            targetReserveBps_,
            venueConfig_,
            chainManifests_,
            automationConfig_,
            maxUnwindSlippageBps_
        );
    }

    function _initialize(
        address owner_,
        address vaultManager_,
        address vault_,
        address sleeve_,
        address remotePpsSnapshotStore_,
        address market_,
        address ptToken_,
        bytes32 strategyId_,
        uint256 targetReserveBps_,
        VenueConfig memory venueConfig_,
        ChainManifest[] memory chainManifests_,
        PTLoopAutomationConfig memory automationConfig_,
        uint256 maxUnwindSlippageBps_
    ) internal {
        if (_initialized) revert NotOwner();
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

        _initialized = true;
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

        uint256 rate = IPendleStaticQuoter(helper).getPtToAssetRate(market);
        if (rate == 0) return (assets + remoteAssets, false);

        uint256 ptAssets = ptBalance * rate / WAD;
        return (assets + ptAssets + remoteAssets, remoteHealthy);
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
        return ControllerLiquidityLib.settlementQueue(address(sleeve));
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
