// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Poseidon2} from "@poseidon/src/Poseidon2.sol";
import {LibPoseidon2Yul} from "../src/vendor/LibPoseidon2Yul.sol";
import {Poseidon2Yul_BN254} from "../src/vendor/Poseidon2Yul.sol";
import {IPoseidon2} from "../src/vendor/IPoseidon2.sol";
import {Field} from "@poseidon/src/Field.sol";
import {IncrementalMerkleTree} from "../src/IncrementalMerkleTree.sol";

/// @dev The Merkle tree must hash exactly like the Noir circuit (Poseidon2 via noir-lang/poseidon), otherwise
///      browser proofs would not match on-chain roots. The Solidity Poseidon2 is the reference the original
///      project used; the Yul version must agree with it on every input.
contract Tree is IncrementalMerkleTree {
    constructor() IncrementalMerkleTree(20, IPoseidon2(address(new Poseidon2Yul_BN254()))) {}

    function insert(bytes32 leaf) external returns (uint32) {
        return _insert(leaf);
    }
}

contract Poseidon2EquivalenceTest is Test {
    uint256 constant FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    Poseidon2 ref;

    function setUp() public {
        ref = new Poseidon2();
    }

    function _yul2(uint256 a, uint256 b) internal pure returns (bytes32) {
        return bytes32(LibPoseidon2Yul.hash_2(a, b));
    }

    function testFuzz_hash2_matchesReference(uint256 a, uint256 b) public view {
        a = bound(a, 0, FIELD - 1);
        b = bound(b, 0, FIELD - 1);
        bytes32 expected = Field.toBytes32(ref.hash_2(Field.toField(a), Field.toField(b)));
        assertEq(_yul2(a, b), expected);
    }

    function testFuzz_hash1_matchesReference(uint256 a) public view {
        a = bound(a, 0, FIELD - 1);
        bytes32 expected = Field.toBytes32(ref.hash_1(Field.toField(a)));
        assertEq(bytes32(LibPoseidon2Yul.hash_1(a)), expected);
    }

    /// @dev The deployed hasher contract (what the vault calls) must agree with the library and the reference.
    function testFuzz_hasherContract_matchesReference(uint256 a, uint256 b) public {
        a = bound(a, 0, FIELD - 1);
        b = bound(b, 0, FIELD - 1);
        IPoseidon2 h = IPoseidon2(address(new Poseidon2Yul_BN254()));
        assertEq(bytes32(h.hash_2(a, b)), Field.toBytes32(ref.hash_2(Field.toField(a), Field.toField(b))));
    }

    function test_edgeValues() public view {
        uint256[4] memory v = [uint256(0), 1, FIELD - 1, FIELD / 2];
        for (uint256 i = 0; i < 4; i++) {
            for (uint256 j = 0; j < 4; j++) {
                bytes32 expected = Field.toBytes32(ref.hash_2(Field.toField(v[i]), Field.toField(v[j])));
                assertEq(_yul2(v[i], v[j]), expected);
            }
        }
    }

    /// @dev The precomputed zero-subtree roots must be consistent with the hasher.
    function test_zerosAreConsistent() public {
        Tree t = new Tree();
        for (uint256 i = 0; i < 20; i++) {
            assertEq(t.hashLeftRight(t.zeros(i), t.zeros(i)), t.zeros(i + 1));
        }
    }

    /// @dev Rebuilds the tree with the reference hash and compares roots after every insert.
    function test_treeRootsMatchReference() public {
        Tree t = new Tree();
        bytes32[] memory leaves = new bytes32[](12);
        for (uint256 i = 0; i < 12; i++) {
            leaves[i] = bytes32(uint256(keccak256(abi.encode(i))) % FIELD);
            t.insert(leaves[i]);
            assertEq(t.getLatestRoot(), _refRoot(t, leaves, i + 1));
        }
    }

    function _refRoot(Tree t, bytes32[] memory leaves, uint256 count) internal view returns (bytes32) {
        bytes32[] memory level = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) level[i] = leaves[i];
        uint256 n = count;
        for (uint256 d = 0; d < 20; d++) {
            uint256 m = (n + 1) / 2;
            bytes32[] memory next = new bytes32[](m);
            for (uint256 i = 0; i < m; i++) {
                bytes32 l = level[2 * i];
                bytes32 r = 2 * i + 1 < n ? level[2 * i + 1] : t.zeros(d);
                next[i] = Field.toBytes32(ref.hash_2(Field.toField(l), Field.toField(r)));
            }
            level = next;
            n = m;
        }
        return level[0];
    }
}

