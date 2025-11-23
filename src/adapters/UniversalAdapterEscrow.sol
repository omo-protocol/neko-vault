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

    // Prevents unbounded activeStrategies enumeration from causing DoS of deposits/withdrawals
    uint256 private constant VALUER_GAS_STIPEND = 200000;

    // Time-bounded fallback to cached valuation
    // Maximum age of cached valuation before rejecting fallback
    uint256 private constant MAX_CACHED_VALUATION_AGE = 4 hours;

    // (Cached Valuation Exploitation): Emergency mode haircut
    // 5% haircut makes most arbitrage opportunities unprofitable while maintaining vault liveness
    uint256 public constant EMERGENCY_HAIRCUT = 500; // 5% in basis points

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

    // Transient variable used during deallocate to enable early exit when sufficient assets recovered
    // Set to target withdrawal amount before multicall, reset to 0 after
    uint256 private withdrawTarget;

    // (Cached Valuation Exploitation): Emergency mode state
    // When enabled, applies conservative haircut to all valuations
    // Prevents arbitrage during valuer downtime while maintaining vault liveness
    bool public emergencyMode;
    uint256 public emergencyModeActivatedAt;

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
    /// @notice Allocate assets from vault to strategy
    /// @dev SECURITY FIX: liquidityData MUST contain empty calls array
    ///      This prevents deposit failures when calls have hardcoded amounts that don't match actual deposits.
    ///      Agents execute strategies separately via executeStrategy() with dynamic amounts based on actual balance.
    /// @param data Encoded: (bytes32 strategyId, uint256 ignored, bool ignored, Call[] calls)
    ///             - calls MUST be empty array (enforced)
    /// @param assets Amount of assets transferred from vault
    function allocate(
        bytes memory data,
        uint256 assets,
        bytes4,
        address
    ) external override onlyVault notPaused returns (bytes32[] memory ids, int256 change) {
        if (data.length == 0) revert InvalidData();

        // Decode allocation data
        (bytes32 strategyId, , , Call[] memory calls) =
            abi.decode(data, (bytes32, uint256, bool, Call[]));

        // Validate strategy exists and is active
        if (!strategies[strategyId].active) revert StrategyNotActive();
        if (assets == 0) revert InvalidAmount();

        // SECURITY: Enforce empty calls array in liquidityData
        // Prevents curator from configuring hardcoded amounts that mismatch actual deposits
        // Agents execute strategies separately with correct amounts via executeStrategy()
        if (calls.length > 0) {
            revert LiquidityDataMustHaveEmptyCalls();
        }

        // Update allocation tracking with transferred amount
        allocations[strategyId] += assets;
        totalAllocations += assets;

        // Add to active strategies if not already present (O(1) operation)
        activeStrategies.add(strategyId);

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
        bool withdrawalsExecuted = false; // Track if we actually executed withdrawals

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
                    withdrawalsExecuted = true; // Mark that we executed withdrawals

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

                // SECURITY FIX: Valuer-based synchronization after withdrawal
                // Sync externalDeposits to actual remaining value in protocol using valuer
                // This prevents ghost funds by accurately tracking principal + yield
                //
                // Benefits over old symmetric reduction:
                // 1. Handles yield correctly (increase in value tracked)
                // 2. Self-correcting (syncs to actual on-chain value)
                // 3. Protocol-agnostic (no protocol-specific queries needed)
                // 4. Uses existing valuer infrastructure
                //
                // Note: balanceAfter already defined at line 262
                if (balanceAfter > adapterBalance) {
                    uint256 withdrawnAmount = balanceAfter - adapterBalance;
                    if (withdrawnAmount > assets) withdrawnAmount = assets;

                    // Sync externalDeposits to actual protocol value via valuer
                    _syncExternalDepositsWithValuer(strategyId, withdrawnAmount, assets);
                }
            }
        }

        // SECURITY FIX (security_issues_5nov2025_7.md Issue #1): Effective slippage protection
        // Enforce minimum balance INCREASE achieved by withdrawCalls (deltaIncrease) to protect against MEV/slippage
        //
        // VULNERABILITY (OLD APPROACH):
        // - Checked total balance >= minAmountOut (ineffective)
        // - Constrained by minAmountOut <= assets (made it redundant)
        // - Didn't measure actual delta from withdrawCalls
        // - Allowed MEV bots to sandwich DEX swaps while transaction still succeeds
        // - Loss absorbed by remaining depositors as reduced pool value
        //
        // NEW APPROACH:
        // - Measure actual delta increase from withdrawCalls execution
        // - Compare delta to minAmountOut (slippage tolerance)
        // - Only enforce when withdrawals were actually executed
        // - Protects against silent principal loss from poor execution prices
        //
        // Only enforce when:
        // 1. Not force deallocate (force ignores calls anyway)
        // 2. minAmountOut > 0 (slippage protection requested)
        // 3. We actually executed withdrawCalls (withdrawalsExecuted == true)
        //
        if (
            caller != FORCE_DEALLOCATE_SELECTOR &&
            minAmountOut > 0 &&
            withdrawalsExecuted
        ) {
            // Measure delta increase from before withdrawCalls (adapterBalance) to current balance
            uint256 balanceAfterCheck = IERC20(asset).balanceOf(address(this));
            uint256 deltaIncrease = balanceAfterCheck > adapterBalance
                ? balanceAfterCheck - adapterBalance
                : 0;

            // Enforce minimum delta increase to protect against MEV/slippage
            // This ensures the withdrawCalls achieved acceptable execution price
            if (deltaIncrease < minAmountOut) {
                revert SlippageTooHigh();
            }
        }

        // SECURITY FIX (security_issues_5nov2025_6.md Issue #1): Forward surplus to vault
        // If withdrawals returned more than requested assets, forward the surplus immediately.
        // This prevents externalDeposits from staying overstated and underpricing totalAssets.
        // Done after slippage checks so availability checks use the full balance.
        // Only forward if we actually executed withdrawals (not in Scenario 1 where balance covers all).
        if (caller != FORCE_DEALLOCATE_SELECTOR && withdrawalsExecuted) {
            uint256 _bal = IERC20(asset).balanceOf(address(this));
            if (_bal > assets) {
                SafeERC20Lib.safeTransfer(asset, parentVault, _bal - assets);
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

        // SECURITY FIX: Removed _updateCachedValuation() call to prevent cache poisoning
        // from stale off-chain valuer data. Keepers should call refreshCachedValuation()
        // after updating the valuer with fresh data.

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
        uint256 balance = IERC20(asset).balanceOf(address(this));

        // Donation-resistant valuation: ignore excess idle balance beyond allocated-in-adapter
        uint256 allocatedInAdapter = totalAllocations > totalExternalDeposits
            ? totalAllocations - totalExternalDeposits
            : 0;

        uint256 excessIdle = balance > allocatedInAdapter
            ? balance - allocatedInAdapter
            : 0;

        bytes32 totalId = keccak256(abi.encodePacked("ESCROW_TOTAL", address(this)));

        (bool success, bytes memory data) = valuer.staticcall{gas: VALUER_GAS_STIPEND}(
            abi.encodeWithSignature("getValue(bytes32)", totalId)
        );

        if (success && data.length >= 32) {
            uint256 totalValue = abi.decode(data, (uint256));

            uint256 totalValueAdj;
            if (totalValue >= excessIdle) {
                totalValueAdj = totalValue - excessIdle;
            } else {
                totalValueAdj = totalValue + allocatedInAdapter;
            }

            // (Cached Valuation Exploitation): Apply emergency haircut if enabled
            // Valuer is working - return donation-adjusted value with haircut if in emergency mode
            if (totalValueAdj > 0) {
                if (emergencyMode) {
                    // Apply 5% conservative haircut during emergency mode
                    return totalValueAdj * (10000 - EMERGENCY_HAIRCUT) / 10000;
                }
                return totalValueAdj;
            }

            // Valuer returned 0 - check if this is legitimate (no allocations) or error
            // If no allocations, 0 is the correct value (cold start or fully deallocated)
            if (totalAllocations == 0) {
                return 0;  // Legitimate 0 value when nothing allocated
            }

            // Check emergency mode for fallback behavior
            if (emergencyMode) {
                // In emergency mode: use cached valuation with haircut
                if (cachedValuationTimestamp > 0 &&
                    block.timestamp - cachedValuationTimestamp <= MAX_CACHED_VALUATION_AGE) {
                    // Apply haircut to cached value for conservative pricing
                    return cachedValuation * (10000 - EMERGENCY_HAIRCUT) / 10000;
                }

                // No valid cache: use externalDeposits as floor with haircut
                // This is most conservative - only counts confirmed protocol deposits
                return totalExternalDeposits * (10000 - EMERGENCY_HAIRCUT) / 10000;
            }

            // Normal mode (not emergency): revert to force emergency activation
            // This prevents using stale cache without explicit owner acknowledgment
            revert ValuationUnavailable();
        }

        // Cold start case: no allocations, valuer failed to respond
        // This is safe to return 0 since there's nothing allocated
        if (totalAllocations == 0) {
            return 0;
        }

        // SECURITY FIX Issue #2: Valuer call failed and we have allocations
        // Check emergency mode for fallback behavior
        if (emergencyMode) {
            // In emergency mode: use cached valuation with haircut
            if (cachedValuationTimestamp > 0 &&
                block.timestamp - cachedValuationTimestamp <= MAX_CACHED_VALUATION_AGE) {
                // Apply haircut to cached value for conservative pricing
                return cachedValuation * (10000 - EMERGENCY_HAIRCUT) / 10000;
            }

            // No valid cache: use externalDeposits as floor with haircut
            // This is most conservative - only counts confirmed protocol deposits
            return totalExternalDeposits * (10000 - EMERGENCY_HAIRCUT) / 10000;
        }

        // Normal mode (not emergency): revert to force emergency activation
        // Operator must enable emergency mode when valuation service is unavailable
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
    function executeStrategy(
        bytes32 strategyId,
        Call[] calldata calls
    ) external onlyStrategyAgentOrOwner(strategyId) notPaused {
        // Balance increases (withdrawals) must use executeStrategyWithSlippage() or deallocate()
        // to ensure proper externalDeposits accounting via symmetric reduction
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));

        _executeMulticall(strategyId, calls, false);

        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        if (balanceAfter > balanceBefore) revert InvalidAmount();

        // SECURITY FIX: Removed _updateCachedValuation() call to prevent cache poisoning
        emit StrategyExecuted(strategyId, msg.sender);
    }

    /// @notice Execute strategy calls with additional slippage protection
    /// @param strategyId The strategy identifier
    /// @param calls Array of calls to execute
    /// @param minBalanceIncrease Minimum balance increase required (for withdrawals), 0 to skip check
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

            if (balanceAfter > balanceBefore) {
                uint256 withdrawnAmount = balanceAfter - balanceBefore;
                if (withdrawnAmount > minBalanceIncrease) withdrawnAmount = minBalanceIncrease;

                // Sync externalDeposits to actual protocol value via valuer
                _syncExternalDepositsWithValuer(strategyId, withdrawnAmount, minBalanceIncrease);
            }

            if (balanceAfter > balanceBefore + minBalanceIncrease) {
                SafeERC20Lib.safeTransfer(
                    asset,
                    parentVault,
                    balanceAfter - (balanceBefore + minBalanceIncrease)
                );
            }
        }

        emit StrategyExecuted(strategyId, msg.sender);
    }

    /// @notice Execute strategy calls with circuit breaker bypassed
    /// @param strategyId The strategy identifier
    /// @param calls Array of calls to execute
    function executeStrategyBypassCircuitBreaker(
        bytes32 strategyId,
        Call[] calldata calls
    ) external onlyStrategyAgentOrOwner(strategyId) notPaused {
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));

        _executeMulticall(strategyId, calls, true);

        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        if (balanceAfter > balanceBefore) revert InvalidAmount();

        emit StrategyExecuted(strategyId, msg.sender);
    }

    /// @inheritdoc IUniversalAdapterEscrow
    function executePreConfigured(bytes32 strategyId) external onlyStrategyAgentOrOwner(strategyId) notPaused {
        StrategyConfig memory strategy = strategies[strategyId];
        if (strategy.preConfiguredData.length == 0) revert InvalidData();

        // Decode pre-configured calls
        Call[] memory calls = abi.decode(strategy.preConfiguredData, (Call[]));
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));

        _executeMulticall(strategyId, calls, false);

        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        if (balanceAfter > balanceBefore) revert InvalidAmount();

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
    /// @dev
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
    /// @notice Sync external deposits for specific strategies with actual values
    /// @param strategyIds Array of strategy IDs to update
    /// @param newValues Array of new external deposit values for each strategy
    function syncExternalDepositsPerStrategy(bytes32[] calldata strategyIds, uint256[] calldata newValues) external onlyOwner {
        require(strategyIds.length == newValues.length, "Length mismatch");
        require(strategyIds.length > 0, "Empty arrays");

        uint256 totalDelta = 0;

        for (uint256 i = 0; i < strategyIds.length; i++) {
            bytes32 strategyId = strategyIds[i];
            uint256 oldValue = externalDeposits[strategyId];
            uint256 newValue = newValues[i];

            // SECURITY: Can only reduce, never increase (removing ghost, not creating it)
            require(newValue <= oldValue, "Can only reduce ghost deposits");

            uint256 delta = oldValue - newValue;
            externalDeposits[strategyId] = newValue;
            totalDelta += delta;

            // If both allocation and externalDeposits are now zero, remove from active set
            if (allocations[strategyId] == 0 && newValue == 0) {
                _removeFromActiveStrategies(strategyId);
            }

            emit ExternalDepositSyncedPerStrategy(strategyId, oldValue, newValue, delta);
        }

        // Update total to maintain invariant: totalExternalDeposits == sum(externalDeposits[•])
        totalExternalDeposits -= totalDelta;

        // VALIDATION: New value should make sense given valuer's current report
        uint256 balance = IERC20(asset).balanceOf(address(this));
        uint256 newMinKnown = balance + totalExternalDeposits;

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

        // SECURITY FIX: Invalidate stale cache (removed _updateCachedValuation() call)
        // Keepers should call refreshCachedValuation() after updating valuer with fresh data
        cachedValuationTimestamp = 0;

        emit ExternalDepositsSyncedBatch(msg.sender, totalDelta, totalExternalDeposits);
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

        // SECURITY FIX: Removed _updateCachedValuation() call to prevent cache poisoning
        // from stale off-chain valuer data. Keepers should call refreshCachedValuation()
        // after updating the valuer with fresh data.

        emit ExternalDepositsReduced(strategyId, current, newPerStrategy, delta);
    }

    /// @notice Refresh cached valuation from current valuer state
    /// @dev SECURITY FIX: Separated from state-changing functions to prevent cache poisoning.
    ///      Should be called by keepers AFTER valuer has been updated with fresh off-chain data.
    ///      This ensures cache contains only validated, keeper-signed valuations, not stale data
    ///      from the same transaction as state changes.
    function refreshCachedValuation() external {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        uint256 allocatedInAdapter = totalAllocations > totalExternalDeposits
            ? totalAllocations - totalExternalDeposits : 0;
        uint256 excessIdle = balance > allocatedInAdapter ? balance - allocatedInAdapter : 0;

        bytes32 totalId = keccak256(abi.encodePacked("ESCROW_TOTAL", address(this)));

        (bool success, bytes memory data) = valuer.staticcall{gas: VALUER_GAS_STIPEND}(
            abi.encodeWithSignature("getValue(bytes32)", totalId)
        );

        if (success && data.length >= 32) {
            uint256 totalValue = abi.decode(data, (uint256));
            uint256 totalValueAdj;

            if (totalValue >= excessIdle) {
                totalValueAdj = totalValue - excessIdle;
            } else {
                totalValueAdj = totalValue + allocatedInAdapter;
            }

            // SECURITY: Sanity check - reject obviously wrong values
            if (totalAllocations > 0) {
                require(totalValueAdj >= (totalAllocations * 80) / 100, "Valuation too low - check valuer");
                require(totalValueAdj <= (totalAllocations * 150) / 100, "Valuation too high - check valuer");
            }

            if (totalValueAdj > 0) {
                cachedValuation = totalValueAdj;
                cachedValuationTimestamp = block.timestamp;
                emit CachedValuationRefreshed(totalValueAdj, block.timestamp);
            }
        } else {
            revert("Valuer call failed");
        }
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

    /// @notice Get idle balance for a specific strategy
    /// @dev Idle balance = assets allocated to strategy but not yet deployed to external protocol
    ///      This helps agents monitor which strategies need execution.
    ///      After liquidityData empty calls enforcement, all allocations start as idle
    ///      until agents manually execute via executeStrategy().
    /// @param strategyId Strategy to check
    /// @return idle Amount of idle assets available for execution
    function getIdleBalance(bytes32 strategyId) external view returns (uint256 idle) {
        uint256 allocated = allocations[strategyId];
        uint256 deployed = externalDeposits[strategyId];

        // Idle = allocated but not deployed
        if (allocated > deployed) {
            return allocated - deployed;
        }

        // Safety: if deployed >= allocated, no idle balance
        return 0;
    }

    /// @notice Get idle assets that are not allocated to any strategy
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
    /// @dev
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
        // Defer aggregate reduction to admin/keeper sync via syncExternalDepositsPerStrategy() or deallocate()
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

    /// @notice Sync externalDeposits to actual protocol value after withdrawal using valuer
    /// @dev SECURITY FIX: Prevents ghost funds by syncing to actual remaining value from valuer
    /// @param strategyId The strategy that was withdrawn from
    /// @param withdrawnAmount Amount that was withdrawn (balance increase measured)
    /// @param requestedAssets Amount that was requested in the deallocate call
    function _syncExternalDepositsWithValuer(
        bytes32 strategyId,
        uint256 withdrawnAmount,
        uint256 requestedAssets
    ) internal {
        // Get current tracked value
        uint256 trackedValue = externalDeposits[strategyId];

        // If nothing tracked, nothing to sync
        if (trackedValue == 0) return;

        // Try to get actual remaining value from valuer
        (bool success, bytes memory data) = valuer.staticcall{gas: VALUER_GAS_STIPEND}(
            abi.encodeWithSignature("getValue(bytes32)", strategyId)
        );

        if (success && data.length >= 32) {
            uint256 actualValue = abi.decode(data, (uint256));

            // If valuer returns 0, it means either:
            // 1. Strategy actually has 0 value (fully withdrawn)
            // 2. Valuer not configured for this strategy (test/dev environment)
            // In case 2, fall back to conservative estimate
            bool valuerConfigured = (actualValue > 0 || trackedValue == 0);

            // Sync externalDeposits to actual value if valuer is configured
            if (valuerConfigured && actualValue != trackedValue) {
                int256 delta;

                if (actualValue < trackedValue) {
                    // Value decreased (withdrawal or loss)
                    uint256 decrease = trackedValue - actualValue;

                    // Sanity check: decrease should be close to withdrawn amount
                    // Allow 20% variance for price movements, fees, slippage, yield
                    uint256 expectedMin = (withdrawnAmount * 80) / 100;
                    uint256 expectedMax = (withdrawnAmount * 120) / 100;

                    if (decrease < expectedMin || decrease > expectedMax) {
                        // Unexpected decrease - emit warning
                        emit UnexpectedValueChange(
                            strategyId,
                            withdrawnAmount,
                            decrease,
                            withdrawnAmount,
                            "Value decrease outside expected range"
                        );
                    }

                    // Update per-strategy accounting
                    externalDeposits[strategyId] = actualValue;

                    // Safe total reduction with desync protection
                    if (decrease > totalExternalDeposits) {
                        // Desync detected - shouldn't happen but handle gracefully
                        emit AccountingDesyncDetected(strategyId, decrease, totalExternalDeposits);
                        totalExternalDeposits = 0;
                    } else {
                        totalExternalDeposits -= decrease;
                    }

                    delta = -int256(decrease);
                } else {
                    // Value increased (yield accrued between last sync and now)
                    uint256 increase = actualValue - trackedValue;

                    // Update accounting to include accrued yield
                    externalDeposits[strategyId] = actualValue;
                    totalExternalDeposits += increase;

                    emit YieldAccrued(strategyId, increase);

                    delta = int256(increase);
                }

                emit ExternalDepositsValuerSynced(strategyId, trackedValue, actualValue, delta);
            } else {
                // Valuer returned 0 but we have trackedValue > 0
                // This means valuer is not configured - use conservative fallback
                _applyConservativeReduction(strategyId, trackedValue, withdrawnAmount, false);
            }
        } else {
            // Valuer call failed - determine if we should warn
            bool cacheStale = block.timestamp - cachedValuationTimestamp >= MAX_CACHED_VALUATION_AGE;
            _applyConservativeReduction(strategyId, trackedValue, withdrawnAmount, cacheStale);
        }
    }

    /// @notice Apply conservative reduction when valuer unavailable
    /// @param strategyId The strategy identifier
    /// @param trackedValue Current tracked external deposits
    /// @param withdrawnAmount Amount withdrawn
    /// @param emitWarning Whether to emit warning about valuer unavailability
    function _applyConservativeReduction(
        bytes32 strategyId,
        uint256 trackedValue,
        uint256 withdrawnAmount,
        bool emitWarning
    ) internal {
        // Conservative estimate: reduce by withdrawn amount
        uint256 conservativeReduction = withdrawnAmount;

        // Apply two-phase cap for safety (prevents underflow)
        uint256 maxReduction = trackedValue < totalExternalDeposits ? trackedValue : totalExternalDeposits;
        if (conservativeReduction > maxReduction) {
            conservativeReduction = maxReduction;
        }

        if (conservativeReduction > 0) {
            externalDeposits[strategyId] = trackedValue - conservativeReduction;
            totalExternalDeposits -= conservativeReduction;

            if (emitWarning) {
                emit UnexpectedValueChange(
                    strategyId,
                    withdrawnAmount,
                    conservativeReduction,
                    withdrawnAmount,
                    "Valuer unavailable - using conservative estimate"
                );
            } else {
                emit ExternalDepositsValuerSynced(
                    strategyId,
                    trackedValue,
                    trackedValue - conservativeReduction,
                    -int256(conservativeReduction)
                );
            }
        }
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

        // Use single aggregated strategy ID
        bytes32 totalId = keccak256(abi.encodePacked("ESCROW_TOTAL", address(this)));

        // Try to get fresh valuation
        (bool success, bytes memory data) = valuer.staticcall{gas: VALUER_GAS_STIPEND}(
            abi.encodeWithSignature("getValue(bytes32)", totalId)
        );

        if (success && data.length >= 32) {
            uint256 totalValue = abi.decode(data, (uint256));

            // Semantic-agnostic adjustment
            // Same logic as realAssets() to handle both valuer semantic interpretations
            uint256 totalValueAdj;
            if (totalValue >= excessIdle) {
                totalValueAdj = totalValue - excessIdle;
            } else {
                totalValueAdj = totalValue + allocatedInAdapter;
            }

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

    /* EMERGENCY MODE FUNCTIONS */

    /// @notice Enable emergency mode when valuer is unavailable
    /// @dev Applies 5% conservative haircut to prevent arbitrage during valuer downtime
    /// @dev Only owner can enable emergency mode
    function enableEmergencyMode() external onlyOwner {
        if (emergencyMode) revert EmergencyModeAlreadyEnabled();

        emergencyMode = true;
        emergencyModeActivatedAt = block.timestamp;

        emit EmergencyModeEnabled(block.timestamp, "Valuer unavailable");
    }

    /// @notice Disable emergency mode when valuer is restored
    /// @dev Requires valuer to be working before disabling emergency mode
    /// @dev Only owner can disable emergency mode
    function disableEmergencyMode() external onlyOwner {
        if (!emergencyMode) revert EmergencyModeNotEnabled();

        // Verify valuer is actually working before disabling emergency mode
        bytes32 totalId = keccak256(abi.encodePacked("ESCROW_TOTAL", address(this)));
        (bool success, bytes memory data) = valuer.staticcall{gas: VALUER_GAS_STIPEND}(
            abi.encodeWithSignature("getValue(bytes32)", totalId)
        );

        // Valuer must return valid data (even if 0 is valid when totalAllocations == 0)
        if (!success || data.length < 32) revert ValuerStillUnavailable();

        uint256 totalValue = abi.decode(data, (uint256));

        // If we have allocations, valuer must return non-zero
        if (totalAllocations > 0 && totalValue == 0) revert ValuerStillUnavailable();

        uint256 duration = block.timestamp - emergencyModeActivatedAt;
        emergencyMode = false;
        emergencyModeActivatedAt = 0;

        emit EmergencyModeDisabled(block.timestamp, duration);
    }

    /// @notice Receive ETH
    /// @dev COMMENTED OUT FOR NOW AS WE DON'T ACCEPT ETH
    // receive() external payable {}
}
