// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @notice Minimal interface for a MetaMorpho vault (ERC-4626).
interface IMorphoVault {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address onBehalfOf) external returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function convertToShares(uint256 assets) external view returns (uint256 shares);
    function totalAssets() external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
}
