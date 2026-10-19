// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoseidon2} from "./vendor/IPoseidon2.sol";


contract IncrementalMerkleTree {
    uint256 public constant FIELD_SIZE = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    // the "zero" element is the default value for the Merkle tree, it is used to fill in empty nodes keccak256("privacy") % FIELD_SIZE
    bytes32 public constant ZERO_ELEMENT = bytes32(0x2b0df951ef3a8bf2a23ac5acc4f59acca38c21ca13cbb63d412a8da53f58823b);
    /// @dev Poseidon2 hasher (vendor/Poseidon2Yul.sol, ~20k gas per hash; the Solidity reference the original
    ///      project used costs ~220k). Kept as a separate contract so the vault stays under the 24 KB size limit.
    IPoseidon2 public immutable i_hasher;

    uint32 public immutable i_depth; // the depth of the Merkle tree, i.e. the number of levels in the tree

    mapping(uint256 => bytes32) private s_cachedSubtrees; // subtrees for already stored commitments
    mapping(uint256 => bytes32) public s_roots; // ROOT_HISTORY_SIZE roots for the Merkle tree
    uint32 public constant ROOT_HISTORY_SIZE = 30; // the number of roots stored to compare proofs against
    uint32 public s_currentRootIndex = 0; // where in ROOT_HISTORY_SIZE the current root is stored in the roots array
    uint32 public s_nextLeafIndex = 0; // the index of the next leaf index to be inserted into the tree

    error IncrementalMerkleTree__LeftValueOutOfRange(bytes32 left);
    error IncrementalMerkleTree__RightValueOutOfRange(bytes32 right);
    error IncrementalMerkleTree__LevelsShouldBeGreaterThanZero(uint32 depth);
    error IncrementalMerkleTree__LevelsShouldBeLessThan32(uint32 depth);
    error IncrementalMerkleTree__MerkleTreeFull(uint32 nextIndex);
    error IncrementalMerkleTree__IndexOutOfBounds(uint256 index);

    constructor(uint32 _depth, IPoseidon2 _hasher) {
        if (_depth == 0) {
            revert IncrementalMerkleTree__LevelsShouldBeGreaterThanZero(_depth);
        }
        if (_depth >= 32) {
            revert IncrementalMerkleTree__LevelsShouldBeLessThan32(_depth);
        }
        i_depth = _depth;
        i_hasher = _hasher;

        s_roots[0] = zeros(_depth);
    }

    /**
     * @dev Hash 2 tree leaves, returns Poseidon(_left, _right)
     */
    function hashLeftRight(bytes32 _left, bytes32 _right) public view returns (bytes32) {
        // these checks aren't needed since the hash function will return a valid value
        if (uint256(_left) >= FIELD_SIZE) {
            revert IncrementalMerkleTree__LeftValueOutOfRange(_left);
        }
        if (uint256(_right) >= FIELD_SIZE) {
            revert IncrementalMerkleTree__RightValueOutOfRange(_right);
        }

        return bytes32(i_hasher.hash_2(uint256(_left), uint256(_right)));
    }

    function _insert(bytes32 _leaf) internal returns (uint32 index) {
        uint32 _nextLeafIndex = s_nextLeafIndex;
        if (_nextLeafIndex == uint32(2) ** i_depth) {
            revert IncrementalMerkleTree__MerkleTreeFull(_nextLeafIndex);
        }
        uint32 currentIndex = _nextLeafIndex; // the index of the current node starting with the leaf and working up
        bytes32 currentHash = _leaf; // the actual value of the current node starting with the leaf and working up
        bytes32 left; // the node that needs to be on the left side of the hash
        bytes32 right; // the node that needs to be on the right side of the hash

        for (uint32 i = 0; i < i_depth; i++) {
            // check if the index is even
            if (currentIndex % 2 == 0) {
                // if even, the current node is the left child and the right child is a zero subtree of depth = the current depth we are at i
                left = currentHash;
                right = zeros(i);
                // cache the calculated hash as a sebtree root
                s_cachedSubtrees[i] = currentHash;
            } else {
                // if odd, the current node is the right child and the left child is a cached subtree of depth = the current depth we are at i
                left = s_cachedSubtrees[i];
                right = currentHash;
            }
            // calculate the hash of the left and right nodes
            currentHash = hashLeftRight(left, right);
            // go up a level by halving the index (this is easier to see if you visualize the tree)
            currentIndex /= 2;
        }

        // at this point we have calculated the root of the tree, so we can store it in the roots array
        // calculate the next index in the array
        uint32 newRootIndex = (s_currentRootIndex + 1) % ROOT_HISTORY_SIZE;
        // store the index of the new root we are adding
        s_currentRootIndex = newRootIndex;
        // store the new root in the roots array
        s_roots[newRootIndex] = currentHash;
        // store the index of the next leaf to be inserted ready for the next deposit
        s_nextLeafIndex = _nextLeafIndex + 1;
        // return the index of the leaf we just inserted to be passed to the deposit event
        return _nextLeafIndex;
    }

    /**
     * @dev Whether the root is present in the root history
     */
    function isKnownRoot(bytes32 _root) public view returns (bool) {
        // check if they are trying to bypass the check by passing a zero root which is the defualt value
        if (_root == bytes32(0)) {
            return false;
        }
        uint32 _currentRootIndex = s_currentRootIndex; // cash the result so we don't have to read it multiple times
        uint32 i = _currentRootIndex; // show the diagram:)
        do {
            if (_root == s_roots[i]) {
                return true; // the root is present in the history
            }
            if (i == 0) {
                i = ROOT_HISTORY_SIZE; // we have got to the end of the array and need to wrap around
            }
            i--;
        } while (i != _currentRootIndex); // once we get back to the current root index, we are done
        return false; // the root is not present in the history
    }

    /**
     * @dev Returns the latest root
     */
    function getLatestRoot() public view returns (bytes32) {
        return s_roots[s_currentRootIndex];
    }

    // NOTE: change when you know the hash function to use
    /// @notice Returns the root of a subtree at the given depth
    /// @param i The depth of the subtree root to return
    /// @return The root of the given subtree
    function zeros(uint256 i) public pure returns (bytes32) {
        if (i == 0) return bytes32(0x2b0df951ef3a8bf2a23ac5acc4f59acca38c21ca13cbb63d412a8da53f58823b);
        else if (i == 1) return bytes32(0x0a1cc9dbf552c542379dee34a6616bd37fec1b0962c4fbe314a01cffac8308c3);
        else if (i == 2) return bytes32(0x0a6110e905ebe9c8a2a439acd710643468b9f51122440aadf091a4b6f167dba7);
        else if (i == 3) return bytes32(0x258e86d2ad936208dc4faebd94dcb560775b4a8a1d706f968387f99f03e9f1af);
        else if (i == 4) return bytes32(0x05721de377a87fe563e9012cbe21790b472bb4d430248322a7d55c340e99cc19);
        else if (i == 5) return bytes32(0x090bfc4cc3a2866a647c6fa30145eee92e99040f2993d11564bd465664203d05);
        else if (i == 6) return bytes32(0x24f174edec8ffbdea445407a17c7561917dab67efc2066314e02169a5f2bd176);
        else if (i == 7) return bytes32(0x0a3ecad8587b9b576b30d87b26e7df73a01e0cab533609f89133b635d47da8e6);
        else if (i == 8) return bytes32(0x2e90b8eab7dcc8a1fafa1010d660b076ddd9e5ebd03daed8c86b72ab7a283bdc);
        else if (i == 9) return bytes32(0x11a1e63d4bcdf3bbd6063b3ed48c4fb16c6a309b13e07580e3f839d499534282);
        else if (i == 10) return bytes32(0x2c48eb427f0f886a60397a3fba5d15f6bd143ae5f174a10d22bde36a61101986);
        else if (i == 11) return bytes32(0x037cd7c51c74293d8ffb4f0e5f651b0c25c1dc2a353de5d50c9aa1b44bf9ae8a);
        else if (i == 12) return bytes32(0x158cfadd0317fc74ea136cf413ae55930ca54df49b188d9dd13f00577daa8087);
        else if (i == 13) return bytes32(0x07335e0b5bd0204ec32988ef68a2359fca5a1958bf40f9d71dd4841ee5cec9e9);
        else if (i == 14) return bytes32(0x1da000a45af447517f4fca21d41b7673cade7a1211dc6e5d52f65c1799812a81);
        else if (i == 15) return bytes32(0x106b7a78ff69c3215c39f302b148d1c570a5285ff53c440577007d078445716b);
        else if (i == 16) return bytes32(0x00d4db11baf5c43d1c76c87f22f1f33c5437298a2c6beb780703e7e92bee7d6f);
        else if (i == 17) return bytes32(0x1efe71b822044ba01cc663f102b111b0dabd3ca7f73402a29ecce5227706a2a5);
        else if (i == 18) return bytes32(0x13754ca04c0c2a7b4e5f82c6aae25705d6e0ee0b7094d05641b7adeef34a8449);
        else if (i == 19) return bytes32(0x0657e306bfe45d146af75eb24df29e329a963f4d5936d9ceb9484c023083f593);
        else if (i == 20) return bytes32(0x10818f8e49e6bcb2947974a99dd7044f39d593aca03d1d409576fdb4d42c499c);
        else if (i == 21) return bytes32(0x07549d3b880272463ee20c2d21d11a9c75641a615298e720ee3cc4bd1320aea9);
        else if (i == 22) return bytes32(0x24b4c553b100ee6d1e61b5c2749771dde51d467d9fd6835e433092bdc54062af);
        else if (i == 23) return bytes32(0x1c61d04aa13f846b386357ff6c6e1a4598e05f049d07fd5ed7d7a7090dd388ce);
        else if (i == 24) return bytes32(0x07129e3a2402ad700820a983f5c67e52a94cd723b9503169ad1497ee0a9d1bbf);
        else if (i == 25) return bytes32(0x2937eda145e485b1c063e21a4ccacb2ab962b3839153bb429bae55ee91dcb505);
        else if (i == 26) return bytes32(0x2ca0025527955fda4a822fc2cbbb8e4173f9eed2686876d404dd5722d38c26af);
        else if (i == 27) return bytes32(0x1da16d9077f5da8a807b8db1838e4f20988ecfcb6e2cc2b57c83e90e8609ce5e);
        else if (i == 28) return bytes32(0x2cb09a9f118e8a9513cbc3afc3a6dd2b45c344e27ec869c809aabd3b7494ee05);
        else if (i == 29) return bytes32(0x10806cef53c66f51fedcd6aa84aad612fe0d8e44ee2df3c17501eb997e280637);
        else if (i == 30) return bytes32(0x2b747672dc3a2c356fa264d3abf718798f46c6c12e4980395093f10ffc888831);
        else if (i == 31) return bytes32(0x1df76f78296ff7c7e288d0c7cab2907cf355dc95b0a476de80884dcfc6e40f6b);
        else revert IncrementalMerkleTree__IndexOutOfBounds(i);
    }
}
