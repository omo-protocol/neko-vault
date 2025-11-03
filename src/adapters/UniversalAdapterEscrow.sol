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

    // Whitelist management
    mapping(address => mapping(bytes4 => WhitelistConfig)) public functionWhitelist;

    // Pause state
    bool public paused;

    // Access control
    address public owner;

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

        // Decode deallocation data with slippage protection parameter
        (bytes32 strategyId, uint256 minAmountOut, , Call[] memory withdrawCalls) =
            abi.decode(data, (bytes32, uint256, bool, Call[]));

        // IMPORTANT: No allocation validation here - users should be able to withdraw
        // idle assets, profits, or do emergency withdrawals even from strategies with 0 allocation

        uint256 adapterBalance = IERC20(asset).balanceOf(address(this));
        uint256 actualAmount;

        // SECURITY FIX: For forceDeallocate, ignore calls but use same data format
        if (caller == FORCE_DEALLOCATE_SELECTOR) {
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
                    try this.externalExecuteMulticall(strategyId, withdrawCalls) {
                        // Success - balance increased from protocol withdrawal
                    } catch {
                        // Failure - protocol couldn't provide liquidity
                        // Continue with current balance (partial fulfillment)
                        // Vault's transferFrom will naturally limit to available balance
                    }
                }

                uint256 balanceAfter = IERC20(asset).balanceOf(address(this));

                // CRITICAL FIX: Cap actualAmount to requested assets to prevent accounting mismatch
                // If protocol returns more than needed (e.g., balanceAfter=900, assets=800),
                // we MUST cap to assets=800, otherwise:
                // - Adapter returns change=-900
                // - Vault decreases caps by 900
                // - But vault only pulls 800 via transferFrom
                // - Result: 100 token accounting loss!

                actualAmount = balanceAfter;

                // Cap to requested amount (prevents accounting mismatch)
                if (actualAmount > assets) {
                    actualAmount = assets;
                }

                // NOTE: Removed valuer cap (was Issue #2) - physical availability is the only limit
                // If we don't have enough, vault's transferFrom will revert with insufficient balance
            }
        }

        // SECURITY FIX: Slippage protection for liquidity adapter withdrawals
        // Prevents MEV sandwich attacks when withdrawal involves DEX swaps
        // minAmountOut = 0 disables check (backward compatible)
        // Force deallocate bypasses slippage check as it doesn't execute withdrawal calls
        if (caller != FORCE_DEALLOCATE_SELECTOR && minAmountOut > 0 && actualAmount < minAmountOut) {
            revert SlippageTooHigh();
        }

        // Update allocation - handle case where actualAmount exceeds tracked allocation
        uint256 allocationDecrease = actualAmount > allocations[strategyId]
            ? allocations[strategyId]
            : actualAmount;
        allocations[strategyId] -= allocationDecrease;
        totalAllocations -= allocationDecrease;

        // Remove from active strategies if fully deallocated
        if (allocations[strategyId] == 0) {
            _removeFromActiveStrategies(strategyId);
        }

        // Transfer assets back to vault
        // The vault will pull the assets using transferFrom

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
        uint256 minKnownValue = totalAllocations;

        // Call getTotalValue which aggregates all strategy values + idle assets
        (bool success, bytes memory data) = valuer.staticcall(
            abi.encodeWithSignature("getTotalValue(address)", address(this))
        );

        if (success && data.length >= 32) {
            uint256 totalValue = abi.decode(data, (uint256));

            // Adjust totalValue to exclude donation excess
            uint256 totalValueAdj = totalValue > excessIdle
                ? totalValue - excessIdle
                : 0;

            // CRITICAL SECURITY FIX Issue #6 (Tolerance-Based Approach):
            // Balance between preventing malicious underpricing and allowing legitimate losses
            //
            // PROBLEM WITH STRICT MINIMUM:
            // - totalExternalDeposits tracks historical flows, not current value
            // - When deposits have slippage/fees (e.g., 800 sent → 760 value), creates "ghost"
            // - Strict check (totalValue >= minKnownValue) causes persistent overpricing
            // - Ghost accumulates with each loss: 5 KHYPE loss → permanent 5 KHYPE overprice
            //
            // SOLUTION: Tolerance-Based Validation
            // - Allow valuer values within 10% of minimum (accounts for legitimate losses)
            // - Reject valuer values >10% below minimum (likely malicious/buggy)
            //
            // LEGITIMATELY ACCEPTED (totalValueAdj >= 90% of minKnownValue):
            // ✅ Swap slippage: 0.5-2% loss
            // ✅ Protocol deposit fees: 0.1-1% loss
            // ✅ Small trading losses: < 10%
            // ✅ Prevents ghost accumulation from normal operations
            // ✅ Profits (totalValueAdj > minKnownValue) always accepted
            //
            // ATTACKS PREVENTED (totalValueAdj < 90% of minKnownValue):
            // ❌ 50% malicious underpricing → returns minKnownValue
            // ❌ 90% compromised valuer → returns minKnownValue
            // ❌ Oracle manipulation > 10% → returns minKnownValue
            // ❌ Donation-based inflation → excessIdle excluded from totalValueAdj
            //
            // TRADE-OFF:
            // - Losses > 10% still create small ghost (but rare in normal operations)
            // - Attacker needs to manipulate valuer by >10% (much harder)
            // - Prevents persistent overpricing from normal slippage/fees
            // - Prevents donation-based value extraction attacks

            // Calculate 90% threshold (allow up to 10% loss)
            // Use 9000 / 10000 to avoid precision loss
            uint256 lossToleranceThreshold = (minKnownValue * 9000) / 10000;

            if (totalValueAdj >= lossToleranceThreshold) {
                // Within tolerance - accept valuer's value (adjusted for donations)
                // This handles:
                // - Normal profits (totalValueAdj > minKnownValue)
                // - Legitimate losses (minKnownValue > totalValueAdj >= 90% minKnownValue)
                // - Ignores donation-based inflation attempts
                return totalValueAdj;
            }

            // Extreme undervaluation (>10% below minimum)
            // Likely malicious/buggy valuer - protect holders by using minimum
            return minKnownValue;
        }

        // CRITICAL SECURITY FIX Issue #4: Proper fallback when valuer fails
        // Use totalAllocations (principal) as fallback instead of balance + externalDeposits
        // This prevents donation inflation even when valuer fails
        // Misses yield but safer than allowing donation-based attacks
        return minKnownValue;
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
        // Cannot remove strategy with active allocation
        if (allocations[strategyId] > 0) revert InvalidStrategy();

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
        _executeMulticall(strategyId, calls, false);
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
        }

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
        _executeMulticall(strategyId, calls, true);
        emit StrategyExecuted(strategyId, msg.sender);
    }

    /// @inheritdoc IUniversalAdapterEscrow
    function executePreConfigured(bytes32 strategyId) external onlyStrategyAgentOrOwner(strategyId) notPaused {
        StrategyConfig memory strategy = strategies[strategyId];
        if (strategy.preConfiguredData.length == 0) revert InvalidData();

        // Decode pre-configured calls
        Call[] memory calls = abi.decode(strategy.preConfiguredData, (Call[]));

        _executeMulticall(strategyId, calls, false);
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
    /// @notice Manually adjust totalExternalDeposits to remove ghost amounts
    /// @dev SECURITY FIX Issue #6: Manual intervention for large losses (>10%) that exceeded tolerance
    ///      SECURITY FIX Issue #8: No pause check - owner can fix mispricing even during pause
    ///
    ///      USE CASES:
    ///      - Market crash causes >10% loss → ghost accumulates
    ///      - Strategy exits with high slippage during black swan events
    ///      - Periodic maintenance to clear accumulated small ghosts
    ///      - After large losses from liquidations/exploits in external protocols
    ///      - CRITICAL: Fix mispricing during pause to enable accurate emergency operations
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

        (bool success, bytes memory data) = valuer.staticcall(
            abi.encodeWithSignature("getTotalValue(address)", address(this))
        );

        if (success && data.length >= 32) {
            uint256 valuerValue = abi.decode(data, (uint256));

            // SAFETY CHECK: New minimum shouldn't be too far below valuer value
            // Allow up to 20% below valuer for safety margin (more conservative than 10% tolerance)
            require(valuerValue >= (newMinKnown * 8000) / 10000, "New value too low vs valuer");
        }

        uint256 oldValue = totalExternalDeposits;
        totalExternalDeposits = newTotalExternalDeposits;

        emit ExternalDepositsSynced(msg.sender, oldValue, newTotalExternalDeposits);
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
    /// @dev SECURITY FIX Issue #6: Helper function to monitor when manual sync might be needed
    ///      SECURITY FIX: Updated to use donation-resistant valuation (consistent with realAssets)
    ///
    ///      WHAT IS A GHOST AMOUNT:
    ///      Ghost = The amount by which minKnownValue exceeds the valuer's reported real value
    ///      This happens when:
    ///      - Large losses (>10%) exceed the tolerance threshold
    ///      - Multiple small losses accumulate over time
    ///      - Protocol liquidations or exploits cause value loss
    ///
    ///      WHEN TO SYNC:
    ///      - If ghost > 0.5% of totalAssets: Consider syncing
    ///      - If ghost > 2% of totalAssets: Should sync soon
    ///      - If ghost > 5% of totalAssets: Sync urgently
    ///
    ///      Example:
    ///      - totalAllocations = 1000 (principal)
    ///      - Valuer reports: 800 (real current value after 20% loss)
    ///      - Ghost = 1000 - 800 = 200 (20% overpricing!)
    ///
    /// @return ghost The amount of overpricing (0 if no ghost detected)
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
                revert CallFailed(i, returnData);
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
        } else if (balanceAfter > balanceBefore) {
            // Net balance increased - likely withdrawal from external protocol
            // NOTE: Could also be profit/yield, causing externalDeposits undercount
            uint256 withdrawn = balanceAfter - balanceBefore;

            // SECURITY FIX Issue #9: Prevent desynchronization between per-strategy and aggregate
            // Cap decrease to both per-strategy AND aggregate to prevent underflow
            uint256 decreaseAmount = withdrawn;

            // Cap to per-strategy external deposits
            if (decreaseAmount > externalDeposits[strategyId]) {
                decreaseAmount = externalDeposits[strategyId];
            }

            // Cap to total external deposits (prevents desync if aggregate is lower)
            if (decreaseAmount > totalExternalDeposits) {
                decreaseAmount = totalExternalDeposits;
            }

            externalDeposits[strategyId] -= decreaseAmount;
            totalExternalDeposits -= decreaseAmount;
        }
        // If balanceAfter == balanceBefore, no accounting update
        // NOTE: This misses cases where deposit+withdrawal happened in same multicall
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


    /// @notice Receive ETH
    /// @dev COMMENTED OUT FOR NOW AS WE DON'T ACCEPT ETH
    // receive() external payable {}
}