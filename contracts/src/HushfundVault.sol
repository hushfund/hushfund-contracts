// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVerifier} from "./Verifier.sol";
import {IncrementalMerkleTree} from "./IncrementalMerkleTree.sol";
import {IPoseidon2} from "./vendor/IPoseidon2.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAavePool} from "./interfaces/IAavePool.sol";
import {IMorphoVault} from "./interfaces/IMorphoPool.sol";
import {IERC3009} from "./interfaces/IERC3009.sol";
import {IHushfundVault} from "./interfaces/IHushfundVault.sol";

/// @title HushfundVault
/// @notice Fixed-denomination private USDC vault. Deposits earn yield in Aave V3 and a Morpho (ERC-4626) vault,
///         withdrawals and loans are authorised with zero-knowledge proofs of note ownership.
/// @dev Derived from Privacy Vaults (github.com/bri3t/Privacy-Vaults). Changes for Ethereum mainnet:
///      - every public input is checked to be a canonical field element (prevents nullifier malleability / double spends)
///      - EIP-3009 nonces are bound to the commitment, so a front-runner cannot steal a pending deposit or repayment
///      - proofs bind an ext-data hash (recipient, relayer, relayer fee, borrow amount, chain id, vault) so relayers
///        can submit transactions without being able to change where the money goes
///      - repaying a loan retires the old note and inserts a fresh one, so a borrow cannot be linked to the withdrawal
///      - overpayment on repay is refunded, liquidity is pulled from whichever strategy has it
///      - deposits/borrows can be paused (withdrawals and repayments never can), ownership transfer is two-step,
///        and strategy changes go through a time-locked migration that moves the funds along
contract HushfundVault is IncrementalMerkleTree, ReentrancyGuard, Ownable2Step, Pausable, IHushfundVault {
    using SafeERC20 for IERC20;

    uint256 private constant RAY = 1e27;
    /// @dev Yield index is rounded to this granularity (1e-4 of RAY, roughly one day at 4-5% APY) so that deposits
    ///      made in the same period share a yield index and stay indistinguishable.
    uint256 private constant BUCKET_PRECISION = 1e23;
    uint256 private constant ONE_SHARE = 1e18;
    uint256 private constant LTV_BPS = 7000;
    uint256 private constant BPS = 10_000;
    uint256 private constant MAX_FEE_BPS = 100; // protocol fee can never exceed 1%
    uint64 public constant MIGRATION_DELAY = 2 days;

    uint256 private constant ACTION_WITHDRAW = 1;
    uint256 private constant ACTION_REPAY = 2;
    uint256 private constant ACTION_BORROW = 3;
    bytes32 private constant DEPOSIT_TAG = keccak256("hushfund.deposit.v1");
    bytes32 private constant REPAY_TAG = keccak256("hushfund.repay.v1");

    IERC20 public immutable token;
    IVerifier public immutable i_verifier; // withdraw + repay circuit
    IVerifier public immutable i_borrowVerifier; // borrow circuit
    uint256 public immutable DENOMINATION;

    IAavePool public aavePool;
    IERC20 public aToken;
    IMorphoVault public morphoVault;

    // Both strategy indices are normalised to start at RAY; funds are split in the ratio of the two indices.
    uint256 public s_aaveBaseIndex;
    uint256 public s_aaveBaseIncome;
    uint256 public s_morphoBaseIndex;
    uint256 public s_morphoBasePrice;

    mapping(bytes32 => bool) public s_nullifierHashes;
    mapping(bytes32 => bool) public s_commitments;
    mapping(bytes32 => Loan) public s_loans;
    mapping(bytes32 => bool) public s_collateralSpent;
    uint256 public totalBorrowed;

    uint256 public s_withdrawalFeeBps;
    address public s_feeRecipient;

    PendingMigration public s_pendingMigration;

    constructor(
        IVerifier _verifier,
        IVerifier _borrowVerifier,
        IPoseidon2 _hasher,
        uint32 _merkleTreeDepth,
        uint256 _denomination,
        IERC20 _token,
        IAavePool _aavePool,
        IERC20 _aToken,
        IMorphoVault _morphoVault,
        address _owner,
        address _feeRecipient,
        uint256 _feeBps
    ) IncrementalMerkleTree(_merkleTreeDepth, _hasher) Ownable(_owner) {
        if (address(_verifier) == address(0) || address(_borrowVerifier) == address(0)) revert Hushfund__InvalidProof();
        if (_denomination == 0) revert Hushfund__DepositValueMismatch(1, 0);
        if (address(_token).code.length == 0) revert Hushfund__InvalidPoolAddress("token", address(_token));
        if (_feeRecipient == address(0)) revert Hushfund__InvalidFeeRecipient();
        if (_feeBps > MAX_FEE_BPS) revert Hushfund__FeeTooHigh(_feeBps, MAX_FEE_BPS);

        i_verifier = _verifier;
        i_borrowVerifier = _borrowVerifier;
        DENOMINATION = _denomination;
        token = _token;
        s_feeRecipient = _feeRecipient;
        s_withdrawalFeeBps = _feeBps;

        _setStrategies(address(_aavePool), address(_aToken), address(_morphoVault), RAY, RAY);
    }

    // ------------------------------------------------------------------
    // Yield index
    // ------------------------------------------------------------------

    function getAaveIndex() public view returns (uint256) {
        return (s_aaveBaseIndex * aavePool.getReserveNormalizedIncome(address(token))) / s_aaveBaseIncome;
    }

    function getMorphoIndex() public view returns (uint256) {
        return (s_morphoBaseIndex * morphoVault.convertToAssets(ONE_SHARE)) / s_morphoBasePrice;
    }

    /// @notice Current blended (Aave + Morpho) index, not bucketed. Used for payouts and debt.
    function getCurrentYieldIndex() public view returns (uint256) {
        return (getAaveIndex() + getMorphoIndex()) / 2;
    }

    /// @notice Index stored with new deposits: the next bucket boundary above the current index. Deposits in the
    ///         same period share it (privacy), and because it is always above the true index the vault can never
    ///         owe more than it holds. A note forgoes at most one bucket (~1 day) of yield.
    function getCurrentBucketedYieldIndex() public view returns (uint256) {
        return (getCurrentYieldIndex() / BUCKET_PRECISION + 1) * BUCKET_PRECISION;
    }

    // ------------------------------------------------------------------
    // Helpers exposed for the frontend and relayer
    // ------------------------------------------------------------------

    /// @notice The EIP-3009 nonce a depositor must sign. Binding it to the commitment stops front-running.
    function depositNonce(bytes32 innerCommitment) public view returns (bytes32) {
        return keccak256(abi.encode(DEPOSIT_TAG, block.chainid, address(this), innerCommitment));
    }

    /// @notice The EIP-3009 nonce a payer must sign to repay a loan and receive the renewed note.
    function repayNonce(bytes32 collateralNullifierHash, bytes32 newInnerCommitment) public view returns (bytes32) {
        return keccak256(abi.encode(REPAY_TAG, block.chainid, address(this), collateralNullifierHash, newInnerCommitment));
    }

    function withdrawExtDataHash(address recipient, address relayer, uint256 relayerFee) public view returns (bytes32) {
        return _toField(abi.encode(ACTION_WITHDRAW, block.chainid, address(this), recipient, relayer, relayerFee));
    }

    function borrowExtDataHash(address recipient, address relayer, uint256 relayerFee, uint256 amount)
        public
        view
        returns (bytes32)
    {
        return _toField(abi.encode(ACTION_BORROW, block.chainid, address(this), recipient, relayer, relayerFee, amount));
    }

    function repayExtDataHash(bytes32 newInnerCommitment) public view returns (bytes32) {
        return _toField(abi.encode(ACTION_REPAY, block.chainid, address(this), newInnerCommitment));
    }

    // ------------------------------------------------------------------
    // Deposit
    // ------------------------------------------------------------------

    /// @param innerCommitment Poseidon2(nullifier, secret), computed in the browser.
    /// @param receiveAuthorization abi.encode(from, to, value, validAfter, validBefore, nonce, v, r, s) for USDC's
    ///        receiveWithAuthorization. `nonce` must equal depositNonce(innerCommitment).
    function depositWithAuthorization(bytes32 innerCommitment, bytes calldata receiveAuthorization)
        external
        nonReentrant
        whenNotPaused
    {
        uint256 yieldIndex = getCurrentBucketedYieldIndex();
        bytes32 commitment = hashLeftRight(innerCommitment, bytes32(yieldIndex)); // also range-checks innerCommitment
        if (s_commitments[commitment]) revert Hushfund__CommitmentAlreadyAdded(commitment);
        s_commitments[commitment] = true;

        address from = _receive(receiveAuthorization, DENOMINATION, depositNonce(innerCommitment), true);

        _supply(DENOMINATION);
        uint32 leafIndex = _insert(commitment);

        emit Commitment(commitment, leafIndex, block.timestamp, yieldIndex);
        emit Deposit(commitment, from);
    }

    // ------------------------------------------------------------------
    // Withdraw
    // ------------------------------------------------------------------

    /// @notice Withdraw a note. Anyone (typically a relayer) may submit; the proof fixes recipient, relayer and fee.
    function withdraw(
        bytes calldata proof,
        bytes32 root,
        bytes32 nullifierHash,
        bytes32 collateralNullifierHash,
        uint256 yieldIndex,
        address recipient,
        address relayer,
        uint256 relayerFee
    ) external nonReentrant {
        _checkSpend(root, nullifierHash, collateralNullifierHash, yieldIndex);
        _checkParties(recipient, relayer, relayerFee);
        if (s_loans[collateralNullifierHash].active) revert Hushfund__CollateralLocked(collateralNullifierHash);

        _verifySpend(proof, root, nullifierHash, collateralNullifierHash, withdrawExtDataHash(recipient, relayer, relayerFee), yieldIndex);

        s_nullifierHashes[nullifierHash] = true;
        s_collateralSpent[collateralNullifierHash] = true;

        uint256 payout = (DENOMINATION * getCurrentYieldIndex()) / yieldIndex;
        uint256 protocolFee = (payout * s_withdrawalFeeBps) / BPS;
        if (relayerFee > payout - protocolFee) revert Hushfund__FeeTooHigh(relayerFee, payout - protocolFee);

        _pull(payout);
        token.safeTransfer(recipient, payout - protocolFee - relayerFee);
        if (relayerFee > 0) token.safeTransfer(relayer, relayerFee);
        if (protocolFee > 0) token.safeTransfer(s_feeRecipient, protocolFee);

        emit Withdrawal(recipient, nullifierHash, payout - protocolFee - relayerFee, relayer, relayerFee);
    }

    // ------------------------------------------------------------------
    // Borrow
    // ------------------------------------------------------------------

    /// @notice Borrow up to 70% of a note's current value without withdrawing it.
    function borrow(
        bytes calldata proof,
        bytes32 root,
        bytes32 collateralNullifierHash,
        uint256 yieldIndex,
        address recipient,
        uint256 amount,
        address relayer,
        uint256 relayerFee
    ) external nonReentrant whenNotPaused {
        if (s_collateralSpent[collateralNullifierHash]) revert Hushfund__DepositAlreadyWithdrawn(collateralNullifierHash);
        if (s_loans[collateralNullifierHash].active) revert Hushfund__LoanAlreadyActive(collateralNullifierHash);
        if (!isKnownRoot(root)) revert Hushfund__UnknownRoot(root);
        _requireField(collateralNullifierHash);
        _checkYieldIndex(yieldIndex);
        _checkParties(recipient, relayer, relayerFee);
        if (amount == 0) revert Hushfund__ZeroBorrow();
        if (relayerFee > amount) revert Hushfund__FeeTooHigh(relayerFee, amount);

        bytes32[] memory publicInputs = new bytes32[](4);
        publicInputs[0] = root;
        publicInputs[1] = collateralNullifierHash;
        publicInputs[2] = borrowExtDataHash(recipient, relayer, relayerFee, amount);
        publicInputs[3] = bytes32(yieldIndex);
        if (!i_borrowVerifier.verify(proof, publicInputs)) revert Hushfund__InvalidProof();

        uint256 currentIndex = getCurrentYieldIndex();
        uint256 maxBorrow = (((DENOMINATION * currentIndex) / yieldIndex) * LTV_BPS) / BPS;
        if (amount > maxBorrow) revert Hushfund__BorrowAmountExceedsLTV(maxBorrow, amount);

        s_loans[collateralNullifierHash] =
            Loan({principalAmount: amount, borrowYieldIndex: currentIndex, depositYieldIndex: yieldIndex, active: true});
        totalBorrowed += amount;

        _pull(amount);
        token.safeTransfer(recipient, amount - relayerFee);
        if (relayerFee > 0) token.safeTransfer(relayer, relayerFee);

        emit Borrow(collateralNullifierHash, recipient, amount, currentIndex, relayer, relayerFee);
    }

    /// @notice Current debt: principal grown at the vault's own yield rate since the loan was taken.
    function getDebt(bytes32 collateralNullifierHash) public view returns (uint256) {
        Loan memory loan = s_loans[collateralNullifierHash];
        if (!loan.active) return 0;
        uint256 debt = (loan.principalAmount * getCurrentYieldIndex()) / loan.borrowYieldIndex;
        return debt + 1; // round up so rounding never favours the borrower
    }

    // ------------------------------------------------------------------
    // Repay
    // ------------------------------------------------------------------

    /// @notice Repay a loan. The proof (withdraw circuit) shows ownership of the collateral note; the old note is
    ///         retired and a fresh note with the same yield index is inserted, so the later withdrawal cannot be
    ///         linked to the loan. Any amount authorised above the debt is refunded to the payer.
    function repayWithAuthorization(
        bytes calldata proof,
        bytes32 root,
        bytes32 nullifierHash,
        bytes32 collateralNullifierHash,
        uint256 yieldIndex,
        bytes32 newInnerCommitment,
        bytes calldata receiveAuthorization
    ) external nonReentrant {
        Loan storage loan = s_loans[collateralNullifierHash];
        if (!loan.active) revert Hushfund__NoActiveLoan(collateralNullifierHash);
        _checkSpend(root, nullifierHash, collateralNullifierHash, yieldIndex);

        _verifySpend(proof, root, nullifierHash, collateralNullifierHash, repayExtDataHash(newInnerCommitment), yieldIndex);

        uint256 debt = getDebt(collateralNullifierHash);
        address payer = _receive(receiveAuthorization, debt, repayNonce(collateralNullifierHash, newInnerCommitment), false);
        _supply(debt);

        loan.active = false;
        totalBorrowed -= loan.principalAmount;
        s_nullifierHashes[nullifierHash] = true;
        s_collateralSpent[collateralNullifierHash] = true;

        bytes32 renewed = hashLeftRight(newInnerCommitment, bytes32(yieldIndex));
        if (s_commitments[renewed]) revert Hushfund__CommitmentAlreadyAdded(renewed);
        s_commitments[renewed] = true;
        uint32 leafIndex = _insert(renewed);

        emit Commitment(renewed, leafIndex, block.timestamp, yieldIndex);
        emit Repay(collateralNullifierHash, payer, debt, renewed);
    }

    // ------------------------------------------------------------------
    // Admin
    // ------------------------------------------------------------------

    function setWithdrawalFee(uint256 feeBps) external onlyOwner {
        if (feeBps > MAX_FEE_BPS) revert Hushfund__FeeTooHigh(feeBps, MAX_FEE_BPS);
        s_withdrawalFeeBps = feeBps;
        emit FeeUpdated(feeBps);
    }

    function setFeeRecipient(address feeRecipient) external onlyOwner {
        if (feeRecipient == address(0)) revert Hushfund__InvalidFeeRecipient();
        s_feeRecipient = feeRecipient;
        emit FeeRecipientUpdated(feeRecipient);
    }

    /// @notice Stops new deposits and new loans. Withdrawals and repayments keep working.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Starts the time lock for moving all funds to new strategies. Users who disagree can withdraw first.
    function proposeMigration(address newAavePool, address newAToken, address newMorphoVault) external onlyOwner {
        _validateStrategies(newAavePool, newAToken, newMorphoVault);
        uint64 readyAt = uint64(block.timestamp) + MIGRATION_DELAY;
        s_pendingMigration = PendingMigration(newAavePool, newAToken, newMorphoVault, readyAt);
        emit MigrationProposed(newAavePool, newAToken, newMorphoVault, readyAt);
    }

    function cancelMigration() external onlyOwner {
        delete s_pendingMigration;
        emit MigrationCancelled();
    }

    /// @notice Moves every asset from the current strategies into the proposed ones and keeps the yield index
    ///         continuous, so existing notes are paid exactly as before.
    function executeMigration() external onlyOwner nonReentrant {
        PendingMigration memory m = s_pendingMigration;
        if (m.readyAt == 0) revert Hushfund__NoPendingMigration();
        if (block.timestamp < m.readyAt) revert Hushfund__MigrationNotReady(m.readyAt);
        delete s_pendingMigration;

        uint256 aaveIdx = getAaveIndex();
        uint256 morphoIdx = getMorphoIndex();

        // Note: Aave and Morpho can be temporarily illiquid (100% utilisation). Execute when both can pay out in full.
        uint256 morphoBal = morphoVault.maxWithdraw(address(this));
        if (morphoBal > 0) morphoVault.withdraw(morphoBal, address(this), address(this));
        if (aToken.balanceOf(address(this)) > 0) aavePool.withdraw(address(token), type(uint256).max, address(this));

        _setStrategies(m.aavePool, m.aToken, m.morphoVault, aaveIdx, morphoIdx);

        uint256 moved = token.balanceOf(address(this));
        _supply(moved);
        emit StrategiesMigrated(m.aavePool, m.aToken, m.morphoVault, moved);
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _setStrategies(address pool, address aTok, address morpho, uint256 aaveIdx, uint256 morphoIdx) internal {
        _validateStrategies(pool, aTok, morpho);
        aavePool = IAavePool(pool);
        aToken = IERC20(aTok);
        morphoVault = IMorphoVault(morpho);
        s_aaveBaseIndex = aaveIdx;
        s_aaveBaseIncome = IAavePool(pool).getReserveNormalizedIncome(address(token));
        s_morphoBaseIndex = morphoIdx;
        s_morphoBasePrice = IMorphoVault(morpho).convertToAssets(ONE_SHARE);
        if (s_aaveBaseIncome == 0) revert Hushfund__InvalidPoolAddress("Aave", pool);
        if (s_morphoBasePrice == 0) revert Hushfund__InvalidPoolAddress("Morpho", morpho);
    }

    function _validateStrategies(address pool, address aTok, address morpho) internal view {
        if (pool.code.length == 0) revert Hushfund__InvalidPoolAddress("Aave", pool);
        if (aTok.code.length == 0) revert Hushfund__InvalidPoolAddress("aToken", aTok);
        if (morpho.code.length == 0) revert Hushfund__InvalidPoolAddress("Morpho", morpho);
    }

    /// @dev Range checks shared by withdraw and repay.
    function _checkSpend(bytes32 root, bytes32 nullifierHash, bytes32 collateralNullifierHash, uint256 yieldIndex)
        internal
        view
    {
        _requireField(nullifierHash);
        _requireField(collateralNullifierHash);
        _checkYieldIndex(yieldIndex);
        if (s_nullifierHashes[nullifierHash]) revert Hushfund__NoteAlreadySpent(nullifierHash);
        if (!isKnownRoot(root)) revert Hushfund__UnknownRoot(root);
    }

    function _checkParties(address recipient, address relayer, uint256 relayerFee) internal view {
        if (recipient == address(0) || recipient == address(this)) revert Hushfund__InvalidRecipient(recipient);
        if (relayer == address(this) || (relayer == address(0) && relayerFee != 0)) revert Hushfund__InvalidRelayer();
    }

    function _checkYieldIndex(uint256 yieldIndex) internal pure {
        if (yieldIndex == 0 || yieldIndex >= FIELD_SIZE) revert Hushfund__InvalidYieldIndex();
    }

    function _requireField(bytes32 value) internal pure {
        if (uint256(value) >= FIELD_SIZE) revert Hushfund__NotAFieldElement(value);
    }

    function _toField(bytes memory data) internal pure returns (bytes32) {
        return bytes32(uint256(keccak256(data)) % FIELD_SIZE);
    }

    function _verifySpend(
        bytes calldata proof,
        bytes32 root,
        bytes32 nullifierHash,
        bytes32 collateralNullifierHash,
        bytes32 extDataHash,
        uint256 yieldIndex
    ) internal {
        bytes32[] memory publicInputs = new bytes32[](5);
        publicInputs[0] = root;
        publicInputs[1] = nullifierHash;
        publicInputs[2] = collateralNullifierHash;
        publicInputs[3] = extDataHash;
        publicInputs[4] = bytes32(yieldIndex);
        if (!i_verifier.verify(proof, publicInputs)) revert Hushfund__InvalidProof();
    }

    struct Authorization {
        address from;
        address to;
        uint256 value;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// @dev Pulls USDC with receiveWithAuthorization. Deposits must authorise exactly `amount`; repayments may
    ///      authorise more (the debt grows every block) and the excess is refunded to the payer.
    function _receive(bytes calldata auth, uint256 amount, bytes32 expectedNonce, bool exact)
        internal
        returns (address)
    {
        Authorization memory a = abi.decode(auth, (Authorization));
        if (a.to != address(this)) revert Hushfund__InvalidRecipient(a.to);
        if (a.nonce != expectedNonce) revert Hushfund__AuthorizationMismatch();
        if (exact && a.value != amount) revert Hushfund__DepositValueMismatch(amount, a.value);
        if (!exact && a.value < amount) revert Hushfund__InsufficientRepayment(amount, a.value);

        uint256 before = token.balanceOf(address(this));
        IERC3009(address(token)).receiveWithAuthorization(
            a.from, a.to, a.value, a.validAfter, a.validBefore, a.nonce, a.v, a.r, a.s
        );
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != a.value) revert Hushfund__DepositValueMismatch(a.value, received);

        if (a.value > amount) token.safeTransfer(a.from, a.value - amount);
        return a.from;
    }

    /// @dev Splits new funds between the strategies in the ratio of their current indices. This keeps every note's
    ///         holdings exactly proportional to the blended index, so payouts computed from it are fully backed
    ///         (a plain 50/50 split drifts out of balance as the two strategies earn different rates).
    function _supply(uint256 amount) internal {
        if (amount == 0) return;
        uint256 a = getAaveIndex();
        uint256 m = getMorphoIndex();
        uint256 toMorpho = (amount * m) / (a + m);
        uint256 toAave = amount - toMorpho;
        token.forceApprove(address(morphoVault), toMorpho);
        morphoVault.deposit(toMorpho, address(this));
        token.forceApprove(address(aavePool), toAave);
        aavePool.supply(address(token), toAave, address(this), 0);
    }

    /// @dev Withdraws `amount` in the same index ratio used by _supply, falling back to the other strategy when one
    ///      cannot cover its share (rounding dust, temporary illiquidity in Aave or Morpho).
    function _pull(uint256 amount) internal {
        uint256 a = getAaveIndex();
        uint256 m = getMorphoIndex();
        uint256 fromAave = (amount * a) / (a + m);
        uint256 fromMorpho = amount - fromAave;

        uint256 morphoMax = morphoVault.maxWithdraw(address(this));
        uint256 aaveMax = aToken.balanceOf(address(this));
        if (fromMorpho > morphoMax) {
            fromAave += fromMorpho - morphoMax;
            fromMorpho = morphoMax;
        }
        if (fromAave > aaveMax) {
            fromMorpho += fromAave - aaveMax;
            fromAave = aaveMax;
        }
        if (fromMorpho > morphoMax) revert Hushfund__InsufficientLiquidity(amount, morphoMax + aaveMax);

        if (fromMorpho > 0) morphoVault.withdraw(fromMorpho, address(this), address(this));
        if (fromAave > 0) aavePool.withdraw(address(token), fromAave, address(this));
    }
}
