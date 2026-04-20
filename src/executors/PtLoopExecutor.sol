// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "../interfaces/IERC20.sol";

/// @title PtLoopExecutor
/// @notice Per-vault flash-loan sandwich executor for Pendle PT leverage loops. Chain-agnostic:
///         the same contract works on any EVM where Pendle + a flash-loan provider + a lending
///         market exist. Deployed as an EIP-1167 clone per vault by `PtLoopFactory`.
///
/// @dev Design:
///      - Implementation deployed once per chain. Each vault gets its own 45-byte EIP-1167 clone
///        with isolated storage (the clone IS the lending-market borrower-of-record, so each
///        vault's Silo/Morpho/Dolomite position is natively isolated by address).
///      - Chain constants (USDC, Pendle router, flash vault) set at `initialize`. Impl is
///        portable; operator deploys one factory per chain with the right constants.
///      - Lending venue is opaque: the adapter pre-builds all Pendle + lending calldata off-chain
///        and passes it in. Executor just sequences the calls atomically inside the flash-loan
///        callback. Works with Silo, Morpho, Dolomite, or any other venue that accepts calldata.
///      - Adapter server (relayer) signs enter/exit/rebalance calls as the `strategyAgent` EOA
///        (TEE-held per-vault PK). Operator is always the controller on Ritual (for ownership
///        rotation).
contract PtLoopExecutor {
    // ─── Errors ─────────────────────────────────────────────────────────────
    error AlreadyInitialized();
    error NotOwner();
    error NotStrategyAgent();
    error NotFlashCallback();
    error ZeroAddress();
    error BadLeverage();
    error SlippageHit();
    error InsufficientPtOut();
    error InsufficientUsdcOut();
    error ExternalCallFailed(bytes ret);

    // ─── Storage (EIP-1167 clone-isolated) ──────────────────────────────────

    bool internal _initialized;

    /// Chain-specific constants, set once at clone init by the factory.
    address public usdc;
    address public pendleRouter;
    address public flashVault;

    /// Per-vault permissions.
    address public owner;
    address public strategyAgent;

    // ─── Events ─────────────────────────────────────────────────────────────
    event Initialized(address indexed owner, address indexed strategyAgent);
    event StrategyAgentUpdated(address indexed agent);
    event OwnerUpdated(address indexed newOwner);
    event LoopEntered(
        address indexed pendleMarket,
        address indexed lendingVenue,
        uint256 baseUsdc,
        uint256 flashAmt,
        uint256 ptSupplied,
        uint256 usdcBorrowed,
        uint16 leverageBps
    );
    event LoopExited(
        address indexed pendleMarket,
        address indexed lendingVenue,
        uint256 debtRepaid,
        uint256 ptSold,
        uint256 usdcOut,
        address recipient
    );
    event LoopRebalanced(address indexed lendingVenue, int256 deltaUsdcNotional);

    // ─── Modifiers ──────────────────────────────────────────────────────────
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyStrategyAgent() {
        if (msg.sender != strategyAgent) revert NotStrategyAgent();
        _;
    }

    modifier onlyFlashCallback() {
        if (msg.sender != flashVault) revert NotFlashCallback();
        _;
    }

    // ─── Init ───────────────────────────────────────────────────────────────

    /// Block the impl from being init'd directly; sentinel for the EIP-1167 pattern.
    constructor() {
        _initialized = true;
    }

    /// Called once by the factory right after `Clones.cloneDeterministic`.
    function initialize(
        address usdc_,
        address pendleRouter_,
        address flashVault_,
        address owner_,
        address strategyAgent_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        if (
            usdc_ == address(0) || pendleRouter_ == address(0) || flashVault_ == address(0)
                || owner_ == address(0) || strategyAgent_ == address(0)
        ) revert ZeroAddress();
        _initialized = true;
        usdc = usdc_;
        pendleRouter = pendleRouter_;
        flashVault = flashVault_;
        owner = owner_;
        strategyAgent = strategyAgent_;
        emit Initialized(owner_, strategyAgent_);
    }

    function setStrategyAgent(address a) external onlyOwner {
        if (a == address(0)) revert ZeroAddress();
        strategyAgent = a;
        emit StrategyAgentUpdated(a);
    }

    function transferOwnership(address n) external onlyOwner {
        if (n == address(0)) revert ZeroAddress();
        owner = n;
        emit OwnerUpdated(n);
    }

    // ─── Enter / exit params ────────────────────────────────────────────────

    struct EnterParams {
        address pendleMarket;           // Pendle market contract (user-chosen)
        address lendingVenue;           // Silo / Morpho / Dolomite instance for this PT
        uint256 baseUsdc;               // USDC already held by this clone from CCTP mint
        uint256 flashAmt;               // USDC to flash-borrow = base × (L − 1) / 10_000
        uint256 minPtOut;               // slippage floor on USDC → PT swap
        uint16  leverageBps;            // for event emission
        bytes   pendleRouterCalldata;   // adapter-built USDC → PT swap
        bytes   lendingSupplyCalldata;  // adapter-built supply-collateral call
        bytes   lendingBorrowCalldata;  // adapter-built borrow(USDC, flashAmt + fee) call
    }

    struct ExitParams {
        address pendleMarket;
        address lendingVenue;
        uint256 debtUsdc;               // flash-borrow to repay lending debt
        uint256 minUsdcOut;             // slippage floor on PT → USDC swap
        address recipient;              // residual USDC destination (Base-bound CCTP sender)
        bytes   lendingRepayCalldata;
        bytes   lendingWithdrawCalldata;
        bytes   pendleRouterCalldata;
    }

    // ─── External entrypoints (strategy-agent gated) ───────────────────────

    function enterLoop(EnterParams calldata p) external onlyStrategyAgent {
        if (p.leverageBps < 10_000 || p.leverageBps > 100_000) revert BadLeverage();
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = usdc;
        amounts[0] = p.flashAmt;
        // Balancer's flashLoan(recipient=this, tokens, amounts, userData). On callback the clone
        // holds `flashAmt` USDC and must end up with `flashAmt + fee` to repay.
        IBalancerVault(flashVault).flashLoan(
            address(this), tokens, amounts, abi.encode(uint8(0), abi.encode(p))
        );
    }

    function exitLoop(ExitParams calldata p) external onlyStrategyAgent {
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = usdc;
        amounts[0] = p.debtUsdc;
        IBalancerVault(flashVault).flashLoan(
            address(this), tokens, amounts, abi.encode(uint8(1), abi.encode(p))
        );
    }

    /// Partial resize outside the flash-loan flow — adjust leverage by N% without re-doing the
    /// whole sandwich. Adapter builds `rebalanceCalldata` for the lending venue (e.g. a
    /// supplyOrBorrow delta). Use cases: drift rebalance, HF repair after depeg.
    function rebalanceLoop(
        address lendingVenue,
        int256 deltaUsdcNotional,
        bytes calldata rebalanceCalldata
    ) external onlyStrategyAgent {
        _call(lendingVenue, rebalanceCalldata);
        emit LoopRebalanced(lendingVenue, deltaUsdcNotional);
    }

    /// Balancer flash-loan callback. Dispatches to enter/exit handlers.
    function receiveFlashLoan(
        address[] calldata /* tokens */,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata userData
    ) external onlyFlashCallback {
        (uint8 op, bytes memory inner) = abi.decode(userData, (uint8, bytes));
        if (op == 0) {
            _handleEnter(abi.decode(inner, (EnterParams)), amounts[0], feeAmounts[0]);
        } else {
            _handleExit(abi.decode(inner, (ExitParams)), amounts[0], feeAmounts[0]);
        }
    }

    // ─── Atomic handlers (only reachable via flash callback) ───────────────

    function _handleEnter(EnterParams memory p, uint256 flashed, uint256 flashFee) internal {
        uint256 totalUsdc = p.baseUsdc + flashed;

        // 1. USDC → PT via Pendle router. Adapter-built calldata handles the internal aggregator
        //    (USDC → underlying → PT). The router's minPtOut check is our primary slippage gate;
        //    we re-check the balance below as a belt-and-suspenders.
        IERC20(usdc).approve(pendleRouter, totalUsdc);
        _call(pendleRouter, p.pendleRouterCalldata);

        (, address pt, ) = IPMarket(p.pendleMarket).readTokens();
        uint256 ptBal = IERC20(pt).balanceOf(address(this));
        if (ptBal < p.minPtOut) revert InsufficientPtOut();

        // 2. Supply PT as collateral.
        IERC20(pt).approve(p.lendingVenue, ptBal);
        _call(p.lendingVenue, p.lendingSupplyCalldata);

        // 3. Borrow USDC to cover flash repayment (+ fee). Adapter sizes the borrow amount.
        _call(p.lendingVenue, p.lendingBorrowCalldata);

        // 4. Repay flash.
        uint256 owed = flashed + flashFee;
        uint256 usdcBal = IERC20(usdc).balanceOf(address(this));
        if (usdcBal < owed) revert SlippageHit();
        IERC20(usdc).transfer(flashVault, owed);

        emit LoopEntered(
            p.pendleMarket, p.lendingVenue, p.baseUsdc, flashed, ptBal, usdcBal - owed, p.leverageBps
        );
    }

    function _handleExit(ExitParams memory p, uint256 flashed, uint256 flashFee) internal {
        // 1. Repay lending debt with flashed USDC.
        IERC20(usdc).approve(p.lendingVenue, flashed);
        _call(p.lendingVenue, p.lendingRepayCalldata);

        // 2. Withdraw PT collateral.
        _call(p.lendingVenue, p.lendingWithdrawCalldata);

        // 3. PT → USDC via Pendle router.
        (, address pt, ) = IPMarket(p.pendleMarket).readTokens();
        uint256 ptBal = IERC20(pt).balanceOf(address(this));
        IERC20(pt).approve(pendleRouter, ptBal);
        _call(pendleRouter, p.pendleRouterCalldata);

        uint256 owed = flashed + flashFee;
        uint256 usdcBal = IERC20(usdc).balanceOf(address(this));
        if (usdcBal < owed) revert InsufficientUsdcOut();

        // 4. Repay flash, forward residual to recipient.
        IERC20(usdc).transfer(flashVault, owed);
        uint256 residual = IERC20(usdc).balanceOf(address(this));
        if (residual < p.minUsdcOut) revert InsufficientUsdcOut();
        IERC20(usdc).transfer(p.recipient, residual);

        emit LoopExited(p.pendleMarket, p.lendingVenue, flashed, ptBal, residual, p.recipient);
    }

    // ─── Rescue (owner-only) ────────────────────────────────────────────────

    /// Sweep stray tokens. Should never be non-zero between atomic cycles — triggers only if
    /// someone sends tokens here directly or a flash call reverts mid-way and leaves residue.
    function rescue(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).transfer(to, amount);
    }

    // ─── Helpers ────────────────────────────────────────────────────────────

    function _call(address target, bytes memory data) internal {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            if (ret.length == 0) revert ExternalCallFailed(ret);
            assembly { revert(add(ret, 32), mload(ret)) }
        }
    }
}

// ─── Minimal external interfaces ────────────────────────────────────────────

interface IBalancerVault {
    function flashLoan(
        address recipient,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

interface IPMarket {
    function readTokens() external view returns (address sy, address pt, address yt);
    function isExpired() external view returns (bool);
}
