// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {CrossVenueCommandLib} from "./CrossVenueCommandLib.sol";
import {IBaseStrategyModule} from "./IBaseStrategyModule.sol";

/// @title BaseExecutionGateway
/// @notice The only public entrypoint for Ritual-origin capital-export commands on Base.
///         Verifies M-of-N quorum signatures over an EIP-712 CommandEnvelope, enforces
///         nonce / deadline / cycle replay protection, per-command and per-day caps, then
///         dispatches to the BaseStrategyModule via a hardcoded function allowlist.
///         Commands are restricted to TOPUP_PM_BUFFER, TOPUP_HL_BUFFER, and PAUSE.
///         Arbitrary-call surfaces (execute / call / delegatecall) are explicitly forbidden.
contract BaseExecutionGateway {
    using CrossVenueCommandLib for CrossVenueCommandLib.CommandEnvelope;

    // ─── Errors ──────────────────────────────────────────────────────────────

    error NotOwner();
    error AlreadyInitialized();
    error InvalidAddress();
    error WrongVault();
    error WrongAsset();
    error EnvelopeExpired();
    error NonceAlreadyUsed();
    error CycleAlreadyConsumed();
    error InsufficientSignatures();
    error DuplicateSigner();
    error UnknownCommandType();
    error AmountAboveCommandCap();
    error AmountAboveDailyCap();
    error Paused();
    error InvalidThreshold();

    // ─── Events ──────────────────────────────────────────────────────────────

    event CommandExecuted(
        bytes32 indexed cycleId,
        CrossVenueCommandLib.CommandType indexed commandType,
        uint256 amount,
        bytes32 destinationRef,
        bytes32 indexed envelopeHash
    );
    event SignerSet(address indexed signer, bool authorized);
    event ThresholdSet(uint256 threshold);
    event CommandCapSet(CrossVenueCommandLib.CommandType indexed commandType, uint256 cap);
    event DailyCapSet(uint256 cap);
    event PausedSet(bool paused);
    event ModuleSet(address indexed module);

    // ─── Storage (was partially immutable; made mutable for EIP-1167 clones) ─

    bool internal _initialized;
    address public vault;
    address public asset;
    bytes32 public DOMAIN_SEPARATOR;

    address public owner;
    address public module;

    uint256 public threshold;
    mapping(address => bool) public isSigner;
    uint256 public signerCount;

    mapping(uint256 => bool) public usedNonces;
    mapping(bytes32 => bool) public usedCycles;

    mapping(uint8 => uint256) public commandCap;
    uint256 public dailyCap;
    uint256 public dailyWindowStart;
    uint256 public dailyConsumed;

    bool public paused;

    // ─── Modifiers ───────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor() {
        _initialized = true;
    }

    /// @notice One-time init for EIP-1167 clones. DOMAIN_SEPARATOR is computed per-clone
    ///         from `address(this)`, so it differs between clones of the same template.
    function initialize(
        address owner_,
        address vault_,
        address asset_,
        address module_,
        string calldata name_,
        string calldata version_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        if (owner_ == address(0) || vault_ == address(0) || asset_ == address(0) || module_ == address(0)) {
            revert InvalidAddress();
        }
        _initialized = true;
        owner = owner_;
        vault = vault_;
        asset = asset_;
        module = module_;
        DOMAIN_SEPARATOR = CrossVenueCommandLib.domainSeparator(name_, version_, address(this));
        threshold = 1;
        emit ModuleSet(module_);
        emit ThresholdSet(1);
    }

    // ─── Admin ───────────────────────────────────────────────────────────────

    function setSigner(address signer, bool authorized) external onlyOwner {
        if (signer == address(0)) revert InvalidAddress();
        bool was = isSigner[signer];
        if (was == authorized) return;
        isSigner[signer] = authorized;
        if (authorized) signerCount += 1;
        else signerCount -= 1;
        emit SignerSet(signer, authorized);
    }

    function setThreshold(uint256 newThreshold) external onlyOwner {
        if (newThreshold == 0 || newThreshold > signerCount) revert InvalidThreshold();
        threshold = newThreshold;
        emit ThresholdSet(newThreshold);
    }

    function setCommandCap(CrossVenueCommandLib.CommandType commandType, uint256 cap) external onlyOwner {
        commandCap[uint8(commandType)] = cap;
        emit CommandCapSet(commandType, cap);
    }

    function setDailyCap(uint256 cap) external onlyOwner {
        dailyCap = cap;
        emit DailyCapSet(cap);
    }

    function setPaused(bool p) external onlyOwner {
        paused = p;
        emit PausedSet(p);
    }

    function setModule(address newModule) external onlyOwner {
        if (newModule == address(0)) revert InvalidAddress();
        module = newModule;
        emit ModuleSet(newModule);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        owner = newOwner;
    }

    // ─── Execute ─────────────────────────────────────────────────────────────

    /// @notice Verify quorum and dispatch to the allowlisted module function.
    /// @param env The signed command envelope.
    /// @param sigs One signature per quorum member; must be sorted by signer to prevent dup-sig replay.
    function executeCommand(CrossVenueCommandLib.CommandEnvelope calldata env, bytes[] calldata sigs) external {
        if (paused) revert Paused();
        if (env.dstVault != vault) revert WrongVault();
        if (env.asset != asset) revert WrongAsset();
        if (env.deadline < block.timestamp) revert EnvelopeExpired();
        // Replay protection: cycleId ONLY. Controller derives cycleId from
        // keccak256(strategyId, cycleSeq, block.number), and `nonce` from keccak256(cycleId,
        // cmd, destinationRef) — both deterministic and stateless. Using `usedNonces` as a
        // dedup mapping would be redundant with cycleId and fragile: an earlier counter-based
        // `nextNonce++` design could roll back the counter on Ritual tx revert while the async
        // HTTP precompile had already dispatched the envelope to the TEE, creating a permanent
        // lock at nonce=0. Now nonce is derived deterministically so retries produce the same
        // nonce, and cycleId carries the uniqueness guarantee.
        if (usedCycles[env.cycleId]) revert CycleAlreadyConsumed();

        bytes32 envHash = env.hashEnvelope();
        bytes32 d = CrossVenueCommandLib.digest(DOMAIN_SEPARATOR, envHash);
        _verifyQuorum(d, sigs);

        usedCycles[env.cycleId] = true;

        _enforceCaps(env.commandType, env.amount);
        _dispatch(env);

        emit CommandExecuted(env.cycleId, env.commandType, env.amount, env.destinationRef, envHash);
    }

    // ─── Internal ────────────────────────────────────────────────────────────

    function _verifyQuorum(bytes32 d, bytes[] calldata sigs) internal view {
        if (sigs.length < threshold) revert InsufficientSignatures();
        address last;
        uint256 valid;
        for (uint256 i = 0; i < sigs.length; i++) {
            address recovered = ECDSA.recover(d, sigs[i]);
            if (recovered <= last) revert DuplicateSigner();
            last = recovered;
            if (isSigner[recovered]) valid += 1;
        }
        if (valid < threshold) revert InsufficientSignatures();
    }

    function _enforceCaps(CrossVenueCommandLib.CommandType commandType, uint256 amount) internal {
        if (commandType == CrossVenueCommandLib.CommandType.PAUSE) return;

        uint256 cap = commandCap[uint8(commandType)];
        if (cap > 0 && amount > cap) revert AmountAboveCommandCap();

        // Daily cap only applies to outflows (top-ups). REFILL_RESERVE is an inflow and bypasses.
        if (commandType == CrossVenueCommandLib.CommandType.REFILL_RESERVE) return;

        if (dailyCap > 0) {
            if (block.timestamp >= dailyWindowStart + 1 days) {
                dailyWindowStart = block.timestamp;
                dailyConsumed = 0;
            }
            uint256 newConsumed = dailyConsumed + amount;
            if (newConsumed > dailyCap) revert AmountAboveDailyCap();
            dailyConsumed = newConsumed;
        }
    }

    function _dispatch(CrossVenueCommandLib.CommandEnvelope calldata env) internal {
        IBaseStrategyModule m = IBaseStrategyModule(module);
        if (env.commandType == CrossVenueCommandLib.CommandType.TOPUP_PM_BUFFER) {
            m.topUpPmBuffer(env.amount, env.destinationRef, env.payloadHash, env.cycleId);
        } else if (env.commandType == CrossVenueCommandLib.CommandType.TOPUP_HL_BUFFER) {
            m.topUpHlBuffer(env.amount, env.destinationRef, env.payloadHash, env.cycleId);
        } else if (env.commandType == CrossVenueCommandLib.CommandType.PAUSE) {
            m.pauseDeployments(env.cycleId);
        } else if (env.commandType == CrossVenueCommandLib.CommandType.REFILL_RESERVE) {
            m.refillReserve(env.amount, env.destinationRef, env.payloadHash, env.cycleId);
        } else {
            revert UnknownCommandType();
        }
    }
}
