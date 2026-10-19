// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @notice Minimal interface for Aave V3 Pool
interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getReserveNormalizedIncome(address asset) external view returns (uint256);
}
