// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVerifier} from "../../src/Verifier.sol";

/// @dev Accepts or rejects every proof and records the public inputs the vault passed, so tests can check
///      that their order and values match the circuits exactly.
contract RecordingVerifier is IVerifier {
    bool public result = true;
    bytes32[] internal s_last;
    uint256 public calls;

    function setResult(bool r) external {
        result = r;
    }

    function verify(bytes calldata, bytes32[] calldata publicInputs) external returns (bool) {
        delete s_last;
        for (uint256 i = 0; i < publicInputs.length; i++) {
            s_last.push(publicInputs[i]);
        }
        calls++;
        return result;
    }

    function last() external view returns (bytes32[] memory) {
        return s_last;
    }
}
