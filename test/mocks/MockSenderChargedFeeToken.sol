// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {MockERC20} from "./MockERC20.sol";

/**
 * @title MockSenderChargedFeeToken
 * @notice Mock token that charges fees from the sender (not recipient) on transfers
 * @dev This simulates tokens where sender pays MORE than the nominal transfer amount
 *      Example: transfer(recipient, 100) debits sender by 110 (100 + 10 fee)
 */
contract MockSenderChargedFeeToken is MockERC20 {
    uint256 public senderFeeBps = 1000; // 10% default fee charged to sender
    address public feeCollector;

    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals
    ) MockERC20(_name, _symbol, _decimals) {
        feeCollector = address(this); // Fees stay in contract by default
    }

    /// @notice Set sender fee in basis points (10000 = 100%)
    function setSenderFeeBps(uint256 _feeBps) external {
        require(_feeBps <= 10000, "Fee too high");
        senderFeeBps = _feeBps;
    }

    /// @notice Set fee collector address
    function setFeeCollector(address _collector) external {
        feeCollector = _collector;
    }

    /// @notice Transfer with sender-charged fee
    /// @dev Sender pays amount + fee, recipient receives full amount
    function transfer(address to, uint256 amount) public override returns (bool) {
        require(to != address(0), "Transfer to zero");

        // Calculate fee charged to sender
        uint256 senderFee = (amount * senderFeeBps) / 10000;
        uint256 totalDebit = amount + senderFee;

        // Debit sender for amount + fee
        require(balanceOf(msg.sender) >= totalDebit, "Insufficient balance");
        _burn(msg.sender, totalDebit);

        // Credit recipient with full amount (no deduction)
        _mint(to, amount);

        // Route fee to collector
        if (senderFee > 0 && feeCollector != address(0)) {
            _mint(feeCollector, senderFee);
        }

        emit Transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice TransferFrom with sender-charged fee
    /// @dev Sender (from address) pays amount + fee, recipient receives full amount
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(to != address(0), "Transfer to zero");

        // Check and update allowance using OpenZeppelin's _spendAllowance
        _spendAllowance(from, msg.sender, amount);

        // Calculate fee charged to sender
        uint256 senderFee = (amount * senderFeeBps) / 10000;
        uint256 totalDebit = amount + senderFee;

        // Debit sender (from) for amount + fee
        require(balanceOf(from) >= totalDebit, "Insufficient balance");
        _burn(from, totalDebit);

        // Credit recipient with full amount (no deduction)
        _mint(to, amount);

        // Route fee to collector
        if (senderFee > 0 && feeCollector != address(0)) {
            _mint(feeCollector, senderFee);
        }

        emit Transfer(from, to, amount);
        return true;
    }
}
