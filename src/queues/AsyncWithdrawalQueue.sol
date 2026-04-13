// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IVaultV2} from "../interfaces/IVaultV2.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IUniversalAdapterEscrow} from "../adapters/interfaces/IUniversalAdapterEscrow.sol";
import {IAsyncWithdrawalController} from "../controllers/StrategyControllerInterfaces.sol";
import {WithdrawalRequest, WithdrawalRequestStatus} from "../strategies/StrategyTypes.sol";

contract AsyncWithdrawalQueue is ReentrancyGuard {
    error NotOwner();
    error NotSettlementHook();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidRequest();
    error RequestNotClaimable();
    error DuplicateGuid();

    event WithdrawalRequested(
        uint256 indexed requestId,
        address indexed owner,
        address indexed receiver,
        uint256 sharesEscrowed,
        uint256 assetEstimate
    );
    event WithdrawalFunded(uint256 indexed requestId, uint256 assetsReceived, uint256 totalFunded, bytes32 guid);
    event WithdrawalClaimable(uint256 indexed requestId, uint256 currentAssetRequirement);
    event WithdrawalClaimed(
        uint256 indexed requestId, address indexed receiver, uint256 sharesBurned, uint256 assetsOut
    );
    event AsyncWithdrawalInitiated(uint256 indexed requestId, uint256 shortfallAssets, bool initiated);
    event SettlementHookSet(address indexed settlementHook);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    IVaultV2 public immutable vault;
    address public immutable controller;
    address public immutable sleeve;
    bytes32 public immutable strategyId;
    address public owner;
    address public settlementHook;
    uint256 public nextRequestId = 1;
    uint256 public totalReservedLocalAssets;
    uint256 public totalProtectedAssets;

    mapping(uint256 requestId => WithdrawalRequest request) internal _requests;
    mapping(bytes32 guid => bool seen) public processedGuids;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlySettlementHook() {
        if (msg.sender != settlementHook) revert NotSettlementHook();
        _;
    }

    constructor(address vault_, address controller_, address sleeve_, address owner_) {
        if (vault_ == address(0) || controller_ == address(0) || sleeve_ == address(0) || owner_ == address(0)) {
            revert InvalidAddress();
        }
        vault = IVaultV2(vault_);
        controller = controller_;
        sleeve = sleeve_;
        strategyId = IStrategyIdProvider(controller_).strategyId();
        owner = owner_;
    }

    function setSettlementHook(address settlementHook_) external onlyOwner {
        if (settlementHook_ == address(0)) revert InvalidAddress();
        settlementHook = settlementHook_;
        emit SettlementHookSet(settlementHook_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function requestRedeem(uint256 shares, address receiver) public nonReentrant returns (uint256 requestId) {
        if (shares == 0 || receiver == address(0)) revert InvalidAmount();

        requestId = nextRequestId++;
        uint256 assetEstimate = vault.previewRedeem(shares);
        uint256 reservedLocalAssets = _reserveLocalLiquidity(assetEstimate);
        IERC20(address(vault)).transferFrom(msg.sender, address(this), shares);

        _requests[requestId] = WithdrawalRequest({
            owner: msg.sender,
            receiver: receiver,
            sharesEscrowed: shares,
            assetEstimate: assetEstimate,
            reservedLocalAssets: reservedLocalAssets,
            assetsFunded: 0,
            createdAt: uint64(block.timestamp),
            status: reservedLocalAssets >= assetEstimate
                ? WithdrawalRequestStatus.Claimable
                : WithdrawalRequestStatus.Pending
        });
        totalProtectedAssets += reservedLocalAssets;

        emit WithdrawalRequested(requestId, msg.sender, receiver, shares, assetEstimate);
        if (reservedLocalAssets >= assetEstimate) {
            emit WithdrawalClaimable(requestId, assetEstimate);
        } else {
            uint256 shortfallAssets = assetEstimate - reservedLocalAssets;
            bool initiated = _tryInitiateAsyncWithdrawal(shortfallAssets);
            emit AsyncWithdrawalInitiated(requestId, shortfallAssets, initiated);
        }
    }

    function requestWithdraw(uint256 assets, address receiver) external returns (uint256 requestId) {
        if (assets == 0) revert InvalidAmount();
        requestId = requestRedeem(vault.previewWithdraw(assets), receiver);
    }

    function creditSettlement(uint256 requestId, uint256 assetsReceived, bytes32 guid)
        external
        onlySettlementHook
        nonReentrant
    {
        if (assetsReceived == 0) revert InvalidAmount();
        if (processedGuids[guid]) revert DuplicateGuid();

        WithdrawalRequest storage request = _requests[requestId];
        if (request.owner == address(0)) revert InvalidRequest();
        if (request.status == WithdrawalRequestStatus.Claimed || request.status == WithdrawalRequestStatus.Cancelled) {
            revert InvalidRequest();
        }

        processedGuids[guid] = true;
        request.assetsFunded += assetsReceived;
        totalProtectedAssets += assetsReceived;
        IUniversalAdapterEscrow(sleeve).recordSettlement(strategyId, assetsReceived);

        uint256 currentRequirement = vault.previewRedeem(request.sharesEscrowed);
        if (request.reservedLocalAssets + request.assetsFunded >= currentRequirement) {
            request.status = WithdrawalRequestStatus.Claimable;
            emit WithdrawalClaimable(requestId, currentRequirement);
        } else {
            request.status = WithdrawalRequestStatus.PartiallyFunded;
        }

        emit WithdrawalFunded(requestId, assetsReceived, request.assetsFunded, guid);
    }

    function claim(uint256 requestId) external nonReentrant returns (uint256 assetsOut) {
        WithdrawalRequest storage request = _requests[requestId];
        _refreshRequest(requestId, request);
        if (request.status != WithdrawalRequestStatus.Claimable) revert RequestNotClaimable();

        request.status = WithdrawalRequestStatus.Claimed;
        totalProtectedAssets -= request.reservedLocalAssets + request.assetsFunded;
        totalReservedLocalAssets -= request.reservedLocalAssets;
        request.reservedLocalAssets = 0;
        assetsOut = vault.redeem(request.sharesEscrowed, request.receiver, address(this));

        emit WithdrawalClaimed(requestId, request.receiver, request.sharesEscrowed, assetsOut);
    }

    function getRequest(uint256 requestId) external view returns (WithdrawalRequest memory) {
        return _requests[requestId];
    }

    function currentAssetRequirement(uint256 requestId) external view returns (uint256) {
        WithdrawalRequest storage request = _requests[requestId];
        if (request.owner == address(0)) revert InvalidRequest();
        return vault.previewRedeem(request.sharesEscrowed);
    }

    function refreshRequest(uint256 requestId) external nonReentrant returns (WithdrawalRequestStatus status) {
        WithdrawalRequest storage request = _requests[requestId];
        if (request.owner == address(0) || request.status == WithdrawalRequestStatus.Claimed) revert InvalidRequest();
        return _refreshRequest(requestId, request);
    }

    function _reserveLocalLiquidity(uint256 assetEstimate) internal returns (uint256 reserved) {
        uint256 liquidAssets = IERC20(vault.asset()).balanceOf(address(vault)) + IERC20(vault.asset()).balanceOf(sleeve);
        uint256 unreserved = liquidAssets > totalReservedLocalAssets ? liquidAssets - totalReservedLocalAssets : 0;
        reserved = assetEstimate < unreserved ? assetEstimate : unreserved;
        totalReservedLocalAssets += reserved;
    }

    function _refreshRequest(uint256 requestId, WithdrawalRequest storage request)
        internal
        returns (WithdrawalRequestStatus status)
    {
        uint256 currentRequirement = vault.previewRedeem(request.sharesEscrowed);
        if (_isClaimableByCurrentLiquidity(requestId)) {
            status = WithdrawalRequestStatus.Claimable;
            if (request.status != WithdrawalRequestStatus.Claimable) {
                emit WithdrawalClaimable(requestId, currentRequirement);
            }
        } else if (request.assetsFunded > 0 || request.reservedLocalAssets > 0) {
            status = WithdrawalRequestStatus.PartiallyFunded;
        } else {
            status = WithdrawalRequestStatus.Pending;
        }

        request.status = status;
    }

    function _isClaimableByCurrentLiquidity(uint256 requestId) internal view returns (bool) {
        uint256 availableLiquidity = _availableUnreservedLiquidity();

        for (uint256 i = 1; i <= requestId; i++) {
            WithdrawalRequest storage request = _requests[i];
            if (
                request.owner == address(0) || request.status == WithdrawalRequestStatus.Claimed
                    || request.status == WithdrawalRequestStatus.Cancelled
            ) continue;

            uint256 currentRequirement = vault.previewRedeem(request.sharesEscrowed);
            uint256 coveredLocally = request.reservedLocalAssets;
            if (coveredLocally >= currentRequirement) {
                if (i == requestId) return true;
                continue;
            }

            uint256 shortfall = currentRequirement - coveredLocally;
            if (availableLiquidity < shortfall) return false;
            availableLiquidity -= shortfall;

            if (i == requestId) return true;
        }

        revert InvalidRequest();
    }

    function _availableUnreservedLiquidity() internal view returns (uint256) {
        uint256 liquidAssets = IERC20(vault.asset()).balanceOf(address(vault)) + IERC20(vault.asset()).balanceOf(sleeve);
        return liquidAssets > totalReservedLocalAssets ? liquidAssets - totalReservedLocalAssets : 0;
    }

    function _tryInitiateAsyncWithdrawal(uint256 shortfallAssets) internal returns (bool initiated) {
        try IAsyncWithdrawalController(controller).initiateAsyncWithdrawal(shortfallAssets) returns (bool started) {
            return started;
        } catch {
            return false;
        }
    }
}

interface IStrategyIdProvider {
    function strategyId() external view returns (bytes32);
}
