// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "../interfaces/IERC20.sol";
import {SafeERC20Lib} from "../libraries/SafeERC20Lib.sol";
import {MathLib} from "../libraries/MathLib.sol";

/// @title UniversalTokenWrapper
/// @notice ERC4626-like wrapper for rebasing or non-rebasing ERC20 tokens.
/// @dev This contract is intentionally simple: it holds the underlying and mints non-rebasing shares.
///      Any positive rebases of the underlying increase totalAssets() and thus the wrapper's exchange rate.
///      Fee-on-transfer tokens are supported by measuring actual received.
//  Interface subset (ERC20 + ERC4626-like)
contract UniversalTokenWrapper {
    using MathLib for uint256;

    /* CONSTANTS */

    // Virtual shares to prevent donation/inflation attacks
    // Minted to address(1) on first deposit to make price manipulation economically infeasible
    uint256 private constant VIRTUAL_SHARES = 1000;
    address private constant DEAD_ADDRESS = address(1);

    /* IMMUTABLES */

    address public immutable underlying; // Rebasing token (e.g., stETH)
    uint8 public immutable decimals;

    /* ERC20 STORAGE */

    string public name;
    string public symbol;

    uint256 public totalSupply;
    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    /* REENTRANCY PROTECTION */

    // Reentrancy guard state
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    /* EVENTS */

    event Deposit(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /* CONSTRUCTOR */

    constructor(address _underlying, string memory _name, string memory _symbol) {
        require(_underlying != address(0), "WRP: underlying=0");
        underlying = _underlying;
        name = _name;
        symbol = _symbol;

        // Underlying must expose decimals() (VaultV2 already relies on that on its IERC20).
        decimals = IERC20(_underlying).decimals();

        // Initialize reentrancy guard
        _status = _NOT_ENTERED;
    }

    /* MODIFIERS */

    /// @notice Prevents reentrancy attacks by locking the contract during execution
    /// @dev CRITICAL SECURITY FIX: Protects against re-entrant underlying tokens
    ///      that could double-count deposits or corrupt virtual shares accounting
    modifier nonReentrant() {
        require(_status != _ENTERED, "WRP: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    /* VIEW */

    function asset() external view returns (address) {
        return underlying;
    }

    /// @notice Underlying units held by wrapper (includes any rebases that increased balance).
    function totalAssets() public view returns (uint256) {
        return IERC20(underlying).balanceOf(address(this));
    }

    /// @notice Convert underlying assets to wrapper shares (rounding down).
    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 _totalAssets = totalAssets();
        uint256 _totalSupply = totalSupply;

        if (_totalSupply == 0 || _totalAssets == 0) return assets;
        return assets.mulDivDown(_totalSupply, _totalAssets);
    }

    /// @notice Convert wrapper shares to underlying assets (rounding down).
    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 _totalAssets = totalAssets();
        uint256 _totalSupply = totalSupply;

        if (_totalSupply == 0) return shares;
        return shares.mulDivDown(_totalAssets, _totalSupply);
    }

    /* ERC20 */

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(to != address(0), "WRP: to=0");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(to != address(0), "WRP: to=0");
        if (msg.sender != from) {
            uint256 _allow = allowance[from][msg.sender];
            if (_allow != type(uint256).max) {
                allowance[from][msg.sender] = _allow - amount;
            }
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    /* ERC4626-LIKE */

    /// @notice Deposit underlying and mint shares to receiver.
    /// @dev Supports fee-on-transfer by measuring actual received amount.
    ///      Uses virtual shares to prevent donation/inflation attacks.
    function deposit(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        require(assets != 0, "WRP: zero assets");
        require(receiver != address(0), "WRP: recv=0");

        // Capture PRE-deposit state for accurate share calculation
        uint256 _totalSupply = totalSupply;
        uint256 beforeBal = IERC20(underlying).balanceOf(address(this));

        SafeERC20Lib.safeTransferFrom(underlying, msg.sender, address(this), assets);
        uint256 received = IERC20(underlying).balanceOf(address(this)) - beforeBal;

        // Calculate shares using PRE-deposit totals to prevent value dilution
        if (_totalSupply == 0 || beforeBal == 0) {
            // CRITICAL SECURITY FIX: First deposit mints virtual shares to prevent donation attacks
            // Virtual shares are permanently locked in DEAD_ADDRESS, making price manipulation
            // economically infeasible (attacker would need to donate VIRTUAL_SHARES worth of assets)
            shares = received;
            require(shares > VIRTUAL_SHARES, "WRP: first deposit too small");

            // Mint virtual shares to dead address (permanently locked)
            _mint(DEAD_ADDRESS, VIRTUAL_SHARES);

            // Mint remaining shares to receiver
            _mint(receiver, shares - VIRTUAL_SHARES);

            emit Deposit(msg.sender, receiver, received, shares - VIRTUAL_SHARES);
            return shares - VIRTUAL_SHARES;
        } else {
            shares = received.mulDivDown(_totalSupply, beforeBal);
            require(shares != 0, "WRP: zero shares");
            _mint(receiver, shares);
            emit Deposit(msg.sender, receiver, received, shares);
            return shares;
        }
    }

    /// @notice Mint shares to receiver by pulling enough underlying from caller.
    /// @dev If underlying is fee-on-transfer, slightly more assets may be required; this function reverts if not enough
    ///      was received to support the requested shares. Uses virtual shares to prevent donation attacks.
    ///      Protected against reentrancy to prevent double-counting of deposits.
    ///      SECURITY FIX: On first mint, requests assets for both requested shares AND virtual shares.
    function mint(uint256 shares, address receiver) external nonReentrant returns (uint256 assets) {
        require(shares != 0, "WRP: zero shares");
        require(receiver != address(0), "WRP: recv=0");

        // Capture PRE-deposit state for accurate share calculation
        uint256 _totalSupply = totalSupply;
        uint256 beforeBal = IERC20(underlying).balanceOf(address(this));

        // CRITICAL FIX: On first mint, we must request enough assets to cover both
        // the user's requested shares AND the VIRTUAL_SHARES that will be minted
        if (_totalSupply == 0 || beforeBal == 0) {
            assets = previewMint(shares + VIRTUAL_SHARES);
        } else {
            assets = previewMint(shares);
        }
        SafeERC20Lib.safeTransferFrom(underlying, msg.sender, address(this), assets);
        uint256 received = IERC20(underlying).balanceOf(address(this)) - beforeBal;

        // Recompute shares from actual received using PRE-deposit totals to ensure shares are fully covered
        uint256 maxShares;
        if (_totalSupply == 0 || beforeBal == 0) {
            // CRITICAL SECURITY FIX: First mint includes virtual shares protection
            maxShares = received;
            require(maxShares > VIRTUAL_SHARES, "WRP: first mint too small");
            require(shares <= maxShares - VIRTUAL_SHARES, "WRP: insufficient recv");

            // Mint virtual shares to dead address (permanently locked)
            _mint(DEAD_ADDRESS, VIRTUAL_SHARES);

            // Mint requested shares to receiver
            _mint(receiver, shares);

            emit Deposit(msg.sender, receiver, received, shares);
            return assets;
        } else {
            maxShares = received.mulDivDown(_totalSupply, beforeBal);
            require(maxShares >= shares, "WRP: insufficient recv");
            _mint(receiver, shares);
            emit Deposit(msg.sender, receiver, received, shares);
            return assets;
        }
        // Note: If received > exact requirement, the surplus stays in wrapper and increases exchange rate marginally.
    }

    /// @notice Withdraw underlying assets to receiver, burning shares from owner.
    /// @dev Measures actual balance delta to support tokens with sender-charged fees.
    ///      Protected against reentrancy to prevent underflow DoS attacks.
    ///      SECURITY FIX: Handles positive rebases that occur during transfer.
    function withdraw(uint256 assets, address receiver, address owner_) external nonReentrant returns (uint256 shares) {
        require(assets != 0, "WRP: zero assets");
        require(receiver != address(0), "WRP: recv=0");

        // Capture PRE-transfer state for accurate share calculation
        uint256 _totalSupply = totalSupply;
        uint256 beforeBal = IERC20(underlying).balanceOf(address(this));

        // Execute transfer
        SafeERC20Lib.safeTransfer(underlying, receiver, assets);

        // Measure actual balance delta (protects against sender-charged fees)
        uint256 afterBal = IERC20(underlying).balanceOf(address(this));

        // SECURITY FIX: Handle positive rebases that cause afterBal >= beforeBal
        // If positive rebase occurs during transfer, wrapper gains value - treat as zero-cost withdrawal
        uint256 actualTransferred;
        if (afterBal >= beforeBal) {
            // Positive rebase occurred (e.g., stETH rebase, on-transfer credits)
            // The wrapper gained tokens during the transfer, so use requested amount
            actualTransferred = assets;
        } else {
            // Normal case or sender-charged fee case
            actualTransferred = beforeBal - afterBal;
        }

        // For standard tokens: actualTransferred == assets
        // For sender-charged fee tokens: actualTransferred > assets (sender pays fee)
        // For positive rebase tokens: actualTransferred == assets (wrapper benefits from rebase)
        // Calculate shares using PRE-transfer state to burn correct amount
        if (_totalSupply == 0 || beforeBal == 0) {
            shares = actualTransferred;
        } else {
            shares = actualTransferred.mulDivUp(_totalSupply, beforeBal);
        }
        require(shares != 0, "WRP: zero shares");

        // Burn shares corresponding to actual transferred amount
        _burnFrom(owner_, shares);

        emit Withdraw(msg.sender, receiver, owner_, actualTransferred, shares);
    }

    /// @notice Redeem shares for underlying assets to receiver.
    /// @dev Measures actual balance delta to support tokens with sender-charged fees.
    ///      Protected against reentrancy to prevent underflow DoS attacks.
    ///      SECURITY FIX: Burns additional shares if sender-charged fees cause higher actual outflow.
    ///      SECURITY FIX: Handles positive rebases that occur during transfer.
    function redeem(uint256 shares, address receiver, address owner_) external nonReentrant returns (uint256 assets) {
        require(shares != 0, "WRP: zero shares");
        require(receiver != address(0), "WRP: recv=0");

        // Capture PRE-burn state for accurate share calculation
        uint256 _totalSupply = totalSupply;
        uint256 beforeBal = IERC20(underlying).balanceOf(address(this));

        // Calculate expected assets for these shares
        assets = previewRedeem(shares);

        // Burn requested shares FIRST (per ERC4626 spec)
        _burnFrom(owner_, shares);

        // Execute transfer
        SafeERC20Lib.safeTransfer(underlying, receiver, assets);

        // Measure actual balance delta (captures sender-charged fees AND positive rebases)
        uint256 afterBal = IERC20(underlying).balanceOf(address(this));

        // SECURITY FIX: Handle positive rebases that cause afterBal >= beforeBal
        uint256 actualTransferred;
        if (afterBal >= beforeBal) {
            // Positive rebase occurred during transfer - wrapper gained value
            // Treat as requested amount for share burn calculation
            actualTransferred = assets;
        } else {
            // Normal case or sender-charged fee case
            actualTransferred = beforeBal - afterBal;
        }

        // CRITICAL SECURITY FIX: For sender-charged fee tokens, actualTransferred > assets
        // We must burn additional shares to prevent exchange rate dilution
        // Note: This only applies when actualTransferred > assets (not for positive rebases)
        if (actualTransferred > assets) {
            // Calculate how many shares SHOULD have been burned based on actual outflow
            // Use PRE-burn totalSupply to maintain correct exchange rate
            uint256 requiredShares;
            if (_totalSupply == 0 || beforeBal == 0) {
                requiredShares = actualTransferred;
            } else {
                requiredShares = actualTransferred.mulDivUp(_totalSupply, beforeBal);
            }

            // If we need to burn more shares than originally requested, burn the difference
            if (requiredShares > shares) {
                uint256 additionalShares = requiredShares - shares;

                // Check if owner has enough shares for the additional burn
                // If not, cap the burn to what's available
                uint256 ownerBalance = balanceOf[owner_];
                if (additionalShares > ownerBalance) {
                    // Can only burn what's available
                    // NOTE: This may result in slight exchange rate dilution for sender-charged tokens
                    // Users should use withdraw() instead of redeem() for complete exits with such tokens
                    additionalShares = ownerBalance;
                }

                if (additionalShares > 0) {
                    _burnFrom(owner_, additionalShares);
                    shares += additionalShares; // Update total burned shares
                }
            }
        }

        emit Withdraw(msg.sender, receiver, owner_, actualTransferred, shares);
    }

    /* PREVIEWS (ERC4626 semantics) */

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        uint256 _totalAssets = totalAssets();
        uint256 _totalSupply = totalSupply;

        if (_totalSupply == 0 || _totalAssets == 0) return shares;
        // assets = shares * totalAssets / totalSupply (round up)
        return shares.mulDivUp(_totalAssets, _totalSupply);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        uint256 shares = convertToShares(assets);
        return shares > 0 ? shares : 1; // avoid zero shares for dust asset
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares);
    }

    /* INTERNAL MINT/BURN */

    function _mint(address to, uint256 shares) internal {
        require(to != address(0), "WRP: to=0");
        totalSupply += shares;
        balanceOf[to] += shares;
        emit Transfer(address(0), to, shares);
    }

    function _burnFrom(address from, uint256 shares) internal {
        require(from != address(0), "WRP: from=0");

        if (msg.sender != from) {
            uint256 _allow = allowance[from][msg.sender];
            if (_allow != type(uint256).max) {
                allowance[from][msg.sender] = _allow - shares;
            }
        }

        balanceOf[from] -= shares;
        totalSupply -= shares;
        emit Transfer(from, address(0), shares);
    }
}