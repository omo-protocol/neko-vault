// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {MockERC20} from "./MockERC20.sol";

/**
 * @title MockPositiveRebaseToken
 * @notice Mock token that can rebase positively during transfers
 * @dev Used to test UniversalTokenWrapper's handling of positive rebases
 *      This simulates tokens like stETH where a global rebase can occur
 *      DURING a transfer, increasing the balance of the sender (wrapper)
 */
contract MockPositiveRebaseToken is MockERC20 {
    bool public rebaseOnTransfer;
    uint256 public rebasePercentage; // in basis points (e.g., 100 = 1%)
    bool public aggressiveRebase; // If true, rebase based on original balance before transfer

    constructor(string memory _name, string memory _symbol, uint8 _decimals) MockERC20(_name, _symbol, _decimals) {
        rebaseOnTransfer = false;
        rebasePercentage = 0;
        aggressiveRebase = false;
    }

    /**
     * @notice Enable positive rebase on transfer
     * @param _percentage Rebase percentage in basis points (e.g., 100 = 1%)
     */
    function setPositiveRebaseOnTransfer(uint256 _percentage) external {
        rebaseOnTransfer = true;
        rebasePercentage = _percentage;
    }

    /**
     * @notice Enable aggressive rebase (based on balance BEFORE transfer)
     * @dev This causes afterBal > beforeBal when rebase% > transfer%
     */
    function setAggressiveRebase(bool _aggressive) external {
        aggressiveRebase = _aggressive;
    }

    /**
     * @notice Disable positive rebase on transfer
     */
    function disableRebaseOnTransfer() external {
        rebaseOnTransfer = false;
        rebasePercentage = 0;
        aggressiveRebase = false;
    }

    /**
     * @notice Override transfer to simulate global positive rebase affecting sender
     * @dev CRITICAL: This simulates a rebase that increases the SENDER's (wrapper's) balance
     *      during the transfer, which causes afterBal > beforeBal in withdraw/redeem
     */
    function transfer(address to, uint256 amount) public override returns (bool) {
        // Capture balance before transfer if using aggressive rebase
        uint256 balanceBeforeTransfer = aggressiveRebase ? balanceOf(msg.sender) : 0;

        // First do the normal transfer
        bool success = super.transfer(to, amount);

        if (success && rebaseOnTransfer && rebasePercentage > 0) {
            // CRITICAL: Simulate global positive rebase by minting tokens back to sender
            // This simulates what happens when a positive rebase occurs DURING the transfer
            // In real rebasing tokens (like stETH), this would happen automatically
            uint256 baseAmount = aggressiveRebase ? balanceBeforeTransfer : balanceOf(msg.sender);
            uint256 rebaseAmount = (baseAmount * rebasePercentage) / 10000;
            if (rebaseAmount > 0) {
                _mint(msg.sender, rebaseAmount);
            }
        }

        return success;
    }

    /**
     * @notice Override transferFrom to simulate global positive rebase affecting 'from' address
     */
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        // Capture balance before transfer if using aggressive rebase
        uint256 balanceBeforeTransfer = aggressiveRebase ? balanceOf(from) : 0;

        // First do the normal transfer
        bool success = super.transferFrom(from, to, amount);

        if (success && rebaseOnTransfer && rebasePercentage > 0) {
            // CRITICAL: Simulate global positive rebase by minting tokens to 'from' address
            uint256 baseAmount = aggressiveRebase ? balanceBeforeTransfer : balanceOf(from);
            uint256 rebaseAmount = (baseAmount * rebasePercentage) / 10000;
            if (rebaseAmount > 0) {
                _mint(from, rebaseAmount);
            }
        }

        return success;
    }
}
