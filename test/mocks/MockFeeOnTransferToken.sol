// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @notice Mock ERC20 token that charges a fee on transfers
contract MockFeeOnTransferToken is ERC20 {
    uint8 private immutable _decimals;
    uint256 public transferFeePercent = 100; // 1% fee (100 basis points)

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function setTransferFeePercent(uint256 feePercent) external {
        require(feePercent <= 1000, "Fee too high"); // Max 10%
        transferFeePercent = feePercent;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        address owner = _msgSender();
        uint256 fee = (amount * transferFeePercent) / 10000;
        uint256 netAmount = amount - fee;

        _transfer(owner, to, netAmount);
        if (fee > 0) {
            _burn(owner, fee); // Burn the fee
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);

        uint256 fee = (amount * transferFeePercent) / 10000;
        uint256 netAmount = amount - fee;

        _transfer(from, to, netAmount);
        if (fee > 0) {
            _burn(from, fee); // Burn the fee
        }
        return true;
    }
}