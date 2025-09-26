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

    /* IMMUTABLES */

    address public immutable underlying; // Rebasing token (e.g., stETH)
    uint8 public immutable decimals;

    /* ERC20 STORAGE */

    string public name;
    string public symbol;

    uint256 public totalSupply;
    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

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
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(assets != 0, "WRP: zero assets");
        require(receiver != address(0), "WRP: recv=0");

        uint256 beforeBal = IERC20(underlying).balanceOf(address(this));
        SafeERC20Lib.safeTransferFrom(underlying, msg.sender, address(this), assets);
        uint256 received = IERC20(underlying).balanceOf(address(this)) - beforeBal;

        shares = convertToShares(received);
        // For first deposit or if exchange rate not set, shares == received.

        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, received, shares);
    }

    /// @notice Mint shares to receiver by pulling enough underlying from caller.
    /// @dev If underlying is fee-on-transfer, slightly more assets may be required; this function reverts if not enough
    ///      was received to support the requested shares.
    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        require(shares != 0, "WRP: zero shares");
        require(receiver != address(0), "WRP: recv=0");

        assets = previewMint(shares);
        uint256 beforeBal = IERC20(underlying).balanceOf(address(this));
        SafeERC20Lib.safeTransferFrom(underlying, msg.sender, address(this), assets);
        uint256 received = IERC20(underlying).balanceOf(address(this)) - beforeBal;

        // Recompute from actual received to ensure shares are fully covered.
        uint256 maxShares = convertToShares(received);
        require(maxShares >= shares, "WRP: insufficient recv");

        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, received, shares);
        // Note: If received > exact requirement, the surplus stays in wrapper and increases exchange rate marginally.
    }

    /// @notice Withdraw underlying assets to receiver, burning shares from owner.
    function withdraw(uint256 assets, address receiver, address owner_) external returns (uint256 shares) {
        require(assets != 0, "WRP: zero assets");
        require(receiver != address(0), "WRP: recv=0");

        shares = previewWithdraw(assets);
        _burnFrom(owner_, shares);
        SafeERC20Lib.safeTransfer(underlying, receiver, assets);
        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    /// @notice Redeem shares for underlying assets to receiver.
    function redeem(uint256 shares, address receiver, address owner_) external returns (uint256 assets) {
        require(shares != 0, "WRP: zero shares");
        require(receiver != address(0), "WRP: recv=0");

        assets = previewRedeem(shares);
        _burnFrom(owner_, shares);
        SafeERC20Lib.safeTransfer(underlying, receiver, assets);
        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
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