// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMorphoVault} from "../../src/interfaces/IMorphoPool.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Mock of a MetaMorpho vault (ERC-4626) for local contract tests only.
contract MorphoVaultMock is IMorphoVault, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;

    uint256 public totalShares;
    uint256 public totalAssetsBacking;

    mapping(address => uint256) public shareBalances;

    constructor(IERC20 _asset) Ownable(msg.sender) {
        asset = _asset;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = convertToShares(assets);
        asset.safeTransferFrom(msg.sender, address(this), assets);
        totalShares += shares;
        totalAssetsBacking += assets;
        shareBalances[receiver] += shares;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        shares = convertToShares(assets);
        if (shares > shareBalances[owner]) {
            shares = shareBalances[owner];
            assets = convertToAssets(shares);
        }
        shareBalances[owner] -= shares;
        totalShares -= shares;
        totalAssetsBacking -= assets;
        asset.safeTransfer(receiver, assets);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        if (totalShares == 0) return shares;
        return (shares * totalAssetsBacking) / totalShares;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        if (totalShares == 0) return assets;
        return (assets * totalShares) / totalAssetsBacking;
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        return convertToAssets(shareBalances[owner]);
    }

    function totalAssets() external view returns (uint256) {
        return totalAssetsBacking;
    }

    /// @dev Local test helper: simulate yield by donating assets (increases share price).
    function simulateYield(uint256 extraAssets) external onlyOwner {
        asset.safeTransferFrom(msg.sender, address(this), extraAssets);
        totalAssetsBacking += extraAssets;
    }

    /// @dev Local test helper: simulate yield without token transfer.
    function setTotalAssets(uint256 newTotal) external onlyOwner {
        totalAssetsBacking = newTotal;
    }
}
