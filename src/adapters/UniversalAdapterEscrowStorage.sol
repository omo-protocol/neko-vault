// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IVaultV2} from "../interfaces/IVaultV2.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";
import {IUniversalAdapterEscrow} from "./interfaces/IUniversalAdapterEscrow.sol";
import {IAutomatedWithdrawalController, IOnchainStrategyValuer} from "../controllers/StrategyControllerInterfaces.sol";
import {AdapterAccountingLib} from "./libraries/AdapterAccountingLib.sol";
import {ContractCodeCheckerLib} from "./libraries/ContractCodeCheckerLib.sol";
import {SafeERC20Lib} from "../libraries/SafeERC20Lib.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @notice Designed for single-strategy-per-sleeve deployments (enforced by CrossVenueStrategyVaultFactory).
/// Multi-strategy usage would double-count idle assets across per-strategy allocation tracking.
abstract contract UniversalAdapterEscrowStorage is IUniversalAdapterEscrow {
    using SafeERC20Lib for IERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using ContractCodeCheckerLib for address;
    /* CONSTANTS */

    bytes4 internal constant DEALLOCATE_SELECTOR = 0x4b219d16; // deallocate(address,bytes,uint256)
    bytes4 internal constant FORCE_DEALLOCATE_SELECTOR = 0xe4d38cd8; // forceDeallocate(address,bytes,uint256,address)
    bytes4 internal constant WITHDRAW_SELECTOR = bytes4(keccak256("withdraw(uint256,address,address)"));
    bytes4 internal constant REDEEM_SELECTOR = bytes4(keccak256("redeem(uint256,address,address)"));
    uint256 internal constant MAX_BALANCE_LOSS_BPS = 1000;
    uint256 internal constant MAX_AUTOMATION_CALLS = 64;
    uint256 internal constant AUTO_ALLOCATION_FLAG = 1;
    uint256 internal constant AUTO_WITHDRAW_FLAG = 2;
    uint256 internal constant MAX_AUTOMATION_FLAGS = AUTO_ALLOCATION_FLAG | AUTO_WITHDRAW_FLAG;
    uint256 internal constant MAX_CACHED_VALUATION_AGE = 4 hours;
    uint256 public constant EMERGENCY_HAIRCUT = 500; // 5% in basis points
    address public parentVault;
    address public asset;
    bool private _initialized;
    /* STORAGE */
    mapping(bytes32 => StrategyConfig) public strategies;
    mapping(bytes32 => uint256) public allocations;
    EnumerableSet.Bytes32Set internal activeStrategies;
    uint256 public totalAllocations;
    mapping(bytes32 => uint256) public externalDeposits;
    uint256 public totalExternalDeposits;
    uint256 public settlementSurplusAssets;
    uint256 internal cachedValuation;
    uint256 internal cachedValuationTimestamp;
    mapping(address => mapping(bytes4 => WhitelistConfig)) public functionWhitelist;
    mapping(address => bytes32) internal whitelistCodeHashes;
    bool public paused;
    address public owner;
    address public settlementQueue;
    bool public emergencyMode;
    uint256 public emergencyModeActivatedAt;
    bool private _locked;

    /* MODIFIERS */
    modifier onlyVault() {
        if (msg.sender != parentVault) revert NotAuthorized();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier onlySettlementQueue() {
        if (msg.sender != settlementQueue) revert NotAuthorized();
        _;
    }

    modifier notPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier onlyStrategyAgentOrOwner(bytes32 strategyId) {
        StrategyConfig memory strategy = strategies[strategyId];
        if (!strategy.active) revert StrategyNotActive();
        if (msg.sender != strategy.agent && msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier nonReentrant() {
        if (_locked) revert ReentrancyGuarded();
        _locked = true;
        _;
        _locked = false;
    }

    constructor(address _parentVault) {
        if (_parentVault == address(0)) {
            _initialized = true;
            return;
        }
        _initialize(_parentVault);
    }

    function initialize(address _parentVault) external {
        _initialize(_parentVault);
    }

    function _initialize(address _parentVault) internal {
        if (_initialized) revert NotAuthorized();
        if (_parentVault == address(0)) revert InvalidData();

        _initialized = true;
        parentVault = _parentVault;
        asset = IVaultV2(_parentVault).asset();
        owner = IVaultV2(_parentVault).owner();

        SafeERC20Lib.safeApprove(asset, _parentVault, type(uint256).max);
    }
}

interface ISettlementQueueValidation {
    function vault() external view returns (address);
    function sleeve() external view returns (address);
    function strategyId() external view returns (bytes32);
}