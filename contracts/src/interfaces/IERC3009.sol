// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The part of EIP-3009 that USDC implements and Hushfund uses.
interface IERC3009 {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}
