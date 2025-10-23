// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IERC20} from "./interfaces/IERC20.sol";
import {IVaultV2} from "./interfaces/IVaultV2.sol";

/**
 * @title VaultTimeLockWrapper
 * @notice Enforces 7-day lockup on VaultV2 deposits with transferable ERC20 receipt tokens
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
 *
 * @dev Example Flow:
 *      T=0: Alice deposits 100 tokens → Gets 100 vTokens (unlock T=7)
 *      T=3: Alice transfers 50 vTokens to Bob
 *      T=7: Bob can withdraw (his tokens unlock based on Alice's original deposit at T=0)
 */
contract VaultTimeLockWrapper {

    // ============================================
    // STATE VARIABLES
    // ============================================

    IVaultV2 public immutable vault;
    IERC20 public immutable asset;
    uint256 public constant LOCK_PERIOD = 7 days;

    // ERC20 Receipt Token State
    string public constant name = "Vault TimeLock Token";
    string public constant symbol = "vTLT";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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
     * When withdrawing, oldest batches are processed first
     * When transferring, oldest batches are transferred first (preserves deposit time)
     */
    mapping(address => DepositBatch[]) public userDeposits;

    // ============================================
    // EVENTS
    // ============================================

    event Deposit(address indexed caller, address indexed onBehalf, uint256 assets, uint256 shares, uint256 vTokens);
    event Withdraw(address indexed caller, address indexed receiver, address indexed onBehalf, uint256 assets, uint256 shares, uint256 vTokens);
    event EmergencyExit(address indexed user, address indexed adapter, uint256 assets, uint256 penaltyShares);

    // ERC20 Events
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ============================================
    // CONSTRUCTOR
    // ============================================

    constructor(address _vault) {
        vault = IVaultV2(_vault);
        asset = IERC20(vault.asset());
    }

    // ============================================
    // DEPOSIT FUNCTIONS
    // ============================================

    /**
     * @notice Deposit assets and receive transferable vTokens with 7-day lockup
     * @dev Creates new deposit batch tracked by original deposit time
     * @param assets Amount of underlying assets to deposit
     * @param onBehalf Address to receive vTokens
     * @return vTokens Amount of receipt tokens minted (1:1 with vault shares)
     */
    function deposit(uint256 assets, address onBehalf) external returns (uint256 vTokens) {
        require(assets > 0, "Zero deposit");
        require(onBehalf != address(0), "Zero address");

        // Pull assets from caller
        asset.transferFrom(msg.sender, address(this), assets);

        // Approve and deposit to vault
        asset.approve(address(vault), assets);
        uint256 shares = vault.deposit(assets, address(this));

        // Mint vTokens 1:1 with vault shares
        vTokens = shares;

        // Create new deposit batch for this user
        userDeposits[onBehalf].push(DepositBatch({
            amount: vTokens,
            depositTime: block.timestamp
        }));

        // Mint receipt tokens
        _mint(onBehalf, vTokens);

        emit Deposit(msg.sender, onBehalf, assets, shares, vTokens);
    }

    /**
     * @notice Mint specific amount of vault shares and receive vTokens
     * @dev Alternative to deposit() for exact share amount
     */
    function mint(uint256 shares, address onBehalf) external returns (uint256 assets) {
        require(shares > 0, "Zero shares");
        require(onBehalf != address(0), "Zero address");

        // Calculate required assets
        assets = vault.previewMint(shares);

        // Pull assets and deposit
        asset.transferFrom(msg.sender, address(this), assets);
        asset.approve(address(vault), assets);
        vault.mint(shares, address(this));

        // Create deposit batch and mint vTokens
        userDeposits[onBehalf].push(DepositBatch({
            amount: shares,
            depositTime: block.timestamp
        }));

        _mint(onBehalf, shares);

        emit Deposit(msg.sender, onBehalf, assets, shares, shares);
    }

    // ============================================
    // WITHDRAWAL FUNCTIONS (ENFORCES LOCKUP)
    // ============================================

    /**
     * @notice Withdraw assets after lockup period expires
     * @dev Enforces 7-day lockup on OLDEST deposit batch
     *      Burns vTokens from oldest batches first (FIFO)
     * @param assets Amount of underlying assets to withdraw
     * @param receiver Address to receive withdrawn assets
     * @param onBehalf Address whose vTokens to burn
     * @return vTokensBurned Amount of receipt tokens burned
     */
    function withdraw(uint256 assets, address receiver, address onBehalf)
        external
        returns (uint256 vTokensBurned)
    {
        require(receiver != address(0), "Zero address");

        // Check authorization if caller is not onBehalf
        if (msg.sender != onBehalf) {
            uint256 allowed = allowance[onBehalf][msg.sender];
            require(allowed >= assets, "Insufficient allowance");
            if (allowed != type(uint256).max) {
                allowance[onBehalf][msg.sender] = allowed - assets;
            }
        }

        // Preview how many shares (vTokens) needed
        uint256 shares = vault.previewWithdraw(assets);

        // Enforce lockup and burn vTokens (FIFO)
        _burnWithLockupCheck(onBehalf, shares);

        // Withdraw from vault
        uint256 actualShares = vault.withdraw(assets, receiver, address(this));

        emit Withdraw(msg.sender, receiver, onBehalf, assets, actualShares, actualShares);

        return actualShares;
    }

    /**
     * @notice Redeem vTokens for assets after lockup period
     * @dev Burns vTokens from oldest batches first (FIFO)
     * @param vTokens Amount of receipt tokens to burn
     * @param receiver Address to receive assets
     * @param onBehalf Address whose vTokens to burn
     * @return assets Amount of underlying assets received
     */
    function redeem(uint256 vTokens, address receiver, address onBehalf)
        external
        returns (uint256 assets)
    {
        require(receiver != address(0), "Zero address");

        // Check authorization
        if (msg.sender != onBehalf) {
            uint256 allowed = allowance[onBehalf][msg.sender];
            require(allowed >= vTokens, "Insufficient allowance");
            if (allowed != type(uint256).max) {
                allowance[onBehalf][msg.sender] = allowed - vTokens;
            }
        }

        // Enforce lockup and burn vTokens (FIFO)
        _burnWithLockupCheck(onBehalf, vTokens);

        // Redeem from vault (shares = vTokens 1:1)
        assets = vault.redeem(vTokens, receiver, address(this));

        emit Withdraw(msg.sender, receiver, onBehalf, assets, vTokens, vTokens);
    }

    /**
     * @dev Internal function to burn vTokens with lockup enforcement
     * Burns from oldest deposits first (FIFO)
     * Reverts if oldest deposit is still locked
     */
    function _burnWithLockupCheck(address user, uint256 amount) internal {
        DepositBatch[] storage deposits = userDeposits[user];
        require(deposits.length > 0, "No deposits");

        // Check if oldest deposit is unlocked
        DepositBatch storage oldest = deposits[0];
        require(
            block.timestamp >= oldest.depositTime + LOCK_PERIOD,
            "Oldest deposit still locked"
        );

        // Burn tokens starting from oldest batch (FIFO)
        uint256 remaining = amount;

        while (remaining > 0 && deposits.length > 0) {
            DepositBatch storage batch = deposits[0];

            if (batch.amount <= remaining) {
                // Burn entire batch
                remaining -= batch.amount;

                // Remove batch by swapping with last and popping
                deposits[0] = deposits[deposits.length - 1];
                deposits.pop();
            } else {
                // Partially burn batch
                batch.amount -= remaining;
                remaining = 0;
            }
        }

        require(remaining == 0, "Insufficient deposit balance");

        // Burn the ERC20 tokens
        _burn(user, amount);
    }

    // ============================================
    // EMERGENCY EXIT (BYPASSES LOCKUP)
    // ============================================

    /**
     * @notice Emergency withdrawal via vault's forceDeallocate (bypasses lockup, pays penalty)
     * @dev Uses vault's force deallocate mechanism (up to 2% penalty)
     *      Preserves non-custodial guarantee from VaultV2_GATE.md
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
        require(balanceOf[msg.sender] > 0, "No vTokens");

        // Force deallocate from vault (charges penalty)
        penaltyShares = vault.forceDeallocate(adapter, data, assets, address(this));

        // Transfer assets to user
        uint256 assetsReceived = asset.balanceOf(address(this));
        require(assetsReceived >= assets, "Deallocate failed");
        asset.transfer(msg.sender, assets);

        // Burn vTokens and remove from deposits (bypass lockup check)
        _burnEmergency(msg.sender, penaltyShares);

        emit EmergencyExit(msg.sender, adapter, assets, penaltyShares);
    }

    /**
     * @dev Emergency burn without lockup check (for forceDeallocate only)
     */
    function _burnEmergency(address user, uint256 amount) internal {
        DepositBatch[] storage deposits = userDeposits[user];
        uint256 remaining = amount;

        // Burn from oldest first (no lockup check)
        while (remaining > 0 && deposits.length > 0) {
            DepositBatch storage batch = deposits[0];

            if (batch.amount <= remaining) {
                remaining -= batch.amount;
                deposits[0] = deposits[deposits.length - 1];
                deposits.pop();
            } else {
                batch.amount -= remaining;
                remaining = 0;
            }
        }

        _burn(user, amount);
    }

    // ============================================
    // ERC20 STANDARD FUNCTIONS
    // ============================================

    /**
     * @notice Transfer vTokens to another address
     * @dev Transfers oldest deposit batches first (FIFO)
     *      Receiver inherits original deposit timestamps (preserves lockup)
     */
    function transfer(address to, uint256 amount) external returns (bool) {
        require(to != address(0), "Zero address");
        _transferWithBatches(msg.sender, to, amount);
        return true;
    }

    /**
     * @notice Transfer vTokens from one address to another (requires approval)
     */
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(to != address(0), "Zero address");

        // Check and update allowance
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "Insufficient allowance");
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
     * @dev Internal transfer that preserves deposit batch timestamps
     * Transfers oldest batches from sender to receiver (FIFO)
     * Receiver inherits original deposit times (lockup preserved)
     */
    function _transferWithBatches(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "Insufficient balance");

        // Standard ERC20 balance transfer
        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        // Transfer deposit batches (oldest first, preserving timestamps)
        DepositBatch[] storage fromDeposits = userDeposits[from];
        DepositBatch[] storage toDeposits = userDeposits[to];

        uint256 remaining = amount;

        while (remaining > 0 && fromDeposits.length > 0) {
            DepositBatch storage oldestBatch = fromDeposits[0];

            if (oldestBatch.amount <= remaining) {
                // Transfer entire batch to receiver
                toDeposits.push(DepositBatch({
                    amount: oldestBatch.amount,
                    depositTime: oldestBatch.depositTime // ✅ Preserve original deposit time
                }));

                remaining -= oldestBatch.amount;

                // Remove from sender
                fromDeposits[0] = fromDeposits[fromDeposits.length - 1];
                fromDeposits.pop();
            } else {
                // Partial batch transfer
                toDeposits.push(DepositBatch({
                    amount: remaining,
                    depositTime: oldestBatch.depositTime // ✅ Preserve original deposit time
                }));

                oldestBatch.amount -= remaining;
                remaining = 0;
            }
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
     * @dev Returns true if user can withdraw any amount
     */
    function isUnlocked(address user) external view returns (bool) {
        DepositBatch[] storage deposits = userDeposits[user];
        if (deposits.length == 0) return true;

        DepositBatch storage oldest = deposits[0];
        return block.timestamp >= oldest.depositTime + LOCK_PERIOD;
    }

    /**
     * @notice Get remaining lock time for user's oldest deposit
     * @return seconds Seconds until oldest deposit unlocks (0 if unlocked)
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
     * @dev Sums all deposit batches that have passed the lockup period
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
     * @return amount Number of vTokens in this batch
     * @return depositTime When this batch was deposited
     * @return unlockTime When this batch can be withdrawn
     * @return isUnlocked Whether this batch is currently unlocked
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
