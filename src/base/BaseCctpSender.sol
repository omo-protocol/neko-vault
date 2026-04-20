// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {SafeERC20Lib} from "../libraries/SafeERC20Lib.sol";
import {IERC20} from "../interfaces/IERC20.sol";

interface ITokenMessengerV2 {
    /// @notice CCTP V2 burn, plain variant.
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;

    /// @notice CCTP V2 burn with destination-side hook. The hook payload is passed to
    ///         `mintRecipient` (must be a contract implementing the CCTP hook interface — e.g.
    ///         Circle's CctpForwarder on HyperEVM for routing USDC to HyperCore).
    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external;
}

/// @title BaseCctpSender
/// @notice On-chain router that wraps Circle CCTP V2 for strategy top-ups. Per-`destinationRef`
///         routes pick the (destinationDomain, mintRecipient, fee cap, finality, hookData) tuple.
///         Fees are paid in USDC; no native fee balance needed.
///
///         Routes without `hookData` go to a plain EOA/contract as `mintRecipient` (e.g. our PM
///         API wallet on Polygon). Routes with `hookData` target Circle's CctpForwarder on a
///         destination chain (e.g. HyperEVM → HyperCore forwarding, hookData encodes the HL
///         trading wallet + destinationDex).
///
///         CCTP V2 domain IDs (partial): Ethereum=0, Avalanche=1, OP=2, Arbitrum=3, Base=6,
///         Polygon=7, HyperEVM=19. HyperCore itself isn't a CCTP domain — USDC lands at HyperEVM
///         and a Circle forwarder-hook credits HyperCore.
contract BaseCctpSender {
    error NotOwner();
    error NotAuthorized();
    error RouteInactive();
    error InvalidAddress();
    error AlreadyInitialized();

    event RouteConfigured(
        bytes32 indexed destinationRef,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bool hasHook,
        bool active
    );
    event AuthorizedCallerSet(address indexed caller, bool allowed);
    event CctpBurnTriggered(bytes32 indexed destinationRef, uint256 amount, uint256 maxFee);
    event OwnerSet(address indexed newOwner);

    struct Route {
        uint32 destinationDomain;
        bytes32 mintRecipient;
        uint256 maxFee;
        uint32 minFinalityThreshold;
        bytes hookData; // empty = plain depositForBurn; non-empty = depositForBurnWithHook
        bool active;
    }

    bool internal _initialized;
    address public asset;
    address public tokenMessenger;
    address public owner;
    mapping(address => bool) public authorizedCallers;
    mapping(bytes32 => Route) public routes;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        _initialized = true;
    }

    function initialize(address asset_, address tokenMessenger_, address owner_) external {
        if (_initialized) revert AlreadyInitialized();
        if (asset_ == address(0) || tokenMessenger_ == address(0) || owner_ == address(0)) revert InvalidAddress();
        _initialized = true;
        asset = asset_;
        tokenMessenger = tokenMessenger_;
        owner = owner_;
    }

    receive() external payable {}

    // ─── Admin ───────────────────────────────────────────────────────────────

    function setOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        owner = newOwner;
        emit OwnerSet(newOwner);
    }

    function setAuthorizedCaller(address caller, bool allowed) external onlyOwner {
        authorizedCallers[caller] = allowed;
        emit AuthorizedCallerSet(caller, allowed);
    }

    function configureRoute(bytes32 destinationRef, Route calldata r) external onlyOwner {
        if (r.mintRecipient == bytes32(0)) revert InvalidAddress();
        routes[destinationRef] = r;
        emit RouteConfigured(
            destinationRef,
            r.destinationDomain,
            r.mintRecipient,
            r.maxFee,
            r.minFinalityThreshold,
            r.hookData.length > 0,
            r.active
        );
    }

    function sweepNative(address to, uint256 amount) external onlyOwner {
        (bool ok,) = to.call{value: amount}("");
        require(ok, "native sweep failed");
    }

    function sweepToken(address token, address to, uint256 amount) external onlyOwner {
        SafeERC20Lib.safeTransfer(token, to, amount);
    }

    // ─── Bridge ──────────────────────────────────────────────────────────────

    /// @notice Burn `amount` USDC on Base via CCTP V2. Caller must have transferred `amount` here.
    ///         Returns `bytes32(0)` — CCTP emits the message nonce from MessageTransmitter; the
    ///         off-chain relayer indexes `MessageSent` and fetches Circle's attestation.
    function bridge(bytes32 destinationRef, uint256 amount) external returns (bytes32) {
        if (!authorizedCallers[msg.sender]) revert NotAuthorized();

        Route memory r = routes[destinationRef];
        if (!r.active) revert RouteInactive();

        IERC20(asset).approve(tokenMessenger, amount);

        if (r.hookData.length == 0) {
            ITokenMessengerV2(tokenMessenger).depositForBurn(
                amount,
                r.destinationDomain,
                r.mintRecipient,
                asset,
                bytes32(0),
                r.maxFee,
                r.minFinalityThreshold
            );
        } else {
            ITokenMessengerV2(tokenMessenger).depositForBurnWithHook(
                amount,
                r.destinationDomain,
                r.mintRecipient,
                asset,
                bytes32(0),
                r.maxFee,
                r.minFinalityThreshold,
                r.hookData
            );
        }

        emit CctpBurnTriggered(destinationRef, amount, r.maxFee);
        return bytes32(0);
    }
}
