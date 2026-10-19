// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HushfundVault} from "../src/HushfundVault.sol";
import {HonkVerifier, IVerifier} from "../src/Verifier.sol";
import {BorrowHonkVerifier} from "../src/BorrowVerifier.sol";
import {Poseidon2Yul_BN254} from "../src/vendor/Poseidon2Yul.sol";
import {IPoseidon2} from "../src/vendor/IPoseidon2.sol";
import {IHushfundVault} from "../src/interfaces/IHushfundVault.sol";
import {IAavePool} from "../src/interfaces/IAavePool.sol";
import {IMorphoVault} from "../src/interfaces/IMorphoPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSDC} from "./mocks/MockERC20.sol";
import {AavePoolMock} from "./mocks/AavePoolMock.sol";
import {AaveATokenMock} from "./mocks/AaveATokenMock.sol";
import {MorphoVaultMock} from "./mocks/MorphoVaultMock.sol";

/// @notice End-to-end tests with real UltraHonk proofs and the real Solidity verifiers.
///         Needs Node.js and `npm install` in the repo root (the prover is bb.js, same as the frontend):
///
///   REAL_PROOFS=true forge test --ffi --match-contract RealProofTest -vv
contract RealProofTest is Test {
    uint256 constant FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    bytes32 constant RECEIVE_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    HushfundVault vault;
    MockUSDC usdc;
    address alice;
    uint256 aliceKey;
    address recipient = makeAddr("recipient");
    address relayer = makeAddr("relayer");
    bytes32[] leaves;

    function setUp() public {
        if (!vm.envOr("REAL_PROOFS", false)) vm.skip(true);
        (alice, aliceKey) = makeAddrAndKey("alice");
        usdc = new MockUSDC(0, "USD Coin");
        AavePoolMock aave = new AavePoolMock();
        vault = new HushfundVault(
            IVerifier(address(new HonkVerifier())),
            IVerifier(address(new BorrowHonkVerifier())),
            IPoseidon2(address(new Poseidon2Yul_BN254())),
            20,
            100e6,
            IERC20(address(usdc)),
            IAavePool(address(aave)),
            IERC20(address(new AaveATokenMock(aave, address(usdc)))),
            IMorphoVault(address(new MorphoVaultMock(IERC20(address(usdc))))),
            address(this),
            address(this),
            5
        );
        usdc.mint(alice, 10_000e6);
    }

    function _deposit(uint256 salt) internal returns (bytes32 nullifier, bytes32 secret, uint256 yieldIndex) {
        nullifier = bytes32(uint256(keccak256(abi.encode("n", salt))) % FIELD);
        secret = bytes32(uint256(keccak256(abi.encode("s", salt))) % FIELD);
        bytes32 inner = vault.hashLeftRight(nullifier, secret);
        yieldIndex = vault.getCurrentBucketedYieldIndex();
        vault.depositWithAuthorization(inner, _auth(100e6, vault.depositNonce(inner)));
        leaves.push(vault.hashLeftRight(inner, bytes32(yieldIndex)));
    }

    function _auth(uint256 value, bytes32 nonce) internal view returns (bytes memory) {
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                usdc.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(RECEIVE_TYPEHASH, alice, address(vault), value, 0, validBefore, nonce))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest);
        return abi.encode(alice, address(vault), value, 0, validBefore, nonce, v, r, s);
    }

    function _prove(string memory kind, bytes32 nullifier, bytes32 secret, uint256 yieldIndex, bytes32 ext)
        internal
        returns (bytes memory proof, bytes32[] memory pi)
    {
        string[] memory cmd = new string[](8 + leaves.length);
        cmd[0] = "npx";
        cmd[1] = "tsx";
        cmd[2] = "js-scripts/prove.ts";
        cmd[3] = kind;
        cmd[4] = vm.toString(nullifier);
        cmd[5] = vm.toString(secret);
        cmd[6] = vm.toString(bytes32(yieldIndex));
        cmd[7] = vm.toString(ext);
        for (uint256 i = 0; i < leaves.length; i++) {
            cmd[8 + i] = vm.toString(leaves[i]);
        }
        (proof, pi) = abi.decode(vm.ffi(cmd), (bytes, bytes32[]));
    }

    function test_realWithdraw_andTamperedRecipientFails() public {
        (bytes32 n, bytes32 s, uint256 yi) = _deposit(1);
        _deposit(2);
        bytes32 ext = vault.withdrawExtDataHash(recipient, relayer, 1e6);
        (bytes memory proof, bytes32[] memory pi) = _prove("withdraw", n, s, yi, ext);
        assertEq(pi[0], vault.getLatestRoot(), "root must match the on-chain tree (hash compatibility)");

        // a relayer that swaps the recipient is rejected by the verifier
        vm.expectRevert();
        vault.withdraw(proof, pi[0], pi[1], pi[2], yi, makeAddr("thief"), relayer, 1e6);

        vault.withdraw(proof, pi[0], pi[1], pi[2], yi, recipient, relayer, 1e6);
        assertGt(usdc.balanceOf(recipient), 0);
        assertEq(usdc.balanceOf(relayer), 1e6);
    }

    function test_realBorrow_andTamperedAmountFails() public {
        (bytes32 n, bytes32 s, uint256 yi) = _deposit(3);
        _deposit(4);
        bytes32 ext = vault.borrowExtDataHash(recipient, address(0), 0, 50e6);
        (bytes memory proof, bytes32[] memory pi) = _prove("borrow", n, s, yi, ext);

        vm.expectRevert();
        vault.borrow(proof, pi[0], pi[1], yi, recipient, 60e6, address(0), 0);

        vault.borrow(proof, pi[0], pi[1], yi, recipient, 50e6, address(0), 0);
        assertEq(usdc.balanceOf(recipient), 50e6);
    }

    function test_realRepay_renewsNote() public {
        (bytes32 n, bytes32 s, uint256 yi) = _deposit(5);
        _deposit(6);
        _realBorrow(n, s, yi, 50e6);
        (bytes32 newN, bytes32 newS) = _realRepay(n, s, yi);
        _realWithdraw(newN, newS, yi);
        assertGt(usdc.balanceOf(recipient), 50e6);
    }

    function _realBorrow(bytes32 n, bytes32 s, uint256 yi, uint256 amount) internal {
        (bytes memory proof, bytes32[] memory pi) =
            _prove("borrow", n, s, yi, vault.borrowExtDataHash(recipient, address(0), 0, amount));
        vault.borrow(proof, pi[0], pi[1], yi, recipient, amount, address(0), 0);
    }

    function _realRepay(bytes32 n, bytes32 s, uint256 yi) internal returns (bytes32 newN, bytes32 newS) {
        newN = bytes32(uint256(keccak256("renewed-n")) % FIELD);
        newS = bytes32(uint256(keccak256("renewed-s")) % FIELD);
        bytes32 newInner = vault.hashLeftRight(newN, newS);
        (bytes memory proof, bytes32[] memory pi) = _prove("withdraw", n, s, yi, vault.repayExtDataHash(newInner));
        bytes memory auth = _auth(vault.getDebt(pi[2]) + 1e6, vault.repayNonce(pi[2], newInner));
        vault.repayWithAuthorization(proof, pi[0], pi[1], pi[2], yi, newInner, auth);
        leaves.push(vault.hashLeftRight(newInner, bytes32(yi)));
    }

    function _realWithdraw(bytes32 n, bytes32 s, uint256 yi) internal {
        (bytes memory proof, bytes32[] memory pi) =
            _prove("withdraw", n, s, yi, vault.withdrawExtDataHash(recipient, address(0), 0));
        vault.withdraw(proof, pi[0], pi[1], pi[2], yi, recipient, address(0), 0);
    }
}
