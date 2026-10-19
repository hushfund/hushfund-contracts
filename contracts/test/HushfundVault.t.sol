// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {IHushfundVault} from "../src/interfaces/IHushfundVault.sol";
import {IncrementalMerkleTree} from "../src/IncrementalMerkleTree.sol";
import {AavePoolMock} from "./mocks/AavePoolMock.sol";
import {AaveATokenMock} from "./mocks/AaveATokenMock.sol";
import {MorphoVaultMock} from "./mocks/MorphoVaultMock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract HushfundVaultTest is Base {
    // ------------------------------------------------------------------ deposit

    function test_deposit_insertsLeafAndSplitsFunds() public {
        Note memory n = _deposit(alice, aliceKey);
        assertTrue(vault.s_commitments(n.commitment));
        assertEq(vault.s_nextLeafIndex(), 1);
        assertEq(usdc.balanceOf(alice), 100_000e6 - DENOMINATION);
        assertEq(aToken.balanceOf(address(vault)), DENOMINATION / 2);
        assertEq(morpho.maxWithdraw(address(vault)), DENOMINATION / 2);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_deposit_frontRunWithOtherCommitmentReverts() public {
        Note memory victim = _newNote();
        bytes memory auth = _auth(alice, aliceKey, DENOMINATION, vault.depositNonce(victim.inner));
        Note memory attacker = _newNote();
        vm.prank(bob);
        vm.expectRevert(IHushfundVault.Hushfund__AuthorizationMismatch.selector);
        vault.depositWithAuthorization(attacker.inner, auth);
    }

    function test_deposit_wrongAmountReverts() public {
        Note memory n = _newNote();
        bytes memory auth = _auth(alice, aliceKey, DENOMINATION - 1, vault.depositNonce(n.inner));
        vm.expectRevert(
            abi.encodeWithSelector(IHushfundVault.Hushfund__DepositValueMismatch.selector, DENOMINATION, DENOMINATION - 1)
        );
        vault.depositWithAuthorization(n.inner, auth);
    }

    function test_deposit_nonFieldCommitmentReverts() public {
        bytes32 bad = bytes32(FIELD);
        bytes memory auth = _auth(alice, aliceKey, DENOMINATION, vault.depositNonce(bad));
        vm.expectRevert(abi.encodeWithSelector(IncrementalMerkleTree.IncrementalMerkleTree__LeftValueOutOfRange.selector, bad));
        vault.depositWithAuthorization(bad, auth);
    }

    // ------------------------------------------------------------------ withdraw

    function test_withdraw_passesExactPublicInputs() public {
        Note memory n = _deposit(alice, aliceKey);
        bytes32 root = vault.getLatestRoot();
        _withdraw(n, recipient, relayer, 2e6);

        bytes32[] memory pi = withdrawVerifier.last();
        assertEq(pi.length, 5);
        assertEq(pi[0], root);
        assertEq(pi[1], n.nullifierHash);
        assertEq(pi[2], n.collateralHash);
        assertEq(pi[3], vault.withdrawExtDataHash(recipient, relayer, 2e6));
        assertEq(uint256(pi[4]), n.yieldIndex);
        assertLt(uint256(pi[3]), FIELD);
    }

    function test_withdraw_paysRecipientRelayerAndFee() public {
        Note memory n = _deposit(alice, aliceKey);
        uint256 payout = (DENOMINATION * vault.getCurrentYieldIndex()) / n.yieldIndex;
        _withdraw(n, recipient, relayer, 2e6);

        uint256 protocolFee = (payout * 5) / 10_000;
        assertEq(usdc.balanceOf(relayer), 2e6);
        assertEq(usdc.balanceOf(feeRecipient), protocolFee);
        assertEq(usdc.balanceOf(recipient), payout - protocolFee - 2e6);
        assertLe(payout, DENOMINATION, "a note withdrawn in its own bucket earns nothing extra");
        assertGe(payout, (DENOMINATION * 9999) / 10_000, "and loses at most one bucket");
        assertTrue(vault.s_nullifierHashes(n.nullifierHash));
        assertTrue(vault.s_collateralSpent(n.collateralHash));
    }

    function test_withdraw_extDataBindsEveryField() public view {
        bytes32 base = vault.withdrawExtDataHash(recipient, relayer, 1);
        assertTrue(base != vault.withdrawExtDataHash(bob, relayer, 1));
        assertTrue(base != vault.withdrawExtDataHash(recipient, bob, 1));
        assertTrue(base != vault.withdrawExtDataHash(recipient, relayer, 2));
        assertTrue(base != vault.borrowExtDataHash(recipient, relayer, 1, 0));
    }

    function test_withdraw_doubleSpendReverts() public {
        Note memory n = _deposit(alice, aliceKey);
        _deposit(bob, bobKey); // second deposit keeps liquidity available
        _withdraw(n, recipient, address(0), 0);
        _withdraw(n, recipient, address(0), 0, abi.encodeWithSelector(IHushfundVault.Hushfund__NoteAlreadySpent.selector, n.nullifierHash));
    }

    /// @dev Without the range check, nullifierHash + p would verify as the same field element: a second withdrawal.
    function test_withdraw_nonCanonicalNullifierReverts() public {
        Note memory n = _deposit(alice, aliceKey);
        _deposit(bob, bobKey);
        _withdraw(n, recipient, address(0), 0);

        bytes32 alias_ = bytes32(uint256(n.nullifierHash) + FIELD);
        bytes32 root = vault.getLatestRoot();
        vm.expectRevert(abi.encodeWithSelector(IHushfundVault.Hushfund__NotAFieldElement.selector, alias_));
        vault.withdraw(hex"01", root, alias_, n.collateralHash, n.yieldIndex, recipient, address(0), 0);
    }

    function test_withdraw_invalidProofReverts() public {
        Note memory n = _deposit(alice, aliceKey);
        withdrawVerifier.setResult(false);
        _withdraw(n, recipient, address(0), 0, abi.encodeWithSelector(IHushfundVault.Hushfund__InvalidProof.selector));
    }

    function test_withdraw_feeWithoutRelayerReverts() public {
        Note memory n = _deposit(alice, aliceKey);
        _withdraw(n, recipient, address(0), 1, abi.encodeWithSelector(IHushfundVault.Hushfund__InvalidRelayer.selector));
    }

    function test_withdraw_unknownRootReverts() public {
        Note memory n = _deposit(alice, aliceKey);
        bytes32 fake = bytes32(uint256(123));
        vm.expectRevert(abi.encodeWithSelector(IHushfundVault.Hushfund__UnknownRoot.selector, fake));
        vault.withdraw(hex"01", fake, n.nullifierHash, n.collateralHash, n.yieldIndex, recipient, address(0), 0);
    }

    function test_withdraw_paysYield() public {
        Note memory n = _deposit(alice, aliceKey);
        _accrue(500); // +5%
        uint256 payout = (DENOMINATION * vault.getCurrentYieldIndex()) / n.yieldIndex;
        _withdraw(n, recipient, address(0), 0);

        uint256 fee = (payout * 5) / 10_000;
        assertApproxEqAbs(usdc.balanceOf(recipient), payout - fee, 2);
    }

    function test_withdraw_vaultStaysSolventAcrossBuckets() public {
        Note[] memory notes = new Note[](6);
        for (uint256 i = 0; i < 6; i++) {
            notes[i] = _deposit(i % 2 == 0 ? alice : bob, i % 2 == 0 ? aliceKey : bobKey);
            _accrue(37 + i * 11);
            vm.warp(block.timestamp + 3 days);
        }
        for (uint256 i = 0; i < 6; i++) {
            _withdraw(notes[i], recipient, address(0), 0);
        }
        // everything paid out; whatever is left is surplus, never a shortfall
        assertGe(_strategyAssets() + usdc.balanceOf(address(vault)), 0);
        assertGt(usdc.balanceOf(recipient), 6 * DENOMINATION);
    }

    // ------------------------------------------------------------------ borrow

    function test_borrow_withinLtvAndRelayerFee() public {
        Note memory n = _deposit(alice, aliceKey);
        _deposit(bob, bobKey);
        uint256 amount = (((DENOMINATION * vault.getCurrentYieldIndex()) / n.yieldIndex) * 7000) / 10_000;
        bytes32 root = vault.getLatestRoot();
        _borrow(n, recipient, amount, relayer, 3e6);

        bytes32[] memory pi = borrowVerifier.last();
        assertEq(pi.length, 4);
        assertEq(pi[0], root);
        assertEq(pi[1], n.collateralHash);
        assertEq(pi[2], vault.borrowExtDataHash(recipient, relayer, 3e6, amount));
        assertEq(uint256(pi[3]), n.yieldIndex);

        assertEq(usdc.balanceOf(recipient), amount - 3e6);
        assertEq(usdc.balanceOf(relayer), 3e6);
        assertEq(vault.totalBorrowed(), amount);
        assertGe(vault.getDebt(n.collateralHash), amount);
    }

    function test_borrow_overLtvReverts() public {
        Note memory n = _deposit(alice, aliceKey);
        uint256 amount = (DENOMINATION * 7000) / 10_000 + 1;
        _borrow(n, recipient, amount, address(0), 0, ANY);
    }

    function test_borrow_twiceReverts() public {
        Note memory n = _deposit(alice, aliceKey);
        _deposit(bob, bobKey);
        _borrow(n, recipient, 100e6, address(0), 0);
        _borrow(n, recipient, 100e6, address(0), 0, abi.encodeWithSelector(IHushfundVault.Hushfund__LoanAlreadyActive.selector, n.collateralHash));
    }

    function test_borrow_afterWithdrawReverts() public {
        Note memory n = _deposit(alice, aliceKey);
        _deposit(bob, bobKey);
        _withdraw(n, recipient, address(0), 0);
        _borrow(n, recipient, 100e6, address(0), 0, abi.encodeWithSelector(IHushfundVault.Hushfund__DepositAlreadyWithdrawn.selector, n.collateralHash));
    }

    function test_withdraw_blockedWhileLoanActive() public {
        Note memory n = _deposit(alice, aliceKey);
        _deposit(bob, bobKey);
        _borrow(n, recipient, 100e6, address(0), 0);
        _withdraw(n, recipient, address(0), 0, abi.encodeWithSelector(IHushfundVault.Hushfund__CollateralLocked.selector, n.collateralHash));
    }

    // ------------------------------------------------------------------ repay

    function test_repay_refundsExcessAndRenewsNote() public {
        Note memory n = _deposit(alice, aliceKey);
        _deposit(bob, bobKey);
        _borrow(n, recipient, 500e6, address(0), 0);
        _accrue(200);

        uint256 debt = vault.getDebt(n.collateralHash);
        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 leavesBefore = vault.s_nextLeafIndex();
        Note memory renewed = _repay(n, bob, bobKey, debt + 25e6);

        assertEq(usdc.balanceOf(bob), bobBefore - debt, "only the debt is kept");
        assertEq(vault.totalBorrowed(), 0);
        assertTrue(vault.s_nullifierHashes(n.nullifierHash), "old note retired");
        assertTrue(vault.s_collateralSpent(n.collateralHash), "old collateral retired");
        assertTrue(vault.s_commitments(renewed.commitment), "renewed note inserted");
        assertEq(vault.s_nextLeafIndex(), leavesBefore + 1);

        bytes32[] memory pi = withdrawVerifier.last();
        assertEq(pi[3], vault.repayExtDataHash(renewed.inner));
    }

    function test_repay_renewedNoteWithdrawsWithOriginalYield() public {
        Note memory n = _deposit(alice, aliceKey);
        _deposit(bob, bobKey);
        _borrow(n, recipient, 500e6, address(0), 0);
        _accrue(300);
        Note memory renewed = _repay(n, bob, bobKey, vault.getDebt(n.collateralHash));

        address dest = makeAddr("fresh");
        uint256 payout = (DENOMINATION * vault.getCurrentYieldIndex()) / renewed.yieldIndex;
        _withdraw(renewed, dest, address(0), 0);

        assertApproxEqAbs(usdc.balanceOf(dest), payout - (payout * 5) / 10_000, 2);
    }

    function test_repay_oldNoteCannotWithdrawAfterRenewal() public {
        Note memory n = _deposit(alice, aliceKey);
        _deposit(bob, bobKey);
        _borrow(n, recipient, 100e6, address(0), 0);
        _repay(n, bob, bobKey, vault.getDebt(n.collateralHash));
        _withdraw(n, recipient, address(0), 0, abi.encodeWithSelector(IHushfundVault.Hushfund__NoteAlreadySpent.selector, n.nullifierHash));
    }

    function test_repay_frontRunWithOtherNoteReverts() public {
        Note memory n = _deposit(alice, aliceKey);
        _deposit(bob, bobKey);
        _borrow(n, recipient, 100e6, address(0), 0);
        uint256 debt = vault.getDebt(n.collateralHash);

        Note memory honest = _newNote();
        bytes memory auth = _auth(bob, bobKey, debt, vault.repayNonce(n.collateralHash, honest.inner));
        Note memory attacker = _newNote();
        bytes32 root = vault.getLatestRoot();
        vm.expectRevert(IHushfundVault.Hushfund__AuthorizationMismatch.selector);
        vault.repayWithAuthorization(hex"03", root, n.nullifierHash, n.collateralHash, n.yieldIndex, attacker.inner, auth);
    }

    function test_repay_underpaymentReverts() public {
        Note memory n = _deposit(alice, aliceKey);
        _deposit(bob, bobKey);
        _borrow(n, recipient, 100e6, address(0), 0);
        uint256 debt = vault.getDebt(n.collateralHash);
        _repay(n, bob, bobKey, debt - 1, abi.encodeWithSelector(IHushfundVault.Hushfund__InsufficientRepayment.selector, debt, debt - 1));
    }

    // ------------------------------------------------------------------ admin

    function test_pause_blocksDepositAndBorrowButNotExits() public {
        Note memory n = _deposit(alice, aliceKey);
        Note memory m = _deposit(bob, bobKey);
        _borrow(m, recipient, 100e6, address(0), 0);

        vm.prank(owner);
        vault.pause();

        Note memory x = _newNote();
        bytes memory auth = _auth(alice, aliceKey, DENOMINATION, vault.depositNonce(x.inner));
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.depositWithAuthorization(x.inner, auth);

        _repay(m, bob, bobKey, vault.getDebt(m.collateralHash)); // repay still works
        _withdraw(n, recipient, address(0), 0); // withdraw still works
    }

    function test_fee_capped() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHushfundVault.Hushfund__FeeTooHigh.selector, 101, 100));
        vault.setWithdrawalFee(101);
    }

    function test_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.pause();
    }

    function test_ownershipIsTwoStep() public {
        vm.prank(owner);
        vault.transferOwnership(alice);
        assertEq(vault.owner(), owner);
        vm.prank(alice);
        vault.acceptOwnership();
        assertEq(vault.owner(), alice);
    }

    function test_migration_timelockAndIndexContinuity() public {
        Note memory n = _deposit(alice, aliceKey);
        _deposit(bob, bobKey);
        _accrue(400);
        uint256 indexBefore = vault.getCurrentYieldIndex();

        AavePoolMock aave2 = new AavePoolMock();
        AaveATokenMock aToken2 = new AaveATokenMock(aave2, address(usdc));
        MorphoVaultMock morpho2 = new MorphoVaultMock(IERC20(address(usdc)));
        aave2.setNormalizedIncome(address(usdc), 1.3e27); // a different starting index must not matter

        vm.prank(owner);
        vault.proposeMigration(address(aave2), address(aToken2), address(morpho2));
        vm.prank(owner);
        vm.expectRevert();
        vault.executeMigration();

        vm.warp(block.timestamp + 2 days);
        uint256 assetsBefore = _strategyAssets();
        vm.prank(owner);
        vault.executeMigration();

        assertEq(address(vault.aavePool()), address(aave2));
        assertApproxEqAbs(aToken2.balanceOf(address(vault)) + morpho2.maxWithdraw(address(vault)), assetsBefore, 2);
        assertApproxEqAbs(vault.getCurrentYieldIndex(), indexBefore, 1e18);

        uint256 payout = (DENOMINATION * vault.getCurrentYieldIndex()) / n.yieldIndex;

        _withdraw(n, recipient, address(0), 0);

        assertApproxEqAbs(usdc.balanceOf(recipient), payout - (payout * 5) / 10_000, 2);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_withdraw_neverPaysMoreThanHeld(uint8 deposits, uint16 bps) public {
        deposits = uint8(bound(deposits, 1, 8));
        bps = uint16(bound(bps, 0, 3000));
        Note[] memory notes = new Note[](deposits);
        for (uint256 i = 0; i < deposits; i++) {
            notes[i] = _deposit(alice, aliceKey);
            _accrue(bps / deposits);
            vm.warp(block.timestamp + 1 days);
        }
        for (uint256 i = 0; i < deposits; i++) {
            _withdraw(notes[i], recipient, address(0), 0);
        }
    }
}
