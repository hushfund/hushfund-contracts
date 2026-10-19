// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAavePool} from "../../src/interfaces/IAavePool.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Mock of Aave V3 Pool for local contract tests only.
///      Stores scaled balances and applies normalizedIncome on read,
///      just like real aTokens.
contract AavePoolMock is IAavePool, Ownable {
    using SafeERC20 for IERC20;

    uint256 private constant RAY = 1e27;

    mapping(address => mapping(address => uint256)) public scaledBalances;
    mapping(address => uint256) public normalizedIncome;

    event Supply(address indexed asset, uint256 amount, address indexed onBehalfOf);
    event Withdraw(address indexed asset, uint256 amount, address indexed to);

    constructor() Ownable(msg.sender) {}

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        uint256 index = _getIncome(asset);
        scaledBalances[onBehalfOf][asset] += (amount * RAY) / index;
        emit Supply(asset, amount, onBehalfOf);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        uint256 index = _getIncome(asset);
        uint256 currentBalance = (scaledBalances[msg.sender][asset] * index) / RAY;

        if (amount > currentBalance) {
            amount = currentBalance;
        }

        uint256 scaledAmount = (amount * RAY) / index;
        scaledBalances[msg.sender][asset] -= scaledAmount;

        IERC20(asset).safeTransfer(to, amount);
        emit Withdraw(asset, amount, to);
        return amount;
    }

    function getReserveNormalizedIncome(address asset) external view returns (uint256) {
        return _getIncome(asset);
    }

    function _getIncome(address asset) internal view returns (uint256) {
        uint256 income = normalizedIncome[asset];
        return income == 0 ? RAY : income;
    }

    /// @dev Local test helper: set normalizedIncome to simulate yield accrual.
    function setNormalizedIncome(address asset, uint256 income) external onlyOwner {
        normalizedIncome[asset] = income;
    }

    function getUserBalance(address user, address asset) external view returns (uint256) {
        uint256 index = _getIncome(asset);
        return (scaledBalances[user][asset] * index) / RAY;
    }
}
