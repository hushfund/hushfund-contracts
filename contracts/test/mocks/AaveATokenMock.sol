// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AavePoolMock} from "./AavePoolMock.sol";

/// @dev Stand-in for an Aave aToken: reports a holder's balance in the mock pool (balance grows with the index).
contract AaveATokenMock {
    AavePoolMock public immutable pool;
    address public immutable asset;

    constructor(AavePoolMock _pool, address _asset) {
        pool = _pool;
        asset = _asset;
    }

    function balanceOf(address user) external view returns (uint256) {
        return pool.getUserBalance(user, asset);
    }
}
