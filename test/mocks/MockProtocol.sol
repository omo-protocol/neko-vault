// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./MockERC20.sol";

/// @notice Mock external protocol for testing
contract MockProtocol {
    MockERC20 public asset;
    mapping(address => uint256) public balances;
    
    constructor(address _asset) {
        asset = MockERC20(_asset);
    }
    
    function deposit(uint256 amount) external {
        asset.transferFrom(msg.sender, address(this), amount);
        balances[msg.sender] += amount;
    }
    
    function withdraw(uint256 amount) external {
        require(balances[msg.sender] >= amount, "Insufficient balance");
        balances[msg.sender] -= amount;
        asset.transfer(msg.sender, amount);
    }
    
    function balanceOf(address user) external view returns (uint256) {
        return balances[user];
    }
}
