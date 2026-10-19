// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HushfundVault, IVerifier} from "../src/HushfundVault.sol";
import {Poseidon2} from "@poseidon/src/Poseidon2.sol";
import {Poseidon2Yul_BN254} from "../src/vendor/Poseidon2Yul.sol";
import {IPoseidon2} from "../src/vendor/IPoseidon2.sol";
import {IAavePool} from "../src/interfaces/IAavePool.sol";
import {IMorphoVault} from "../src/interfaces/IMorphoPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSDC} from "./mocks/MockERC20.sol";
import {AavePoolMock} from "./mocks/AavePoolMock.sol";
import {AaveATokenMock} from "./mocks/AaveATokenMock.sol";
import {MorphoVaultMock} from "./mocks/MorphoVaultMock.sol";
import {RecordingVerifier} from "./mocks/RecordingVerifier.sol";
import {Field} from "@poseidon/src/Field.sol";

contract Base is Test {
    uint256 internal constant FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant DENOMINATION = 1_000e6;
    bytes32 internal constant RECEIVE_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    HushfundVault internal vault;
    MockUSDC internal usdc;
    AavePoolMock internal aave;
    AaveATokenMock internal aToken;
    MorphoVaultMock internal morpho;
    Poseidon2 internal poseidon; // reference Solidity implementation (tests only)
    RecordingVerifier internal withdrawVerifier;
    RecordingVerifier internal borrowVerifier;

    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice;
    uint256 internal aliceKey;
    address internal bob;
    uint256 internal bobKey;
    address internal recipient = makeAddr("recipient");
    address internal relayer = makeAddr("relayer");

    uint256 private _salt;

    struct Note {
        bytes32 nullifier;
        bytes32 secret;
        bytes32 inner;
        bytes32 nullifierHash;
        bytes32 collateralHash;
        uint256 yieldIndex;
        bytes32 commitment;
    }

    function setUp() public virtual {
        (alice, aliceKey) = makeAddrAndKey("alice");
        (bob, bobKey) = makeAddrAndKey("bob");

        usdc = new MockUSDC(0, "USD Coin");
        aave = new AavePoolMock();
        aToken = new AaveATokenMock(aave, address(usdc));
        morpho = new MorphoVaultMock(IERC20(address(usdc)));
        poseidon = new Poseidon2();
        withdrawVerifier = new RecordingVerifier();
        borrowVerifier = new RecordingVerifier();

        vault = new HushfundVault(
            IVerifier(address(withdrawVerifier)),
            IVerifier(address(borrowVerifier)),
            IPoseidon2(address(new Poseidon2Yul_BN254())),
            20,
            DENOMINATION,
            IERC20(address(usdc)),
            IAavePool(address(aave)),
            IERC20(address(aToken)),
            IMorphoVault(address(morpho)),
            owner,
            feeRecipient,
            5
        );

        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);
    }

    // ---------------- notes ----------------

    function _newNote() internal returns (Note memory n) {
        _salt++;
        n.nullifier = bytes32(uint256(keccak256(abi.encode("nullifier", _salt))) % FIELD);
        n.secret = bytes32(uint256(keccak256(abi.encode("secret", _salt))) % FIELD);
        n.inner = vault.hashLeftRight(n.nullifier, n.secret);
        n.nullifierHash = Field.toBytes32(poseidon.hash_1(Field.toField(n.nullifier)));
        n.collateralHash = vault.hashLeftRight(n.nullifier, bytes32(uint256(1)));
    }

    function _deposit(address from, uint256 key) internal returns (Note memory n) {
        n = _newNote();
        n.yieldIndex = vault.getCurrentBucketedYieldIndex();
        n.commitment = vault.hashLeftRight(n.inner, bytes32(n.yieldIndex));
        bytes memory auth = _auth(from, key, DENOMINATION, vault.depositNonce(n.inner));
        vault.depositWithAuthorization(n.inner, auth);
    }

    /// @dev Builds the abi-encoded EIP-3009 authorization the vault expects.
    function _auth(address from, uint256 key, uint256 value, bytes32 nonce) internal view returns (bytes memory) {
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 structHash =
            keccak256(abi.encode(RECEIVE_TYPEHASH, from, address(vault), value, validAfter, validBefore, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encode(from, address(vault), value, validAfter, validBefore, nonce, v, r, s);
    }

    // ---------------- actions ----------------

    // Each action helper takes an optional expected revert. It is armed right before the vault call, after the
    // view calls that build the arguments (vm.expectRevert applies to the very next external call).
    bytes internal constant OK = "";
    bytes internal constant ANY = "any";

    function _arm(bytes memory err) internal {
        if (err.length == 0) return;
        if (keccak256(err) == keccak256(ANY)) vm.expectRevert();
        else vm.expectRevert(err);
    }

    function _withdraw(Note memory n, address to, address rel, uint256 fee) internal {
        _withdraw(n, to, rel, fee, OK);
    }

    function _withdraw(Note memory n, address to, address rel, uint256 fee, bytes memory err) internal {
        bytes32 root = vault.getLatestRoot();
        _arm(err);
        vault.withdraw(hex"01", root, n.nullifierHash, n.collateralHash, n.yieldIndex, to, rel, fee);
    }

    function _borrow(Note memory n, address to, uint256 amount, address rel, uint256 fee) internal {
        _borrow(n, to, amount, rel, fee, OK);
    }

    function _borrow(Note memory n, address to, uint256 amount, address rel, uint256 fee, bytes memory err) internal {
        bytes32 root = vault.getLatestRoot();
        _arm(err);
        vault.borrow(hex"02", root, n.collateralHash, n.yieldIndex, to, amount, rel, fee);
    }

    function _repay(Note memory n, address payer, uint256 key, uint256 value) internal returns (Note memory) {
        return _repay(n, payer, key, value, OK);
    }

    function _repay(Note memory n, address payer, uint256 key, uint256 value, bytes memory err)
        internal
        returns (Note memory renewed)
    {
        renewed = _newNote();
        renewed.yieldIndex = n.yieldIndex;
        renewed.commitment = vault.hashLeftRight(renewed.inner, bytes32(n.yieldIndex));
        bytes memory auth = _auth(payer, key, value, vault.repayNonce(n.collateralHash, renewed.inner));
        bytes32 root = vault.getLatestRoot();
        _arm(err);
        vault.repayWithAuthorization(hex"03", root, n.nullifierHash, n.collateralHash, n.yieldIndex, renewed.inner, auth);
    }

    // ---------------- yield ----------------

    /// @dev Grows both strategies by `bps` basis points, funding the extra USDC like real interest would.
    function _accrue(uint256 bps) internal {
        uint256 aaveBal = aToken.balanceOf(address(vault));
        uint256 income = aave.getReserveNormalizedIncome(address(usdc));
        aave.setNormalizedIncome(address(usdc), (income * (10_000 + bps)) / 10_000);
        usdc.mint(address(aave), (aaveBal * bps) / 10_000 + 1);

        uint256 extra = (morpho.totalAssets() * bps) / 10_000;
        if (extra > 0) {
            usdc.mint(address(this), extra);
            usdc.approve(address(morpho), extra);
            morpho.simulateYield(extra);
        }
    }

    function _strategyAssets() internal view returns (uint256) {
        return aToken.balanceOf(address(vault)) + morpho.maxWithdraw(address(vault));
    }
}
