// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IERC20} from "./interfaces/IERC20.sol";
import {IVaultV2} from "./interfaces/IVaultV2.sol";
import {SafeERC20Lib} from "./libraries/SafeERC20Lib.sol";

/**
 * @title VaultTimeLockWrapper
 * @notice SECURE VERSION - Enforces 7-day lockup on VaultV2 deposits with transferable ERC20 receipt tokens
 *
 * @dev Security Fixes Applied:
 *      ✅ Proper FIFO removal (shift left instead of swap-with-last)
 *      ✅ Per-batch lock enforcement (checks every batch during burn)
 *      ✅ Approval required for onBehalf deposits (prevents DoS)
 *      ✅ Emergency withdraw properly redeems from vault
 *      ✅ Allowance checked/deducted in shares not assets
 *      ✅ Max batch limit per user (prevents unbounded loops)
 *
 * @dev Key Features:
 *      - Mints ERC20 receipt tokens (vTokens) representing wrapped vault shares
 *      - Receipt tokens are fully transferable (creates secondary market for locked positions)
 *      - Lockup enforced on ORIGINAL deposit time (not current token holder)
 *      - FIFO withdrawal: Oldest deposits unlock first
 *      - Emergency exit via forceDeallocate (pays vault penalty)
 *
 * @dev Compliant with VaultV2_GATE.md:
 *      - Does not modify VaultV2 core
 *      - Wrapper holds vault shares, users hold receipt tokens
 *      - Non-custodial guarantees via forceDeallocate
 */
contract VaultTimeLockWrapper {

    // ============================================
    // STATE VARIABLES
    // ============================================

    IVaultV2 public immutable vault;
    IERC20 public immutable asset;
    uint256 public constant LOCK_PERIOD = 7 days;
    uint256 public constant MAX_BATCHES_PER_USER = 100; // Prevent DoS via batch spam

    // ERC20 Receipt Token State
    string public constant name = "Vault TimeLock Token";
    string public constant symbol = "vTLT";
    uint8 public immutable decimals; // SECURITY FIX: Use vault's actual decimals instead of hardcoding 18
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // Approval for depositing on behalf of others
    mapping(address => mapping(address => bool)) public canDepositFor;

    /**
     * @dev Deposit tracking structure
     * Each deposit is tracked as a batch with:
     * - amount: Number of receipt tokens in this batch
     * - depositTime: When these tokens were originally deposited (determines unlock time)
     */
    struct DepositBatch {
        uint256 amount;
        uint256 depositTime;
    }

    /**
     * @dev Per-user FIFO queue of deposit batches
     * Oldest deposits are at index 0
     * SECURITY: Uses proper shift-left removal to maintain FIFO order
     */
    mapping(address => DepositBatch[]) public userDeposits;

    // ============================================
    // EVENTS
    // ============================================

    event Deposit(address indexed caller, address indexed onBehalf, uint256 assets, uint256 shares, uint256 vTokens);
    event Withdraw(address indexed caller, address indexed receiver, address indexed onBehalf, uint256 assets, uint256 shares, uint256 vTokens);
    event EmergencyExit(address indexed user, address indexed adapter, uint256 assets, uint256 penaltyShares);
    event ApprovalForDeposit(address indexed owner, address indexed operator, bool approved);

    // ERC20 Events
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ============================================
    // ERRORS
    // ============================================

    error ZeroAmount();
    error ZeroAddress();
    error MaxBatchesReached();
    error BatchStillLocked(uint256 batchIndex, uint256 unlockTime);
    error InsufficientBalance();
    error InsufficientAllowance();
    error NotApprovedForDeposit();
    error InsufficientDepositBalance();

    // ============================================
    // CONSTRUCTOR
    // ============================================

    constructor(address _vault) {
        vault = IVaultV2(_vault);
        asset = IERC20(vault.asset());
        // SECURITY FIX: Use vault's decimals to prevent decimal mismatch
        // VaultV2 uses max(asset.decimals, 18) for shares, so we match that here
        // This ensures wrapper tokens have the same decimal precision as vault shares
        decimals = vault.decimals();
    }

    // ============================================
    // DEPOSIT FUNCTIONS
    // ============================================

    /**
     * @notice Deposit assets and receive vTokens with 7-day lockup
     * @dev SECURITY FIX: Only deposits for msg.sender (no onBehalf parameter)
     * @param assets Amount of underlying assets to deposit
     * @return vTokens Amount of receipt tokens minted
     */
    function deposit(uint256 assets) external returns (uint256 vTokens) {
        return _depositInternal(assets, msg.sender, msg.sender);
    }

    /**
     * @notice Deposit assets on behalf of another user (requires approval)
     * @dev SECURITY FIX: Requires prior approval to prevent DoS attacks
     * @param assets Amount of underlying assets to deposit
     * @param onBehalf Address to receive vTokens
     * @return vTokens Amount of receipt tokens minted
     */
    function depositFor(uint256 assets, address onBehalf) external returns (uint256 vTokens) {
        if (!canDepositFor[onBehalf][msg.sender]) revert NotApprovedForDeposit();
        return _depositInternal(assets, msg.sender, onBehalf);
    }

    /**
     * @dev Internal deposit function
     */
    function _depositInternal(uint256 assets, address from, address to) internal returns (uint256 vTokens) {
        if (assets == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();

        // SECURITY FIX: Check batch limit to prevent DoS
        if (userDeposits[to].length >= MAX_BATCHES_PER_USER) revert MaxBatchesReached();

        // Pull assets from caller
        SafeERC20Lib.safeTransferFrom(
            address(asset),
            from,
            address(this),
            assets
        );

        // Approve and deposit to vault
        SafeERC20Lib.safeApprove(address(asset), address(vault), assets);
        uint256 shares = vault.deposit(assets, address(this));

        // SECURITY FIX: Reject zero-share deposits (prevents batch spam)
        if (shares == 0) revert ZeroAmount();

        // Mint vTokens 1:1 with vault shares
        vTokens = shares;

        // Create new deposit batch
        userDeposits[to].push(DepositBatch({
            amount: vTokens,
            depositTime: block.timestamp
        }));

        // Mint receipt tokens
        _mint(to, vTokens);

        emit Deposit(from, to, assets, shares, vTokens);
    }

    /**
     * @notice Mint specific amount of vault shares and receive vTokens
     */
    function mint(uint256 shares) external returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();

        // SECURITY FIX: Check batch limit
        if (userDeposits[msg.sender].length >= MAX_BATCHES_PER_USER) revert MaxBatchesReached();

        // Calculate required assets
        assets = vault.previewMint(shares);

        // Pull assets and deposit
         SafeERC20Lib.safeTransferFrom(
            address(asset),
            msg.sender,
            address(this),
            assets
        );

        asset.approve(address(vault), assets);
        vault.mint(shares, address(this));

        // Create deposit batch and mint vTokens
        userDeposits[msg.sender].push(DepositBatch({
            amount: shares,
            depositTime: block.timestamp
        }));

        _mint(msg.sender, shares);

        emit Deposit(msg.sender, msg.sender, assets, shares, shares);
    }

    /**
     * @notice Approve/revoke another address to deposit on your behalf
     * @dev SECURITY FIX: Required to prevent DoS via onBehalf deposits
     */
    function setApprovalForDeposit(address operator, bool approved) external {
        canDepositFor[msg.sender][operator] = approved;
        emit ApprovalForDeposit(msg.sender, operator, approved);
    }

    // ============================================
    // WITHDRAWAL FUNCTIONS (ENFORCES LOCKUP)
    // ============================================

    /**
     * @notice Withdraw assets after lockup period expires
     * @dev SECURITY FIX: Checks allowance in shares, not assets
     * @param assets Amount of underlying assets to withdraw
     * @param receiver Address to receive withdrawn assets
     * @param onBehalf Address whose vTokens to burn
     * @return vTokensBurned Amount of receipt tokens burned
     */
    function withdraw(uint256 assets, address receiver, address onBehalf)
        external
        returns (uint256 vTokensBurned)
    {
        if (receiver == address(0)) revert ZeroAddress();

        // Preview how many shares (vTokens) needed
        uint256 shares = vault.previewWithdraw(assets);

        // SECURITY FIX: Check authorization in SHARES, not assets
        if (msg.sender != onBehalf) {
            uint256 allowed = allowance[onBehalf][msg.sender];
            if (allowed < shares) revert InsufficientAllowance();
            if (allowed != type(uint256).max) {
                allowance[onBehalf][msg.sender] = allowed - shares;
            }
        }

        // SECURITY FIX: Enforce lockup with per-batch checks
        _burnWithLockupCheck(onBehalf, shares);

        // Withdraw from vault
        uint256 actualShares = vault.withdraw(assets, receiver, address(this));

        emit Withdraw(msg.sender, receiver, onBehalf, assets, actualShares, actualShares);

        return actualShares;
    }

    /**
     * @notice Redeem vTokens for assets after lockup period
     * @param vTokens Amount of receipt tokens to burn
     * @param receiver Address to receive assets
     * @param onBehalf Address whose vTokens to burn
     * @return assets Amount of underlying assets received
     */
    function redeem(uint256 vTokens, address receiver, address onBehalf)
        external
        returns (uint256 assets)
    {
        if (receiver == address(0)) revert ZeroAddress();

        // Check authorization (already in shares)
        if (msg.sender != onBehalf) {
            uint256 allowed = allowance[onBehalf][msg.sender];
            if (allowed < vTokens) revert InsufficientAllowance();
            if (allowed != type(uint256).max) {
                allowance[onBehalf][msg.sender] = allowed - vTokens;
            }
        }

        // SECURITY FIX: Enforce lockup with per-batch checks
        _burnWithLockupCheck(onBehalf, vTokens);

        // Redeem from vault (shares = vTokens 1:1)
        assets = vault.redeem(vTokens, receiver, address(this));

        emit Withdraw(msg.sender, receiver, onBehalf, assets, vTokens, vTokens);
    }

    /**
     * @dev SECURITY FIX: Per-batch lock enforcement with proper FIFO removal
     * Burns vTokens from oldest deposits first, checking EACH batch for lockup
     */
    function _burnWithLockupCheck(address user, uint256 amount) internal {
        DepositBatch[] storage deposits = userDeposits[user];
        if (deposits.length == 0) revert InsufficientDepositBalance();

        uint256 remaining = amount;
        uint256 batchesConsumed = 0;

        // SECURITY FIX: Check lock status of EACH batch being burned
        while (remaining > 0 && batchesConsumed < deposits.length) {
            DepositBatch storage batch = deposits[batchesConsumed];

            // SECURITY FIX: Per-batch lock check (not just first batch!)
            if (block.timestamp < batch.depositTime + LOCK_PERIOD) {
                revert BatchStillLocked(batchesConsumed, batch.depositTime + LOCK_PERIOD);
            }

            if (batch.amount <= remaining) {
                // Consume entire batch
                remaining -= batch.amount;
                batchesConsumed++;
            } else {
                // Partially consume batch
                batch.amount -= remaining;
                remaining = 0;
            }
        }

        if (remaining > 0) revert InsufficientDepositBalance();

        // SECURITY FIX: Proper FIFO removal - shift left instead of swap-with-last
        if (batchesConsumed > 0) {
            _removeFirstNBatches(deposits, batchesConsumed);
        }

        // Burn the ERC20 tokens
        _burn(user, amount);
    }

    /**
     * @dev SECURITY FIX: Proper FIFO removal via shift-left
     * Removes first N batches by shifting remaining batches left
     * This preserves chronological order (unlike swap-with-last)
     */
    function _removeFirstNBatches(DepositBatch[] storage batches, uint256 n) internal {
        uint256 remaining = batches.length - n;

        // Shift remaining batches to the left
        for (uint256 i = 0; i < remaining; i++) {
            batches[i] = batches[i + n];
        }

        // Remove now-duplicated entries at the end
        for (uint256 i = 0; i < n; i++) {
            batches.pop();
        }
    }

    // ============================================
    // EMERGENCY EXIT (BYPASSES LOCKUP)
    // ============================================

    /**
     * @notice SECURITY FIX: Emergency withdrawal that properly redeems from vault
     * @dev Uses vault's forceDeallocate then redeems shares
     * @param adapter Adapter to deallocate from
     * @param data Deallocation data for adapter
     * @param assets Amount of assets to deallocate
     * @return penaltyShares Shares burned as penalty
     */
    function emergencyWithdraw(
        address adapter,
        bytes memory data,
        uint256 assets
    ) external returns (uint256 penaltyShares) {
        if (balanceOf[msg.sender] == 0) revert InsufficientBalance();

        // SECURITY FIX: Approve vault for penalty shares before forceDeallocate
        // forceDeallocate internally calls withdraw(penaltyAssets, vault, wrapper)
        // which requires wrapper to approve vault for the penalty shares
        uint256 vaultBalanceBefore = vault.balanceOf(address(this));
        vault.approve(address(vault), type(uint256).max);

        // Step 1: Force deallocate from adapter (charges penalty)
        // This will deduct penaltyShares from wrapper via withdraw allowance
        penaltyShares = vault.forceDeallocate(adapter, data, assets, address(this));

        // SECURITY FIX: Revoke approval immediately after forceDeallocate
        // Prevents griefing attacks where anyone could repeatedly call forceDeallocate
        vault.approve(address(vault), 0);

        // Step 2: Redeem the requested assets from vault
        // After forceDeallocate, the wrapper still holds vault shares
        // We need to redeem those shares to get the actual assets
        uint256 sharesToRedeem = vault.previewWithdraw(assets);
        vault.withdraw(assets, msg.sender, address(this));

        // Step 3: Burn vTokens from user (penalty + redeemed shares)
        uint256 totalVTokensToBurn = penaltyShares + sharesToRedeem;

        // Burn without lockup check (emergency bypass)
        _burnEmergency(msg.sender, totalVTokensToBurn);

        emit EmergencyExit(msg.sender, adapter, assets, penaltyShares);
    }

    /**
     * @dev Emergency burn without lockup check
     * SECURITY FIX: Maintains proper FIFO ordering even for emergency burns
     */
    function _burnEmergency(address user, uint256 amount) internal {
        DepositBatch[] storage deposits = userDeposits[user];
        uint256 remaining = amount;
        uint256 batchesConsumed = 0;

        // Burn from oldest first (no lock check)
        while (remaining > 0 && batchesConsumed < deposits.length) {
            DepositBatch storage batch = deposits[batchesConsumed];

            if (batch.amount <= remaining) {
                remaining -= batch.amount;
                batchesConsumed++;
            } else {
                batch.amount -= remaining;
                remaining = 0;
            }
        }

        // SECURITY FIX: Proper FIFO removal
        if (batchesConsumed > 0) {
            _removeFirstNBatches(deposits, batchesConsumed);
        }

        _burn(user, amount);
    }

    // ============================================
    // ERC20 STANDARD FUNCTIONS
    // ============================================

    /**
     * @notice Transfer vTokens to another address
     * @dev SECURITY FIX: Maintains proper FIFO ordering during transfers
     */
    function transfer(address to, uint256 amount) external returns (bool) {
        if (to == address(0)) revert ZeroAddress();
        _transferWithBatches(msg.sender, to, amount);
        return true;
    }

    /**
     * @notice Transfer vTokens from one address to another (requires approval)
     */
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (to == address(0)) revert ZeroAddress();

        // Check and update allowance
        uint256 allowed = allowance[from][msg.sender];
        if (allowed < amount) revert InsufficientAllowance();
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }

        _transferWithBatches(from, to, amount);
        return true;
    }

    /**
     * @notice Approve spender to transfer vTokens on your behalf
     */
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /**
     * @dev SECURITY FIX: Transfer with proper FIFO preservation
     * Transfers oldest batches from sender to receiver using shift-left removal
     */
    function _transferWithBatches(address from, address to, uint256 amount) internal {
        if (balanceOf[from] < amount) revert InsufficientBalance();

        // Standard ERC20 balance transfer
        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        // Transfer deposit batches (oldest first, preserving timestamps)
        DepositBatch[] storage fromDeposits = userDeposits[from];
        DepositBatch[] storage toDeposits = userDeposits[to];

        uint256 remaining = amount;
        uint256 batchesConsumed = 0;

        while (remaining > 0 && batchesConsumed < fromDeposits.length) {
            // SECURITY FIX: Check batch limit BEFORE each push to prevent cap bypass
            // Previous vulnerability: checked once at start, allowing multiple pushes to exceed limit
            if (toDeposits.length >= MAX_BATCHES_PER_USER) revert MaxBatchesReached();

            DepositBatch storage sourceBatch = fromDeposits[batchesConsumed];

            if (sourceBatch.amount <= remaining) {
                // Transfer entire batch to receiver
                toDeposits.push(DepositBatch({
                    amount: sourceBatch.amount,
                    depositTime: sourceBatch.depositTime // Preserve original deposit time
                }));

                remaining -= sourceBatch.amount;
                batchesConsumed++;
            } else {
                // Partial batch transfer
                toDeposits.push(DepositBatch({
                    amount: remaining,
                    depositTime: sourceBatch.depositTime // Preserve original deposit time
                }));

                sourceBatch.amount -= remaining;
                remaining = 0;
            }
        }

        // SECURITY FIX: Proper FIFO removal from sender
        if (batchesConsumed > 0) {
            _removeFirstNBatches(fromDeposits, batchesConsumed);
        }

        emit Transfer(from, to, amount);
    }

    /**
     * @dev Internal mint function
     */
    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    /**
     * @dev Internal burn function
     */
    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Check if user's oldest deposit is unlocked
     */
    function isUnlocked(address user) external view returns (bool) {
        DepositBatch[] storage deposits = userDeposits[user];
        if (deposits.length == 0) return true;

        DepositBatch storage oldest = deposits[0];
        return block.timestamp >= oldest.depositTime + LOCK_PERIOD;
    }

    /**
     * @notice Get remaining lock time for user's oldest deposit
     */
    function remainingLockTime(address user) external view returns (uint256) {
        DepositBatch[] storage deposits = userDeposits[user];
        if (deposits.length == 0) return 0;

        DepositBatch storage oldest = deposits[0];
        uint256 unlockTime = oldest.depositTime + LOCK_PERIOD;

        if (block.timestamp >= unlockTime) return 0;
        return unlockTime - block.timestamp;
    }

    /**
     * @notice Get amount of vTokens that are currently unlocked and withdrawable
     * @dev SECURITY: This now returns accurate results due to proper FIFO ordering
     */
    function unlockedBalanceOf(address user) external view returns (uint256) {
        DepositBatch[] storage deposits = userDeposits[user];
        uint256 unlocked = 0;

        for (uint256 i = 0; i < deposits.length; i++) {
            if (block.timestamp >= deposits[i].depositTime + LOCK_PERIOD) {
                unlocked += deposits[i].amount;
            } else {
                // Since deposits are FIFO, once we hit a locked one, all after are locked
                break;
            }
        }

        return unlocked;
    }

    /**
     * @notice Get number of deposit batches for a user
     */
    function getDepositCount(address user) external view returns (uint256) {
        return userDeposits[user].length;
    }

    /**
     * @notice Get details of a specific deposit batch
     */
    function getDeposit(address user, uint256 index) external view returns (
        uint256 amount,
        uint256 depositTime,
        uint256 unlockTime,
        bool isUnlocked
    ) {
        require(index < userDeposits[user].length, "Index out of bounds");

        DepositBatch storage batch = userDeposits[user][index];
        amount = batch.amount;
        depositTime = batch.depositTime;
        unlockTime = depositTime + LOCK_PERIOD;
        isUnlocked = block.timestamp >= unlockTime;
    }

    /**
     * @notice Get total vault shares held by wrapper
     */
    function totalVaultShares() external view returns (uint256) {
        return vault.balanceOf(address(this));
    }

    /**
     * @notice Preview how many vTokens would be received for an asset deposit
     */
    function previewDeposit(uint256 assets) external view returns (uint256) {
        return vault.previewDeposit(assets);
    }

    /**
     * @notice Preview how many assets would be received for redeeming vTokens
     */
    function previewRedeem(uint256 vTokens) external view returns (uint256) {
        return vault.previewRedeem(vTokens);
    }
}
