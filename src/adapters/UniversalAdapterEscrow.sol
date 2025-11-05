// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IVaultV2} from "../interfaces/IVaultV2.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";
import {IUniversalAdapterEscrow} from "./interfaces/IUniversalAdapterEscrow.sol";
import {SafeERC20Lib} from "../libraries/SafeERC20Lib.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title UniversalAdapterEscrow
/// @notice Unified adapter that merges UniversalEscrowAdapter and StrategyEscrow functionality
/// @dev Simplifies architecture by combining adapter and escrow logic into a single contract
contract UniversalAdapterEscrow is IUniversalAdapterEscrow {
    using SafeERC20Lib for IERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /* CONSTANTS */

    // Vault function selectors for call validation
    bytes4 private constant DEALLOCATE_SELECTOR = 0x4b219d16; // deallocate(address,bytes,uint256)
    bytes4 private constant FORCE_DEALLOCATE_SELECTOR = 0xe4d38cd8; // forceDeallocate(address,bytes,uint256,address)

    // Circuit breaker: Maximum acceptable balance loss per executeStrategy call (10% = 1000 basis points)
    uint256 private constant MAX_BALANCE_LOSS_BPS = 1000;

    // SECURITY FIX Issue #2 (FIXING_ISSUES.md): Gas cap for valuer.getTotalValue() to preserve liveness
    // Prevents unbounded activeStrategies enumeration from causing DoS of deposits/withdrawals
    uint256 private constant VALUER_GAS_STIPEND = 200000;

    // HYBRID SECURITY MODEL (FIXING.md): Time-bounded fallback to cached valuation
    // Maximum age of cached valuation before rejecting fallback
    // CONFIGURABLE: Adjust based on your strategy volatility and operational needs
    //   - 1 hour: Very secure, tight cache (high volatility strategies)
    //   - 4 hours: Balanced security/availability (recommended for most cases)
    //   - 12 hours: High availability (stable strategies only)
    uint256 private constant MAX_CACHED_VALUATION_AGE = 4 hours;

    /* IMMUTABLES */

    address public immutable parentVault;
    address public immutable asset;
    address public immutable valuer;
    bool public immutable useOffchainValuer;

    /* STORAGE */

    // Strategy management
    mapping(bytes32 => StrategyConfig) public strategies;
    mapping(bytes32 => uint256) public allocations;
    EnumerableSet.Bytes32Set private activeStrategies;

    // Total allocations tracking for gas optimization
    uint256 public totalAllocations;

    // Track tokens deposited to external protocols per strategy
    // This enables accurate idle asset calculation even after execution
    mapping(bytes32 => uint256) public externalDeposits;
    uint256 public totalExternalDeposits;

    // Cached valuation for time-bounded fallback
    uint256 private cachedValuation;
    uint256 private cachedValuationTimestamp;

    // Whitelist management
    mapping(address => mapping(bytes4 => WhitelistConfig)) public functionWhitelist;

    // Pause state
    bool public paused;

    // Access control
    address public owner;

    // SECURITY FIX Issue #1 (security_issues_5nov2025.md): Early-exit target for deallocate multicall
    // Transient variable used during deallocate to enable early exit when sufficient assets recovered
    // Set to target withdrawal amount before multicall, reset to 0 after
    uint256 private withdrawTarget;

    /* MODIFIERS */

    modifier onlyVault() {
        if (msg.sender != parentVault) revert NotAuthorized();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
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

    /* CONSTRUCTOR */

    constructor(
        address _parentVault,
        address _valuer,
        bool _useOffchainValuer
    ) {
        parentVault = _parentVault;
        valuer = _valuer;
        useOffchainValuer = _useOffchainValuer;

        // Get asset from parent vault
        asset = IVaultV2(_parentVault).asset();

        // Set owner to vault owner
        owner = IVaultV2(_parentVault).owner();

        // Approve parent vault to pull assets back for deallocations
        SafeERC20Lib.safeApprove(asset, _parentVault, type(uint256).max);
    }

    /* EXTERNAL FUNCTIONS - ADAPTER INTERFACE */

    /// @inheritdoc IAdapter
    function allocate(
        bytes memory data,
        uint256 assets,
        bytes4,
        address
    ) external override onlyVault notPaused returns (bytes32[] memory ids, int256 change) {
        if (data.length == 0) revert InvalidData();

        // Decode allocation data
        (bytes32 strategyId, , bool executeNow, Call[] memory calls) =
            abi.decode(data, (bytes32, uint256, bool, Call[]));

        // Validate strategy exists and is active
        if (!strategies[strategyId].active) revert StrategyNotActive();

        // L-13 FIX: Use full assets amount to prevent locked tokens
        // Unlike old architecture where only partial amount was used, we utilize 100% of transferred assets
        // This prevents the issue where assets > amount would leave tokens stuck in adapter
        if (assets == 0) revert InvalidAmount();

        // SIMPLIFIED ALLOCATION: Standard ERC20 tokens only
        // Fee-on-transfer and rebase tokens are not supported by underlying protocols
        // (Morpho Vault, Pendle, etc.) so we don't need complex tracking logic

        // Update allocation tracking with transferred amount
        allocations[strategyId] += assets;
        totalAllocations += assets;

        // Add to active strategies if not already present (O(1) operation)
        activeStrategies.add(strategyId);

        // Optionally execute strategy immediately after allocation
        if (executeNow && calls.length > 0) {
            _executeMulticall(strategyId, calls, false);
        }

        // Update cached valuation for time-bounded fallback
        _updateCachedValuation();

        // Return results
        ids = new bytes32[](1);
        ids[0] = strategyId;
        change = int256(assets);

        emit AllocationUpdated(strategyId, allocations[strategyId], change);
    }

    /// @inheritdoc IAdapter
    /// @notice Deallocate assets from a strategy
    /// @param data Encoded data: (bytes32 strategyId, uint256 minAmountOut, bool ignored, Call[] withdrawCalls)
    ///             - minAmountOut: Minimum amount to receive (slippage protection). Set to 0 to disable check.
    ///             - ignored: Previously used for executeNow, now ignored for backward compatibility
    /// @dev SECURITY FIX: minAmountOut parameter enables slippage protection for liquidity adapter withdrawals
    ///      This prevents MEV sandwich attacks when adapter executes DEX swaps during deallocate.
    ///      Set minAmountOut = 0 to disable slippage check (backward compatible).
    function deallocate(
        bytes memory data,
        uint256 assets,
        bytes4 caller,
        address
    ) external override onlyVault notPaused returns (bytes32[] memory ids, int256 change) {
        if (data.length == 0) revert InvalidData();

        // SECURITY FIX Issue #3 (FIXING_ISSUES.md): Prevent OOG from oversized Call[] payload
        // The operator could accidentally store liquidityData with massive Call[] array
        // Decoding large arrays can OOG even when calls aren't needed
        // Limit to reasonable size (~100KB) to preserve withdrawal availability
        if (data.length > 100000) revert InvalidData(); // ~100KB max

        // Decode deallocation data with slippage protection parameter
        (bytes32 strategyId, uint256 minAmountOut, , Call[] memory withdrawCalls) =
            abi.decode(data, (bytes32, uint256, bool, Call[]));

        // SECURITY FIX Issue #1 (security_issues_5nov2025.md): Cap withdraw calls to bound gas
        // Prevents DoS from excessively long multicalls that can OOG
        if (withdrawCalls.length > 64) revert InvalidData();

        // IMPORTANT: No allocation validation here - users should be able to withdraw
        // idle assets, profits, or do emergency withdrawals even from strategies with 0 allocation

        uint256 adapterBalance = IERC20(asset).balanceOf(address(this));
        uint256 actualAmount;

        // SECURITY FIX Issue #3: For forceDeallocate, ignore calls but use same data format
        if (caller == FORCE_DEALLOCATE_SELECTOR) {
            // SECURITY FIX Issue #3: Only allow force deallocate up to slack amount
            // Slack = allocations - externalDeposits (assets in adapter, not in external protocols)
            // This prevents donation-assisted force-deallocate attacks
            uint256 slack = allocations[strategyId] > externalDeposits[strategyId]
                ? allocations[strategyId] - externalDeposits[strategyId]
                : 0;

            if (assets > slack) {
                revert InvalidAmount();
            }

            // Only allow if sufficient balance is available in adapter
            // Vault has approval to pull tokens directly via transferFrom
            if (assets > adapterBalance) {
                revert InvalidAmount();
            }
            actualAmount = assets;
            // No external calls executed - withdrawCalls are ignored for security
        } else {
            // Normal deallocate: Handle three balance scenarios explicitly

            if (assets <= adapterBalance) {
                // Scenario 1: Balance covers entire withdrawal
                actualAmount = assets;
                // No external calls needed - we have sufficient balance

            } else {
                // Scenario 2: Insufficient balance - need to withdraw from protocol
                // SECURITY FIX Issues #1 & #2: Removed restrictive valuer cap

                // SECURITY FIX Issue #7: Try-catch multicall to prevent revert-on-failure DoS
                // If protocol withdrawal fails (no liquidity, paused, etc.), we can still
                // return whatever balance we have instead of reverting entire deallocate
                if (withdrawCalls.length > 0) {
                    // SECURITY FIX Issue #1 (security_issues_5nov2025.md): Set early-exit target
                    // Enables _executeMulticall to break early when sufficient assets recovered
                    withdrawTarget = assets;

                    try this.externalExecuteMulticall(strategyId, withdrawCalls) {
                        // Success - balance increased from protocol withdrawal
                    } catch {
                        // Failure - protocol couldn't provide liquidity
                        // Continue with current balance (partial fulfillment)
                        // Vault's transferFrom will naturally limit to available balance
                    }

                    // SECURITY FIX Issue #1: Reset target regardless of success/failure
                    withdrawTarget = 0;
                }

                uint256 balanceAfter = IERC20(asset).balanceOf(address(this));

                // SECURITY FIX Issue #2: Enforce all-or-nothing
                // If still insufficient after attempted withdrawals, revert
                // This ensures VaultV2 always pulls exactly what we report
                if (balanceAfter < assets) {
                    revert InvalidAmount();
                }

                // Ensure VaultV2 pulls exactly what we report as change
                actualAmount = assets;

                // NOTE: Removed valuer cap (was Issue #2) - physical availability is the only limit
                // If we don't have enough, vault's transferFrom will revert with insufficient balance

                // SECURITY FIX (security_issues_5nov2025_3.md Issue #3): Symmetric reduction on withdrawal
                // When we successfully withdraw from protocol to adapter, reduce externalDeposits accordingly
                // This is SAFE here because:
                // 1. We're in deallocate (vault-initiated withdrawal)
                // 2. We just executed withdrawCalls that increased balance
                // 3. We know this is a withdrawal, not a donation or other balance increase
                //
                // This fixes underpricing caused by overstated externalDeposits after withdrawals
                // Note: balanceAfter already defined at line 262
                if (balanceAfter > adapterBalance) {
                    uint256 d = externalDeposits[strategyId];
                    uint256 x = balanceAfter - adapterBalance;

                    // Cap reduction to requested assets (don't over-reduce if we got extra)
                    if (x > assets) x = assets;

                    // Cap reduction to current per-strategy external deposits (prevent underflow)
                    if (x > d) x = d;

                    // Cap reduction to totalExternalDeposits (prevent underflow from desync)
                    if (x > totalExternalDeposits) x = totalExternalDeposits;

                    // Apply symmetric reduction
                    if (x > 0) {
                        externalDeposits[strategyId] = d - x;
                        totalExternalDeposits -= x;
                    }
                }
            }
        }

        // SECURITY FIX (security_issues_5nov2025_3.md Issue #2): Improved slippage protection
        // OLD: Checked actualAmount < minAmountOut (ineffective - actualAmount = assets after success)
        // NEW: Check total balance after withdrawCalls to ensure MEV/slippage hasn't reduced it below minimum
        //
        // Only enforce when:
        // 1. Not force deallocate (force ignores calls anyway)
        // 2. minAmountOut > 0 (slippage protection requested)
        //
        // NOTE: minAmountOut represents minimum acceptable TOTAL balance, not balance increase
        // This allows users to set slippage tolerance (e.g., request 1000 with minAmountOut 990 = 1% tolerance)
        if (
            caller != FORCE_DEALLOCATE_SELECTOR &&
            minAmountOut > 0
        ) {
            // Edge case: if minAmountOut > requested assets, fail immediately
            // We never return more than requested assets, even if balance is higher
            if (minAmountOut > assets) {
                revert SlippageTooHigh();
            }

            // If withdrawCalls were executed, check total balance meets minimum
            if (withdrawCalls.length > 0) {
                uint256 balanceAfter = IERC20(asset).balanceOf(address(this));

                // Enforce total balance >= minAmountOut to protect against MEV/slippage
                if (balanceAfter < minAmountOut) {
                    revert SlippageTooHigh();
                }
            }
        }

        // Update allocation - handle case where actualAmount exceeds tracked allocation
        uint256 allocationDecrease = actualAmount > allocations[strategyId]
            ? allocations[strategyId]
            : actualAmount;
        allocations[strategyId] -= allocationDecrease;
        totalAllocations -= allocationDecrease;

        // SECURITY FIX Issue #3: Remove from active strategies if BOTH allocation AND externalDeposits are zero
        // This prevents valuer from excluding strategies that still have external deposits
        if (allocations[strategyId] == 0 && externalDeposits[strategyId] == 0) {
            _removeFromActiveStrategies(strategyId);
        }

        // Transfer assets back to vault
        // The vault will pull the assets using transferFrom

        // Update cached valuation for time-bounded fallback
        _updateCachedValuation();

        // Return results
        ids = new bytes32[](1);
        ids[0] = strategyId;
        change = -int256(actualAmount);

        emit AllocationUpdated(strategyId, allocations[strategyId], change);
    }

    /// @notice External wrapper for _executeMulticall to enable try-catch in deallocate
    /// @dev SECURITY FIX Issue #7: Allows deallocate to gracefully handle protocol withdrawal failures
    ///      This function is external to enable try-catch, but can only be called by this contract
    /// @param strategyId The strategy identifier
    /// @param calls Array of calls to execute
    function externalExecuteMulticall(bytes32 strategyId, Call[] memory calls) external {
        require(msg.sender == address(this), "Only self");
        _executeMulticall(strategyId, calls, false);
    }

    /// @inheritdoc IAdapter
    function realAssets() external view override returns (uint256 assets) {
        // CRITICAL SECURITY FIX: Donation-resistant valuation
        // Prevents attacker from donating tokens to inflate realAssets and extract value on withdrawals
        //
        // VULNERABILITY (before fix):
        // 1. Attacker donates D tokens to adapter → balance increases
        // 2. Attacker withdraws A ≤ D tokens → higher realAssets → fewer shares burned
        // 3. Withdrawal funded by donated balance → attacker keeps extra shares
        //
        // FIX: Ignore excess idle balance beyond allocated-in-adapter
        // - Only count balance up to (totalAllocations - totalExternalDeposits)
        // - Excess balance (donations) excluded from valuation
        // - Prevents donation-based share manipulation

        uint256 balance = IERC20(asset).balanceOf(address(this));

        // Donation-resistant valuation: ignore excess idle balance beyond allocated-in-adapter
        uint256 allocatedInAdapter = totalAllocations > totalExternalDeposits
            ? totalAllocations - totalExternalDeposits
            : 0;

        uint256 excessIdle = balance > allocatedInAdapter
            ? balance - allocatedInAdapter
            : 0;

        // Principal-only fallback (ignores donations sitting on the adapter)
        // uint256 minKnownValue = totalAllocations;

        // SECURITY FIX (security_issues_5nov2025_3.md Issue #1): Use single aggregated strategy ID
        // instead of enumerating all strategies to prevent DoS from unbounded enumeration
        // OLD: getTotalValue(address) → O(n) enumeration of activeStrategies → OOG with many strategies
        // NEW: getValue(ESCROW_TOTAL_ID) → O(1) lookup → gas-bounded
        bytes32 totalId = keccak256(abi.encodePacked("ESCROW_TOTAL", address(this)));

        (bool success, bytes memory data) = valuer.staticcall{gas: VALUER_GAS_STIPEND}(
            abi.encodeWithSignature("getValue(bytes32)", totalId)
        );

        if (success && data.length >= 32) {
            uint256 totalValue = abi.decode(data, (uint256));

            // NOTE (security_issues_5nov2025_4.md Issue #2): Semantic mismatch handling deferred
            // The conditional logic to detect if valuer excludes idle is too aggressive and triggers
            // false positives during legitimate losses. This requires operator-level configuration
            // (valuer semantic agreement) rather than runtime detection.
            //
            // Current approach: Assume valuer includes idle balance (standard behavior)
            // Adjust totalValue to exclude donation excess
            uint256 totalValueAdj = totalValue > excessIdle
                ? totalValue - excessIdle
                : 0;

            // CRITICAL SECURITY FIX - HIGH SEVERITY ISSUE:
            // Always trust the valuer's donation-adjusted value, no fallback threshold
            //
            // PREVIOUS VULNERABILITY (10% Tolerance Threshold):
            // - When real losses >10% occurred, adapter returned principal instead of actual value
            // - VaultV2 overstated totalAssets, causing share overpricing
            // - Early withdrawers burned fewer shares per asset, extracting excess value
            // - Late withdrawers suffered principal loss or failed withdrawals
            // - Created perverse "bank run" incentive during legitimate market crashes
            //
            // ROOT CAUSE OF VULNERABILITY:
            // - 10% threshold was meant to prevent malicious underpricing
            // - But in practice, it caused WORSE harm during legitimate losses
            // - Overpricing enables value extraction (more harmful than underpricing)
            // - Defeats the purpose of real-time valuer pricing
            //
            // NEW SECURITY MODEL:
            // ✅ Always accept valuer's donation-adjusted value (even if >10% loss)
            // ✅ Donation protection remains via excessIdle adjustment
            // ✅ Fair share pricing for all users (early and late withdrawers)
            // ✅ Accurate loss reporting prevents value extraction
            // ✅ Let SecurityMonitor/EmergencyGate handle anomaly detection
            //
            // WHAT'S STILL PROTECTED:
            // ❌ Donation-based inflation → excessIdle excluded from totalValueAdj
            // ❌ Malicious valuer underpricing → Valuer has multi-sig + signature verification
            // ❌ Operational anomalies → SecurityMonitor detects rapid withdrawals
            // ❌ Emergency situations → EmergencyGate can pause operations
            //
            // WHY THIS IS SAFE:
            // - UniversalValuerOffchain is a trusted component with signature verification
            // - Real DeFi losses >10% are legitimate (liquidations, exploits, crashes)
            // - Accurate pricing is CRITICAL for user fairness
            // - Ghost amounts from losses >10% can be manually synced via syncExternalDeposits()
            //
            // TRADE-OFF:
            // - Large losses >10% may create temporary ghost (manual sync needed)
            // - But prevents systematic value extraction from late withdrawers
            // - Owner can call syncExternalDeposits() to correct ghost amounts
            // - Better to under-report slightly than enable value extraction

            // Always trust the valuer's donation-adjusted value
            if (totalValueAdj > 0) {
                return totalValueAdj;
            }

            // Valuer returned 0 - check if this is legitimate (no allocations) or error
            // If no allocations, 0 is the correct value (cold start or fully deallocated)
            if (totalAllocations == 0) {
                return 0;  // Legitimate 0 value when nothing allocated
            }

            // Valuer returned 0 but we have allocations - attempt time-bounded fallback
            // If cached valuation is recent (< 4 hours), use it as fallback
            // Otherwise revert to prevent stale pricing
            if (cachedValuationTimestamp > 0 && block.timestamp - cachedValuationTimestamp <= MAX_CACHED_VALUATION_AGE) {
                // Recent cache available - use it to maintain availability
                return cachedValuation;
            }

            // No recent cache and valuer returned 0 despite allocations - must revert
            revert ValuationUnavailable();
        }

        // HYBRID SECURITY MODEL (FIXING.md): Time-bounded fallback to cached valuation
        //
        // VULNERABILITY: Falling back to principal enables gas-manipulation attacks:
        //   - Force valuer failure with low gas during profits → underprice → mint excess shares
        //   - Force valuer failure with low gas during losses → overprice → burn too few shares
        //
        // SOLUTION: Three-tier fallback strategy
        //   1. Try fresh valuation with gas stipend
        //   2. If fails but cached valuation < 4 hours old → use cache (time-bounded fallback)
        //   3. If cache too stale or missing → revert (fail-closed)
        //   EXCEPTION: If totalAllocations == 0, return 0 (cold start or fully deallocated)
        //
        // SECURITY PROPERTIES:
        //   ✅ Gas manipulation attacks infeasible (attacker can't sustain low-gas for 4 hours)
        //   ✅ Maintains availability during transient valuation failures
        //   ✅ Prevents stale pricing with 4-hour cache expiry
        //   ✅ Fails closed when cache unavailable or too old
        //   ✅ Handles cold start gracefully when no allocations exist
        //
        // OPERATIONAL BENEFITS:
        //   ✅ Vault remains operational during brief valuation outages
        //   ✅ Users can still withdraw during short-term issues
        //   ✅ Reduces single-point-of-failure risk
        //   ✅ 4-hour window provides time to restore valuation service

        // Cold start case: no allocations, valuer failed to respond
        // This is safe to return 0 since there's nothing allocated
        if (totalAllocations == 0) {
            return 0;
        }

        // Valuer call failed but we have allocations - try cached fallback
        if (cachedValuationTimestamp > 0 && block.timestamp - cachedValuationTimestamp <= MAX_CACHED_VALUATION_AGE) {
            // Recent cached valuation available - use it to maintain availability
            return cachedValuation;
        }

        // No recent cached valuation - must revert
        // Operator must ensure valuation service health or reduce strategy count
        revert ValuationUnavailable();
    }

    /* EXTERNAL FUNCTIONS - STRATEGY MANAGEMENT */

    /// @inheritdoc IUniversalAdapterEscrow
    function setStrategy(
        bytes32 strategyId,
        address agent,
        bytes calldata preConfiguredData,
        uint256 dailyLimit
    ) external onlyOwner {
        strategies[strategyId] = StrategyConfig({
            agent: agent,
            preConfiguredData: preConfiguredData,
            dailyLimit: dailyLimit,
            lastResetTime: block.timestamp,
            dailyUsed: 0,
            active: true
        });

        emit StrategySet(strategyId, agent, dailyLimit);
    }

    /// @inheritdoc IUniversalAdapterEscrow
    function removeStrategy(bytes32 strategyId) external onlyOwner {
        // SECURITY FIX Issue #3: Cannot remove strategy with active allocation OR externalDeposits
        // This prevents removing strategies that still have funds in external protocols
        if (allocations[strategyId] > 0 || externalDeposits[strategyId] > 0) {
            revert InvalidStrategy();
        }

        delete strategies[strategyId];
        _removeFromActiveStrategies(strategyId);

        emit StrategyRemoved(strategyId);
    }

    /// @inheritdoc IUniversalAdapterEscrow
    function updateWhitelist(
        address target,
        bytes4 selector,
        bool allowed,
        uint256 limit
    ) external onlyOwner {
        functionWhitelist[target][selector] = WhitelistConfig({
            allowed: allowed,
            limit: limit
        });

        emit WhitelistUpdated(target, selector, allowed, limit);
    }

    /* EXTERNAL FUNCTIONS - STRATEGY EXECUTION */

    /// @inheritdoc IUniversalAdapterEscrow
    /// @dev SECURITY WARNING - MEV/Sandwich Attack Risk:
    ///      This function executes arbitrary whitelisted calls with basic circuit breaker protection.
    ///      Circuit breaker prevents catastrophic losses (>10%) but strategy agents are still
    ///      RESPONSIBLE for including slippage/deadline checks in their call data.
    ///
    ///      Example attack without slippage protection:
    ///      1. Agent submits withdrawal from DEX
    ///      2. MEV bot frontruns: manipulates pool price
    ///      3. Agent's tx executes at bad price → principal loss
    ///      4. MEV bot backruns: extracts profit
    ///
    ///      DEFENSE-IN-DEPTH PROTECTION:
    ///      - Circuit breaker: Prevents >10% balance loss per operation (last-resort safety)
    ///      - Agent responsibility: Use protocol-native slippage parameters (primary defense)
    ///      - Deadline parameters: Prevent stale transactions
    ///      - Private mempools: Consider Flashbots for sensitive operations
    ///
    ///      MITIGATION - Agents MUST:
    ///      - Use protocol-native slippage parameters (e.g., Uniswap minAmountOut)
    ///      - Include deadline parameters to prevent stale transactions
    ///      - Consider using private mempools (Flashbots, etc.)
    ///      - Monitor for MEV and adjust strategies accordingly
    ///
    ///      For additional protection with explicit balance checks, use executeStrategyWithSlippage() instead.
    ///      For LP minting operations where >10% balance decrease is expected, use executeStrategyBypassCircuitBreaker() instead.
    function executeStrategy(
        bytes32 strategyId,
        Call[] calldata calls
    ) external onlyStrategyAgentOrOwner(strategyId) notPaused {
        // SECURITY FIX (security_issues_5nov2025_4.md Issue #1): Prevent balance increases
        // Balance increases (withdrawals) must use executeStrategyWithSlippage() or deallocate()
        // to ensure proper externalDeposits accounting via symmetric reduction
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));

        _executeMulticall(strategyId, calls, false);

        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        if (balanceAfter > balanceBefore) revert InvalidAmount();

        _updateCachedValuation();
        emit StrategyExecuted(strategyId, msg.sender);
    }

    /// @notice Execute strategy calls with additional slippage protection
    /// @param strategyId The strategy identifier
    /// @param calls Array of calls to execute
    /// @param minBalanceIncrease Minimum balance increase required (for withdrawals), 0 to skip check
    /// @dev SECURITY FEATURE: Provides additional slippage protection on top of protocol-native checks
    ///      This is NOT a substitute for proper slippage parameters in call data!
    ///      Use this for withdrawals where you expect balance to increase.
    ///      For deposits (balance decreases), set minBalanceIncrease to 0.
    function executeStrategyWithSlippage(
        bytes32 strategyId,
        Call[] calldata calls,
        uint256 minBalanceIncrease
    ) external onlyStrategyAgentOrOwner(strategyId) notPaused {
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));

        _executeMulticall(strategyId, calls, false);

        // Slippage check for withdrawals
        if (minBalanceIncrease > 0) {
            uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
            require(balanceAfter >= balanceBefore + minBalanceIncrease, "Slippage: insufficient balance increase");

            // SECURITY FIX (security_issues_5nov2025_3.md Issue #3): Symmetric reduction on withdrawal
            // When we successfully withdraw (balance increased), reduce externalDeposits accordingly
            // This is SAFE here because:
            // 1. We're in executeStrategyWithSlippage with minBalanceIncrease > 0 (explicit withdrawal)
            // 2. We measured the balance increase and it passed slippage check
            // 3. We know this is a withdrawal, not a donation or other balance increase
            //
            // This fixes underpricing caused by overstated externalDeposits after withdrawals
            if (balanceAfter > balanceBefore) {
                uint256 d = externalDeposits[strategyId];
                uint256 x = balanceAfter - balanceBefore;

                // Cap reduction to measured minimum increase (don't over-reduce if we got extra)
                if (x > minBalanceIncrease) x = minBalanceIncrease;

                // Cap reduction to current per-strategy external deposits (prevent underflow)
                if (x > d) x = d;

                // Cap reduction to totalExternalDeposits (prevent underflow from desync)
                if (x > totalExternalDeposits) x = totalExternalDeposits;

                // Apply symmetric reduction
                if (x > 0) {
                    externalDeposits[strategyId] = d - x;
                    totalExternalDeposits -= x;
                }
            }
        }

        _updateCachedValuation();
        emit StrategyExecuted(strategyId, msg.sender);
    }

    /// @notice Execute strategy calls with circuit breaker bypassed
    /// @param strategyId The strategy identifier
    /// @param calls Array of calls to execute
    /// @dev USE WITH EXTREME CAUTION: This bypasses the 10% balance loss circuit breaker!
    ///
    ///      ONLY use this for legitimate operations that cause large balance decreases:
    ///      1. LP minting where tokens are locked in NFT position (e.g., Uniswap V3)
    ///      2. Large protocol deposits (>10% of balance) that need atomic execution
    ///      3. Multi-step operations where balance temporarily drops >10% but recovers
    ///
    ///      SECURITY WARNING:
    ///      - Agent MUST include proper slippage protection in call data
    ///      - Agent MUST verify balance after execution manually
    ///      - Bypassing circuit breaker removes last-resort safety net
    ///      - Only whitelisted functions can be called (provides some protection)
    ///
    ///      For normal operations, use executeStrategy() or executeStrategyWithSlippage() instead.
    function executeStrategyBypassCircuitBreaker(
        bytes32 strategyId,
        Call[] calldata calls
    ) external onlyStrategyAgentOrOwner(strategyId) notPaused {
        // SECURITY FIX (security_issues_5nov2025_4.md Issue #1): Prevent balance increases
        // Balance increases (withdrawals) must use executeStrategyWithSlippage() or deallocate()
        // to ensure proper externalDeposits accounting via symmetric reduction
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));

        _executeMulticall(strategyId, calls, true);

        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        if (balanceAfter > balanceBefore) revert InvalidAmount();

        _updateCachedValuation();
        emit StrategyExecuted(strategyId, msg.sender);
    }

    /// @inheritdoc IUniversalAdapterEscrow
    function executePreConfigured(bytes32 strategyId) external onlyStrategyAgentOrOwner(strategyId) notPaused {
        StrategyConfig memory strategy = strategies[strategyId];
        if (strategy.preConfiguredData.length == 0) revert InvalidData();

        // Decode pre-configured calls
        Call[] memory calls = abi.decode(strategy.preConfiguredData, (Call[]));

        // SECURITY FIX (security_issues_5nov2025_4.md Issue #1): Prevent balance increases
        // Balance increases (withdrawals) must use executeStrategyWithSlippage() or deallocate()
        // to ensure proper externalDeposits accounting via symmetric reduction
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));

        _executeMulticall(strategyId, calls, false);

        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        if (balanceAfter > balanceBefore) revert InvalidAmount();

        _updateCachedValuation();
        emit StrategyExecuted(strategyId, msg.sender);
    }

    /* EXTERNAL FUNCTIONS - ADMIN */

    /// @inheritdoc IUniversalAdapterEscrow
    function sweep(address token, address recipient) external onlyOwner {
        if (token == asset) revert CannotSweepAsset();

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            SafeERC20Lib.safeTransfer(token, recipient, balance);
            emit TokenSwept(token, recipient, balance);
        }
    }

    /// @inheritdoc IUniversalAdapterEscrow
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PauseStatusChanged(_paused);
    }

    /// @notice Transfer ownership
    /// @param newOwner The new owner address
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");
        owner = newOwner;
    }

    /// @inheritdoc IUniversalAdapterEscrow
    /// @notice Manually adjust totalExternalDeposits to remove accounting drift
    /// @dev SECURITY FIX: After HIGH severity issue fix, this is for accounting cleanup only
    ///      SECURITY FIX Issue #8: No pause check - owner can fix accounting even during pause
    ///
    ///      CONTEXT AFTER HIGH SEVERITY FIX:
    ///      - realAssets() now always reports accurate values (no 10% fallback)
    ///      - Ghost amounts are minimal in normal operations
    ///      - This function is for periodic accounting maintenance, not emergency fixes
    ///
    ///      USE CASES:
    ///      - Clear accumulated accounting drift from slippage/fees
    ///      - Periodic maintenance to keep tracking accurate
    ///      - After protocol interactions with complex fee structures
    ///      - Cleanup after external protocol exploits/liquidations
    ///      - Fix accounting during pause for accurate emergency operations
    ///
    ///      SECURITY MEASURES:
    ///      - Can only reduce totalExternalDeposits (removing ghost, not creating it)
    ///      - New value must be within 20% of valuer's current report
    ///      - Only owner can call (no pause restriction - intentional for emergency fixes)
    ///      - Emits event for transparency/auditability
    ///
    ///      WHY NO PAUSE CHECK:
    ///      - During pause, realAssets() still returns (balance + totalExternalDeposits)
    ///      - If totalExternalDeposits has ghost, it causes persistent overpricing
    ///      - Owner needs ability to fix accounting during pause for accurate emergency operations
    ///      - forceDeallocate and other emergency functions rely on accurate realAssets()
    ///
    ///      WORKFLOW:
    ///      1. Monitor getGhostAmount() for significant ghosts
    ///      2. Verify valuer is reporting accurate current value
    ///      3. Calculate correct external deposits: valuerValue - balance
    ///      4. Call syncExternalDeposits with corrected value (works even when paused)
    function syncExternalDeposits(uint256 newTotalExternalDeposits) external onlyOwner {
        // SECURITY FIX Issue #8: Removed pause check
        // Owner must be able to fix accounting during pause for accurate emergency operations

        // SECURITY: Can only reduce, never increase (removing ghost, not creating it)
        require(newTotalExternalDeposits <= totalExternalDeposits, "Can only reduce ghost");

        // VALIDATION: New value should make sense given valuer's current report
        uint256 balance = IERC20(asset).balanceOf(address(this));
        uint256 newMinKnown = balance + newTotalExternalDeposits;

        // SECURITY FIX (security_issues_5nov2025_5.md): Use aggregated ESCROW_TOTAL valuation
        // OLD: getTotalValue(address) → O(N) strategy enumeration → gas-unsafe for high N
        // NEW: getValue(ESCROW_TOTAL_ID) → O(1) lookup → gas-bounded
        bytes32 totalId = keccak256(abi.encodePacked("ESCROW_TOTAL", address(this)));

        (bool success, bytes memory data) = valuer.staticcall{gas: VALUER_GAS_STIPEND}(
            abi.encodeWithSignature("getValue(bytes32)", totalId)
        );

        if (success && data.length >= 32) {
            uint256 valuerValue = abi.decode(data, (uint256));

            // SAFETY CHECK: New minimum shouldn't be too far below valuer value
            // Allow up to 20% below valuer for safety margin (more conservative than 10% tolerance)
            require(valuerValue >= (newMinKnown * 8000) / 10000, "New value too low vs valuer");
        }

        uint256 oldValue = totalExternalDeposits;

        // SECURITY FIX (security_issues_5nov2025_2.md): Proportionally reduce per-strategy values
        // to maintain invariant: totalExternalDeposits == sum(externalDeposits[•])
        // This prevents asymmetric updates that cause double counting (overpricing) or
        // full-idle subtraction (underpricing) in the donation filter
        if (oldValue > 0 && newTotalExternalDeposits < oldValue) {
            // Calculate reduction ratio with 1e18 precision to avoid rounding errors
            // ratio = newTotal / oldTotal
            uint256 ratio = (newTotalExternalDeposits * 1e18) / oldValue;

            // Apply ratio to all active strategies' externalDeposits
            // TODO (security_issues_5nov2025_5.md): For large N, replace this O(N) sweep
            // with a paginated sync to avoid gas limits
            bytes32[] memory activeStrategyIds = activeStrategies.values();
            for (uint256 i = 0; i < activeStrategyIds.length; i++) {
                bytes32 strategyId = activeStrategyIds[i];
                uint256 currentPerStrategy = externalDeposits[strategyId];

                if (currentPerStrategy > 0) {
                    // Proportionally reduce: newValue = currentValue * ratio
                    uint256 newPerStrategy = (currentPerStrategy * ratio) / 1e18;
                    externalDeposits[strategyId] = newPerStrategy;

                    // If both allocation and externalDeposits are now zero, remove from active set
                    if (allocations[strategyId] == 0 && newPerStrategy == 0) {
                        _removeFromActiveStrategies(strategyId);
                    }
                }
            }
        }

        totalExternalDeposits = newTotalExternalDeposits;

        // SECURITY FIX (security_issues_5nov2025_4.md Issue #3): Invalidate stale cache and refresh
        // syncExternalDeposits changes donation filter parameters, so cached valuation becomes stale
        cachedValuationTimestamp = 0;
        _updateCachedValuation();

        emit ExternalDepositsSynced(msg.sender, oldValue, newTotalExternalDeposits);
    }

    /// @notice Reduce per-strategy externalDeposits to clear irrecoverable external exposure
    /// @dev SECURITY FIX Issue #4 (FIXING_ISSUES.md): Enables removal of stuck strategies after losses
    /// @param strategyId The strategy to update
    /// @param newPerStrategy The new per-strategy externalDeposits value (must be <= current)
    function reduceExternalDeposits(bytes32 strategyId, uint256 newPerStrategy) external onlyOwner {
        uint256 current = externalDeposits[strategyId];

        // SECURITY: Can only reduce, never increase
        if (newPerStrategy > current) revert InvalidAmount();

        uint256 delta = current - newPerStrategy;

        // Update per-strategy value
        externalDeposits[strategyId] = newPerStrategy;

        // SECURITY FIX (security_issues_5nov2025_2.md): Replace clamp-to-0 with revert
        // to preserve invariant sequencing and prevent aggregate from drifting from per-strategy sum
        // OLD: totalExternalDeposits = delta > t ? 0 : t - delta; (clamped to 0, breaks invariant)
        // NEW: Revert if invariant would be broken (ensures totalExternalDeposits == sum(externalDeposits[•]))
        require(delta <= totalExternalDeposits, "Invariant: delta exceeds total");
        totalExternalDeposits -= delta;

        // If both allocation and externalDeposits are now zero, remove from active set
        if (allocations[strategyId] == 0 && newPerStrategy == 0) {
            _removeFromActiveStrategies(strategyId);
        }

        // SECURITY FIX (security_issues_5nov2025_4.md Issue #3): Invalidate stale cache and refresh
        // reduceExternalDeposits changes donation filter parameters, so cached valuation becomes stale
        cachedValuationTimestamp = 0;
        _updateCachedValuation();

        emit ExternalDepositsReduced(strategyId, current, newPerStrategy, delta);
    }

    /* VIEW FUNCTIONS */

    /// @inheritdoc IUniversalAdapterEscrow
    function getStrategy(bytes32 strategyId) external view returns (StrategyConfig memory) {
        return strategies[strategyId];
    }

    /// @inheritdoc IUniversalAdapterEscrow
    function getWhitelist(address target, bytes4 selector) external view returns (WhitelistConfig memory) {
        return functionWhitelist[target][selector];
    }

    /// @inheritdoc IUniversalAdapterEscrow
    function getAllocation(bytes32 strategyId) external view returns (uint256) {
        return allocations[strategyId];
    }

    /// @inheritdoc IUniversalAdapterEscrow
    function getActiveStrategies() external view returns (bytes32[] memory) {
        return activeStrategies.values();
    }

    /// @notice Get idle assets that are not allocated to any strategy
    /// @dev CRITICAL FIX (L-04 + external deposit tracking):
    ///      Returns truly idle assets by accounting for:
    ///      1. Assets allocated to strategies (totalAllocations)
    ///      2. Assets moved to external protocols (totalExternalDeposits)
    ///
    ///      Formula: balance - (totalAllocations - totalExternalDeposits)
    ///
    ///      Example scenario:
    ///      - 1000 tokens transferred to adapter, totalAllocations = 1000
    ///      - executeStrategy deposits 600 to external protocol
    ///      - Adapter balance = 400, totalAllocations = 1000, totalExternalDeposits = 600
    ///      - Allocated assets still in adapter = 1000 - 600 = 400
    ///      - Idle assets = 400 - 400 = 0 (correct!)
    ///
    /// @return idleAssets Amount of assets sitting idle in the adapter (not allocated to any strategy)
    function getIdleAssets() external view returns (uint256 idleAssets) {
        uint256 balance = IERC20(asset).balanceOf(address(this));

        // Calculate how many allocated assets are still in the adapter (not moved to external protocols)
        uint256 allocatedInAdapter = totalAllocations > totalExternalDeposits
            ? totalAllocations - totalExternalDeposits
            : 0;

        // Truly idle assets = balance - allocated assets still in adapter
        if (balance > allocatedInAdapter) {
            return balance - allocatedInAdapter;
        }

        // Safety: if balance < allocatedInAdapter, return 0
        return 0;
    }

    /// @inheritdoc IUniversalAdapterEscrow
    /// @notice Calculate current ghost amount (overpricing) if any
    /// @dev SECURITY FIX: Updated after HIGH severity issue fix (removal of 10% threshold)
    ///      SECURITY FIX: Updated to use donation-resistant valuation (consistent with realAssets)
    ///
    ///      WHAT IS A GHOST AMOUNT:
    ///      Ghost = Difference between minKnownValue and valuer's reported real value
    ///      This typically happens due to:
    ///      - Historical tracking limitations in totalExternalDeposits
    ///      - Accumulated slippage/fees from protocol interactions
    ///      - Small discrepancies between accounting and actual value
    ///
    ///      IMPORTANT: After the HIGH severity fix, realAssets() always returns valuer's
    ///      accurate value (no 10% threshold fallback), so ghost amounts should be minimal
    ///      in normal operations. Ghost only represents accounting drift, not security issue.
    ///
    ///      WHEN TO SYNC:
    ///      - If ghost > 1% of totalAllocations: Monitor
    ///      - If ghost > 3% of totalAllocations: Consider syncing
    ///      - If ghost > 5% of totalAllocations: Should sync
    ///
    ///      Example:
    ///      - totalAllocations = 1000 (principal tracking)
    ///      - Valuer reports: 950 (after accumulated slippage/fees)
    ///      - Ghost = 1000 - 950 = 50 (5% accounting drift)
    ///      - realAssets() correctly returns 950 (no overpricing!)
    ///
    /// @return ghost The amount of accounting drift (0 if tracking is accurate)
    function getGhostAmount() external view returns (uint256 ghost) {
        uint256 balance = IERC20(asset).balanceOf(address(this));

        // Donation-resistant calculation (consistent with realAssets)
        uint256 allocatedInAdapter = totalAllocations > totalExternalDeposits
            ? totalAllocations - totalExternalDeposits
            : 0;

        uint256 excessIdle = balance > allocatedInAdapter
            ? balance - allocatedInAdapter
            : 0;

        // Principal-only minimum (ignores donations)
        uint256 minKnown = totalAllocations;

        (bool success, bytes memory data) = valuer.staticcall(
            abi.encodeWithSignature("getTotalValue(address)", address(this))
        );

        if (success && data.length >= 32) {
            uint256 valuerValue = abi.decode(data, (uint256));

            // Adjust for donation excess
            uint256 valuerValueAdj = valuerValue > excessIdle
                ? valuerValue - excessIdle
                : 0;

            if (minKnown > valuerValueAdj) {
                return minKnown - valuerValueAdj; // Amount of ghost (overpricing)
            }
        }
        return 0; // No ghost detected
    }

    /* INTERNAL FUNCTIONS */

    /// @notice Execute multiple calls with validation and circuit breaker
    /// @param strategyId The strategy identifier for tracking external deposits
    /// @param calls Array of calls to execute
    /// @param bypassCircuitBreaker If true, skip the 10% balance loss check (for LP minting)
    /// @dev SECURITY WARNING: No built-in slippage protection!
    ///      Agents must include slippage/deadline checks in call data to prevent MEV attacks.
    ///      Consider using executeStrategyWithSlippage() for additional protection.
    ///
    ///      CIRCUIT BREAKER: Prevents >10% balance loss per operation (last-resort safety).
    ///      This protects against direct theft or unexpected losses, but has limitations:
    ///      - Cannot distinguish legitimate protocol deposits from malicious transfers
    ///      - Any balance decrease >10% triggers circuit breaker, even if intentional
    ///      - For protocol deposits >10% of balance, split into smaller calls or use pre-approved amounts
    ///      - For LP minting where tokens are locked in NFT, set bypassCircuitBreaker=true
    function _executeMulticall(bytes32 strategyId, Call[] memory calls, bool bypassCircuitBreaker) internal {
        // L-16 Fix: Removed daily limit tracking logic per recommendation
        // Daily limits were problematic and could prevent emergency operations

        // CRITICAL FIX: Track balance before execution to detect token movements
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));

        for (uint256 i = 0; i < calls.length; i++) {
            Call memory call = calls[i];

            // Extract function selector
            bytes4 selector = bytes4(call.data);

            // Check whitelist
            WhitelistConfig memory config = functionWhitelist[call.target][selector];
            if (!config.allowed) {
                // Check if all functions are whitelisted for this target
                config = functionWhitelist[call.target][bytes4(0)];
                if (!config.allowed) {
                    revert FunctionNotWhitelisted();
                }
            }

            // L-16 Fix: All limit checking removed per security recommendation
            // Limits were problematic due to denomination mixing and could prevent
            // emergency operations. Whitelisting provides sufficient access control.

            // Execute the call
            (bool success, bytes memory returnData) = call.target.call{value: call.value}(call.data);
            if (!success) {
                // Best-effort during deallocate: when withdrawTarget is set, skip failed subcalls
                // to allow subsequent calls to recover sufficient assets. For other flows,
                // preserve strict revert-on-failure semantics.
                if (withdrawTarget == 0) revert CallFailed(i, returnData);
            }

            // SECURITY FIX Issue #1 (security_issues_5nov2025.md): Early exit optimization
            // If withdrawTarget is set (deallocate flow) and we've recovered enough assets, break early
            // This prevents DoS from executing expensive remaining calls when already sufficient
            if (
                withdrawTarget != 0 &&
                IERC20(asset).balanceOf(address(this)) >= withdrawTarget
            ) {
                break;
            }
        }

        // CIRCUIT BREAKER: Check for excessive balance loss BEFORE balance delta tracking
        // This must happen here (not in executeStrategy) because balance delta tracking below
        // would adjust totalExternalDeposits and mask the loss
        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        if (!bypassCircuitBreaker && balanceAfter < balanceBefore && balanceBefore > 0) {
            uint256 loss = balanceBefore - balanceAfter;
            uint256 lossBps = (loss * 10000) / balanceBefore;

            // Revert if balance decreased by more than 10%
            // NOTE: This also triggers for legitimate protocol deposits >10%
            // For large deposits, either:
            // 1. Split into smaller calls
            // 2. Ensure whitelisted protocol has approval and deposits directly
            // 3. Pass bypassCircuitBreaker=true for LP minting where tokens lock in NFT
            if (lossBps > MAX_BALANCE_LOSS_BPS) {
                revert ExcessiveBalanceLoss();
            }
        }

        // SECURITY FIX Issue #3: Net-delta balance tracking limitation
        // This approach has fundamental limitations:
        // - Cannot distinguish profit/yield accrual from explicit withdrawals
        // - Cannot distinguish losses/liquidations from explicit deposits
        // - Complex multicalls with multiple operations lose granular information
        //
        // IMPACT ON getIdleAssets():
        // - If profit accrues outside this function (direct protocol rewards), then later
        //   withdrawals will incorrectly decrease externalDeposits
        // - If multicall does deposit+withdraw in same tx, net change of 0 hides both operations
        //
        // MITIGATION:
        // - Primary source of truth is the valuer's getValue() for each strategy
        // - externalDeposits is best-effort approximation for getIdleAssets()
        // - Allocators should periodically sync by deallocating/reallocating to reset state
        //
        // PROPER FIX would require:
        // - Classify each whitelisted function as deposit/withdraw/neutral
        // - Track each call's balance delta individually within the loop
        // - Or remove this tracking entirely and rely solely on valuer

        // Balance delta tracking for external deposits (reuse balanceAfter from circuit breaker)

        if (balanceAfter < balanceBefore) {
            // Net balance decreased - likely deposit to external protocol
            // NOTE: Could also be loss/fee, causing externalDeposits overcount
            uint256 deposited = balanceBefore - balanceAfter;
            externalDeposits[strategyId] += deposited;
            totalExternalDeposits += deposited;
        }
        // SECURITY FIX Issue #2 (security_issues_5nov2025.md): Do NOT adjust on balance increases
        // Previous code treated balance increases as withdrawals and reduced totalExternalDeposits
        // This enabled two attack vectors:
        //   1. Double counting: Stale valuer includes strategy value + increased balance counted twice
        //   2. Donation infiltration: Balance increase from swapping donated tokens bypasses donation filter
        // FIX: Only track balance DECREASES (deposits to protocol), ignore balance INCREASES
        // Defer aggregate reduction to admin/keeper sync via syncExternalDeposits() or deallocate()
        //
        // If balanceAfter > balanceBefore: Do nothing (no accounting update)
        // If balanceAfter == balanceBefore: No accounting update
        // NOTE: This misses cases where deposit+withdrawal happened in same multicall

        // SECURITY FIX Issue #3 (security_issues_5nov2025.md): Maintain activeStrategies invariant
        // Remove strategy when BOTH allocations and externalDeposits are zero
        // This prevents stale entries that cause:
        //   - Valuer mispricing (includes stale strategy values)
        //   - Increased gas costs for enumeration
        //   - Potential DoS if many stale entries accumulate
        if (allocations[strategyId] == 0 && externalDeposits[strategyId] == 0) {
            _removeFromActiveStrategies(strategyId);
        }
    }


    /// @notice Remove a strategy from the active list
    /// @param strategyId The strategy to remove
    function _removeFromActiveStrategies(bytes32 strategyId) internal {
        // O(1) operation with EnumerableSet
        activeStrategies.remove(strategyId);
    }

    /// @notice Get strategy value including yield from valuer
    /// @param strategyId The strategy identifier
    /// @return value The strategy value including any yield
    function _getStrategyValue(bytes32 strategyId) internal view returns (uint256 value) {
        // Try to get value from valuer, fallback to allocation if valuer call fails
        (bool success, bytes memory data) = valuer.staticcall(
            abi.encodeWithSignature("getValue(bytes32)", strategyId)
        );

        if (success && data.length >= 32) {
            value = abi.decode(data, (uint256));
            // If valuer returns 0, use allocation as fallback
            if (value == 0) {
                value = allocations[strategyId];
            }
        } else {
            // Fallback to allocation if valuer call fails
            value = allocations[strategyId];
        }
    }

    /// @notice Update cached valuation from fresh valuer call
    /// @dev Called by state-modifying functions to refresh cache for time-bounded fallback
    function _updateCachedValuation() internal {
        uint256 balance = IERC20(asset).balanceOf(address(this));

        // Donation-resistant calculation (same as realAssets)
        uint256 allocatedInAdapter = totalAllocations > totalExternalDeposits
            ? totalAllocations - totalExternalDeposits
            : 0;

        uint256 excessIdle = balance > allocatedInAdapter
            ? balance - allocatedInAdapter
            : 0;

        // SECURITY FIX (security_issues_5nov2025_3.md Issue #1): Use single aggregated strategy ID
        bytes32 totalId = keccak256(abi.encodePacked("ESCROW_TOTAL", address(this)));

        // Try to get fresh valuation
        (bool success, bytes memory data) = valuer.staticcall{gas: VALUER_GAS_STIPEND}(
            abi.encodeWithSignature("getValue(bytes32)", totalId)
        );

        if (success && data.length >= 32) {
            uint256 totalValue = abi.decode(data, (uint256));
            uint256 totalValueAdj = totalValue > excessIdle
                ? totalValue - excessIdle
                : 0;

            if (totalValueAdj > 0) {
                // Update cache with fresh valuation
                cachedValuation = totalValueAdj;
                cachedValuationTimestamp = block.timestamp;
            }
        }
        // If valuer call fails, keep existing cache (don't update)
    }

    /// @inheritdoc IUniversalAdapterEscrow
    function getCachedValuation() external view returns (uint256 value, uint256 timestamp, bool isStale) {
        value = cachedValuation;
        timestamp = cachedValuationTimestamp;

        // Cache is stale if more than MAX_CACHED_VALUATION_AGE old
        isStale = cachedValuationTimestamp == 0 ||
                  block.timestamp - cachedValuationTimestamp > MAX_CACHED_VALUATION_AGE;
    }

    /// @notice Receive ETH
    /// @dev COMMENTED OUT FOR NOW AS WE DON'T ACCEPT ETH
    // receive() external payable {}
}