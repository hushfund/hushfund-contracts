// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IHushfundVault {
    // ---- Structs ----
    struct Loan {
        uint256 principalAmount;
        uint256 borrowYieldIndex;
        uint256 depositYieldIndex;
        bool active;
    }

    struct PendingMigration {
        address aavePool;
        address aToken;
        address morphoVault;
        uint64 readyAt;
    }

    // ---- Events ----
    /// @notice Emitted for every leaf added to the Merkle tree: deposits and notes renewed on repay.
    event Commitment(bytes32 indexed commitment, uint32 leafIndex, uint256 timestamp, uint256 yieldIndex);
    event Deposit(bytes32 indexed commitment, address indexed depositor);
    event Withdrawal(address indexed to, bytes32 nullifierHash, uint256 payout, address relayer, uint256 relayerFee);
    event Borrow(bytes32 indexed collateralNullifierHash, address indexed recipient, uint256 amount, uint256 yieldIndex, address relayer, uint256 relayerFee);
    event Repay(bytes32 indexed collateralNullifierHash, address indexed payer, uint256 amount, bytes32 renewedCommitment);
    event FeeUpdated(uint256 newFeeBps);
    event FeeRecipientUpdated(address newFeeRecipient);
    event MigrationProposed(address aavePool, address aToken, address morphoVault, uint64 readyAt);
    event MigrationCancelled();
    event StrategiesMigrated(address aavePool, address aToken, address morphoVault, uint256 movedAssets);

    // ---- Errors ----
    error Hushfund__DepositValueMismatch(uint256 expected, uint256 actual);
    error Hushfund__InvalidRecipient(address recipient);
    error Hushfund__InvalidRelayer();
    error Hushfund__AuthorizationMismatch();
    error Hushfund__NoteAlreadySpent(bytes32 nullifierHash);
    error Hushfund__UnknownRoot(bytes32 root);
    error Hushfund__InvalidProof();
    error Hushfund__CommitmentAlreadyAdded(bytes32 commitment);
    error Hushfund__InvalidYieldIndex();
    error Hushfund__NotAFieldElement(bytes32 value);
    error Hushfund__InvalidPoolAddress(string protocol, address provided);
    error Hushfund__LoanAlreadyActive(bytes32 collateralNullifierHash);
    error Hushfund__NoActiveLoan(bytes32 collateralNullifierHash);
    error Hushfund__CollateralLocked(bytes32 collateralNullifierHash);
    error Hushfund__BorrowAmountExceedsLTV(uint256 maxBorrow, uint256 requested);
    error Hushfund__ZeroBorrow();
    error Hushfund__DepositAlreadyWithdrawn(bytes32 collateralNullifierHash);
    error Hushfund__FeeTooHigh(uint256 fee, uint256 max);
    error Hushfund__InvalidFeeRecipient();
    error Hushfund__InsufficientRepayment(uint256 debt, uint256 provided);
    error Hushfund__NoPendingMigration();
    error Hushfund__MigrationNotReady(uint64 readyAt);
    error Hushfund__InsufficientLiquidity(uint256 requested, uint256 available);

    // ---- Views ----
    function token() external view returns (IERC20);
    function DENOMINATION() external view returns (uint256);
    function totalBorrowed() external view returns (uint256);
    function s_nullifierHashes(bytes32) external view returns (bool);
    function s_commitments(bytes32) external view returns (bool);
    function s_collateralSpent(bytes32) external view returns (bool);
    function s_withdrawalFeeBps() external view returns (uint256);
    function s_feeRecipient() external view returns (address);
    function getCurrentBucketedYieldIndex() external view returns (uint256);
    function getCurrentYieldIndex() external view returns (uint256);
    function getDebt(bytes32 collateralNullifierHash) external view returns (uint256);
    function depositNonce(bytes32 innerCommitment) external view returns (bytes32);
    function repayNonce(bytes32 collateralNullifierHash, bytes32 newInnerCommitment) external view returns (bytes32);
    function withdrawExtDataHash(address recipient, address relayer, uint256 relayerFee) external view returns (bytes32);
    function borrowExtDataHash(address recipient, address relayer, uint256 relayerFee, uint256 amount) external view returns (bytes32);
    function repayExtDataHash(bytes32 newInnerCommitment) external view returns (bytes32);

    // ---- Actions ----
    function depositWithAuthorization(bytes32 innerCommitment, bytes calldata receiveAuthorization) external;

    function withdraw(
        bytes calldata proof,
        bytes32 root,
        bytes32 nullifierHash,
        bytes32 collateralNullifierHash,
        uint256 yieldIndex,
        address recipient,
        address relayer,
        uint256 relayerFee
    ) external;

    function borrow(
        bytes calldata proof,
        bytes32 root,
        bytes32 collateralNullifierHash,
        uint256 yieldIndex,
        address recipient,
        uint256 amount,
        address relayer,
        uint256 relayerFee
    ) external;

    function repayWithAuthorization(
        bytes calldata proof,
        bytes32 root,
        bytes32 nullifierHash,
        bytes32 collateralNullifierHash,
        uint256 yieldIndex,
        bytes32 newInnerCommitment,
        bytes calldata receiveAuthorization
    ) external;
}
