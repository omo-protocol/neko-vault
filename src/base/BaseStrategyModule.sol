// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IBaseStrategyModule} from "./IBaseStrategyModule.sol";
import {SafeERC20Lib} from "../libraries/SafeERC20Lib.sol";

interface IBaseCctpSender {
    function bridge(bytes32 destinationRef, uint256 amount) external returns (bytes32);
}

interface IUniversalAdapterSettlement {
    function recordSettlement(bytes32 strategyId, uint256 assetsReceived) external;
}

/// @title BaseStrategyModule
/// @notice Narrow execution module called only by BaseExecutionGateway.
///         Forwards top-up amounts from a configured `bufferSource` (the sleeve, or a
///         pre-funded module balance) to the configured PM/HL funding rails.
///         Exposes only the three allowlisted methods — no arbitrary-call surface,
///         no delegatecall, no generic target/data execution.
contract BaseStrategyModule is IBaseStrategyModule {
    error NotGateway();
    error NotOwner();
    error InvalidAddress();
    error AmountZero();
    error DeploymentsPaused();
    error InsufficientBalance();
    error CycleAlreadyConsumed();
    error CctpSenderNotSet();
    error AlreadyInitialized();

    event TopUpPm(bytes32 indexed cycleId, uint256 amount, bytes32 destinationRef, bytes32 payloadHash);
    event TopUpHl(bytes32 indexed cycleId, uint256 amount, bytes32 destinationRef, bytes32 payloadHash);
    event ReserveRefilled(bytes32 indexed cycleId, uint256 amount, bytes32 destinationRef, bytes32 payloadHash);
    event DeploymentsPausedSet(bytes32 indexed cycleId, bool paused);
    event BufferSourceSet(address indexed src);
    event RefillSourceSet(address indexed src);
    event VaultSet(address indexed v);
    event GatewaySet(address indexed gateway);
    event CctpSenderSet(address indexed sender);
    event CctpBridged(bytes32 indexed cycleId, bytes32 indexed destinationRef, uint256 amount);

    bool internal _initialized;
    address public asset;
    address public owner;
    address public gateway;
    /// @notice Source of USDC for OUTBOUND top-ups. Typically the sleeve.
    ///         Module pulls from here via transferFrom (if non-self) during `_topUp`.
    address public bufferSource;
    /// @notice Source of USDC for INBOUND refills. Typically this module itself — the adapter
    ///         CCTP-mints USDC from HyperEVM/Polygon back to this module's Base address after
    ///         closing venue positions. `refillReserve` then transfers from here to the vault.
    ///         If zero, falls back to `bufferSource`.
    address public refillSource;
    address public vault;
    /// @notice Sleeve address for settlement — when module is registered as the sleeve's
    ///         settlement queue, `refillReserve` pushes inbound USDC into sleeve via
    ///         `recordSettlement` (proper accounting — reduces externalDeposits[strategyId]).
    address public sleeve;
    /// @notice Strategy id tied to this module; required for ISettlementQueueValidation.
    bytes32 public strategyId;
    /// @notice CCTP V2 router. All top-ups bridge through this contract via Circle's
    ///         burn/mint. No legacy direct-transfer fallback.
    address public cctpSender;
    bool public deploymentsPaused;
    mapping(bytes32 => bool) public consumedCycles;

    modifier onlyGateway() {
        if (msg.sender != gateway) revert NotGateway();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Sentinel constructor. Marks the template as initialized so it can't be used
    ///         directly; clones call `initialize` after CREATE2.
    constructor() {
        _initialized = true;
    }

    /// @notice One-time init for EIP-1167 clones. Same logic as the old constructor.
    function initialize(address owner_, address asset_, address bufferSource_) external {
        if (_initialized) revert AlreadyInitialized();
        if (owner_ == address(0) || asset_ == address(0)) revert InvalidAddress();
        _initialized = true;
        owner = owner_;
        asset = asset_;
        bufferSource = bufferSource_;
        emit BufferSourceSet(bufferSource_);
    }

    function setGateway(address newGateway) external onlyOwner {
        if (newGateway == address(0)) revert InvalidAddress();
        gateway = newGateway;
        emit GatewaySet(newGateway);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        owner = newOwner;
    }

    function setVault(address v) external onlyOwner {
        if (v == address(0)) revert InvalidAddress();
        vault = v;
        emit VaultSet(v);
    }

    function setBufferSource(address src) external onlyOwner {
        bufferSource = src;
        emit BufferSourceSet(src);
    }

    function setSleeveAndStrategyId(address sleeve_, bytes32 strategyId_) external onlyOwner {
        if (sleeve_ == address(0)) revert InvalidAddress();
        sleeve = sleeve_;
        strategyId = strategyId_;
    }

    function setRefillSource(address src) external onlyOwner {
        refillSource = src;
        emit RefillSourceSet(src);
    }

    function setCctpSender(address sender) external onlyOwner {
        cctpSender = sender;
        emit CctpSenderSet(sender);
    }

    function topUpPmBuffer(uint256 amount, bytes32 destinationRef, bytes32 payloadHash, bytes32 cycleId)
        external
        override
        onlyGateway
    {
        _topUp(amount, destinationRef, cycleId);
        emit TopUpPm(cycleId, amount, destinationRef, payloadHash);
    }

    function topUpHlBuffer(uint256 amount, bytes32 destinationRef, bytes32 payloadHash, bytes32 cycleId)
        external
        override
        onlyGateway
    {
        _topUp(amount, destinationRef, cycleId);
        emit TopUpHl(cycleId, amount, destinationRef, payloadHash);
    }

    function pauseDeployments(bytes32 cycleId) external override onlyGateway {
        if (consumedCycles[cycleId]) revert CycleAlreadyConsumed();
        consumedCycles[cycleId] = true;
        deploymentsPaused = true;
        emit DeploymentsPausedSet(cycleId, true);
    }

    /// @notice Move USDC from bufferSource back to the vault's reserve. Called by the gateway
    ///         after an unwind cycle where venue positions were closed and USDC was bridged back.
    ///         Unlike top-ups, this command is NOT gated by `deploymentsPaused` — restoring reserve
    ///         must work even during a PAUSE for user redemptions to succeed.
    function refillReserve(uint256 amount, bytes32 destinationRef, bytes32 payloadHash, bytes32 cycleId)
        external
        override
        onlyGateway
    {
        if (sleeve == address(0)) revert InvalidAddress();
        if (amount == 0) revert AmountZero();
        if (consumedCycles[cycleId]) revert CycleAlreadyConsumed();
        consumedCycles[cycleId] = true;

        // Push inbound USDC (from CCTP mint) into sleeve, then let sleeve settle accounting.
        // `recordSettlement` reduces externalDeposits[strategyId] — reflects that external
        // venue positions returned funds, so the sleeve's "off-site" balance shrinks.
        address src = refillSource != address(0) ? refillSource : address(this);
        if (src == address(this)) {
            SafeERC20Lib.safeTransfer(asset, sleeve, amount);
        } else {
            SafeERC20Lib.safeTransferFrom(asset, src, sleeve, amount);
        }
        IUniversalAdapterSettlement(sleeve).recordSettlement(strategyId, amount);
        emit ReserveRefilled(cycleId, amount, destinationRef, payloadHash);
    }

    /// @notice Owner-only unpause. Pause is a one-way trip via gateway; recovery is operator-gated.
    function unpauseDeployments() external onlyOwner {
        deploymentsPaused = false;
        emit DeploymentsPausedSet(bytes32(0), false);
    }

    /// @notice Sweep excess USDC held by the module (from CCTP-returns beyond what was requested
    ///         via `refillReserve`, or operator over-funding) directly to the vault. Owner-only.
    function sweepExcessToVault(uint256 amount) external onlyOwner {
        if (vault == address(0)) revert InvalidAddress();
        if (amount == 0) revert AmountZero();
        SafeERC20Lib.safeTransfer(asset, vault, amount);
    }

    function _topUp(uint256 amount, bytes32 destinationRef, bytes32 cycleId) internal {
        if (deploymentsPaused) revert DeploymentsPaused();
        if (amount == 0) revert AmountZero();
        if (consumedCycles[cycleId]) revert CycleAlreadyConsumed();
        consumedCycles[cycleId] = true;

        address sender = cctpSender;
        if (sender == address(0)) revert CctpSenderNotSet();

        address src = bufferSource;
        if (src == address(0) || src == address(this)) {
            SafeERC20Lib.safeTransfer(asset, sender, amount);
        } else {
            SafeERC20Lib.safeTransferFrom(asset, src, sender, amount);
        }
        IBaseCctpSender(sender).bridge(destinationRef, amount);
        emit CctpBridged(cycleId, destinationRef, amount);
    }
}
