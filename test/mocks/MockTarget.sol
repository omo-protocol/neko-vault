// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

contract MockTarget {
    uint256 public counter;
    mapping(address => uint256) public balances;

    event SomethingDone(address caller);
    event Deposited(address user, uint256 amount);

    function doSomething() external {
        counter++;
        emit SomethingDone(msg.sender);
    }

    function deposit(uint256 amount) external {
        balances[msg.sender] += amount;
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        require(balances[msg.sender] >= amount, "Insufficient balance");
        balances[msg.sender] -= amount;
    }

    receive() external payable {}
}