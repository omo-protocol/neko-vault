// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract MockTarget {
    uint256 public counter;
    mapping(address => uint256) public balances;
    address public asset;

    event SomethingDone(address caller);
    event Deposited(address user, uint256 amount);

    constructor(address _asset) {
        asset = _asset;
    }

    function doSomething() external {
        counter++;
        emit SomethingDone(msg.sender);
    }

    function deposit(uint256 amount) external {
        // Pull tokens from sender if asset is configured
        if (asset != address(0)) {
            IERC20(asset).transferFrom(msg.sender, address(this), amount);
        }
        balances[msg.sender] += amount;
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        require(balances[msg.sender] >= amount, "Insufficient balance");
        balances[msg.sender] -= amount;
        // Return tokens to sender
        if (asset != address(0)) {
            IERC20(asset).transfer(msg.sender, amount);
        }
    }

    receive() external payable {}
}