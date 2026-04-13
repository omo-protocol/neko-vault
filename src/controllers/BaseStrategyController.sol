// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IVaultV2} from "../interfaces/IVaultV2.sol";
import {IUniversalAdapterEscrow} from "../adapters/interfaces/IUniversalAdapterEscrow.sol";
import {IRemotePpsSnapshotStore} from "./interfaces/IRemotePpsSnapshotStore.sol";
import {StrategyKind, StrategySpec, ChainManifest, VenueConfig} from "../strategies/StrategyTypes.sol";

abstract contract BaseStrategyController is ReentrancyGuard {
    uint256 internal constant BPS = 10_000;

    error NotOwner();
    error NotVaultManager();
    error InvalidAddress();
    error InvalidReserveConfig();
    error InvalidChainManifest();

    event LiquidityPrepared(uint256 minBalanceIncrease, uint256 deallocatedAssets, bool usedProtocolWithdraw);

    address public immutable owner;
    address public immutable vaultManager;
    IVaultV2 public immutable vault;
    IUniversalAdapterEscrow public immutable sleeve;
    address public immutable remotePpsSnapshotStore;
    address public immutable asset;
    bytes32 public immutable strategyId;
    StrategyKind public immutable strategyKind;
    uint256 public immutable targetReserveBps;
    uint256 public immutable minReserveBps;

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

    constructor(
        StrategyKind kind_,
        address owner_,
        address vaultManager_,
        address vault_,
        address sleeve_,
        address remotePpsSnapshotStore_,
        bytes32 strategyId_,
        uint256 targetReserveBps_,
        uint256 minReserveBps_,
        VenueConfig memory venueConfig_,
        ChainManifest[] memory chainManifests_
    ) {
        if (
            owner_ == address(0) || vaultManager_ == address(0) || vault_ == address(0) || sleeve_ == address(0)
                || strategyId_ == bytes32(0)
        ) {
            revert InvalidAddress();
        }
        if (targetReserveBps_ > BPS || minReserveBps_ > targetReserveBps_) revert InvalidReserveConfig();

        owner = owner_;
        vaultManager = vaultManager_;
        vault = IVaultV2(vault_);
        sleeve = IUniversalAdapterEscrow(sleeve_);
        remotePpsSnapshotStore = remotePpsSnapshotStore_;
        asset = IVaultV2(vault_).asset();
        strategyId = strategyId_;
        strategyKind = kind_;
        targetReserveBps = targetReserveBps_;
        minReserveBps = minReserveBps_;
        venueId = venueConfig_.venueId;
        venue = venueConfig_.venue;
        helper = venueConfig_.helper;
        venueUsesLayerZero = venueConfig_.usesLayerZero;

        _storeChainManifests(chainManifests_, sleeve_);
    }

    function getStrategySpec() external view returns (StrategySpec memory) {
        return StrategySpec({
            kind: strategyKind,
            asset: asset,
            strategyId: strategyId,
            targetReserveBps: targetReserveBps,
            minReserveBps: minReserveBps
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

    function _quoteRemoteAssets() internal view returns (uint256 assets, bool healthy) {
        if (remotePpsSnapshotStore == address(0)) return (0, true);
        return IRemotePpsSnapshotStore(remotePpsSnapshotStore).quoteRemoteAssets();
    }

    function reserveFloor(uint256 totalAssets) public view returns (uint256) {
        return totalAssets * minReserveBps / BPS;
    }

    function availableToAllocate(uint256 idleAssets, uint256 totalAssets) public view returns (uint256) {
        uint256 targetReserve = reserveTarget(totalAssets);
        if (idleAssets <= targetReserve) return 0;
        return idleAssets - targetReserve;
    }

    function liquidityData() public view virtual returns (bytes memory) {
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](0);
        return abi.encode(strategyId, _automationFlags(), _autoUnwindEnabled(), calls);
    }

    function allocateIdle(uint256 assets) external onlyOwner nonReentrant {
        vault.allocate(address(sleeve), liquidityData(), assets);
    }

    function deallocateToVault(uint256 assets) external onlyOwner nonReentrant {
        vault.deallocate(address(sleeve), liquidityData(), assets);
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

    function _autoUnwindEnabled() internal view virtual returns (bool) {
        return false;
    }

    function _autoAllocationEnabled() internal view virtual returns (bool) {
        return false;
    }

    function _automationFlags() internal view virtual returns (uint256 flags) {
        if (_autoAllocationEnabled()) flags |= 1;
        if (_autoUnwindEnabled()) flags |= 2;
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
}
