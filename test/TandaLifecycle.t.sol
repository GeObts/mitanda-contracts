// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {MitandaTestBase} from "./helpers/MitandaTestBase.sol";
import {Tanda} from "../src/Tanda.sol";
import {WrongTandaState} from "../src/MitandaErrors.sol";

/// @title  TandaLifecycleTest
/// @notice End-to-end happy-path test for a 3-participant tanda.
///         Walks CREATE → OPEN → ACTIVE → COMPLETED with assertions
///         on state, balances, fees, insurance, and NFT mints at every
///         step. Phases are split into helpers to keep stack pressure
///         low (the contract is heavily-named-locals-rich and would
///         otherwise hit Solidity's stack-too-deep limit).
///
///         Hand-verified math (100 USDC contribution × 10% insurance):
///         - per-cycle pot            = 100 × 3 = 300 USDC
///         - platform fee (2%)        = 6 USDC
///         - organizer fee (3%)       = 9 USDC
///         - recipient share (95%)    = 285 USDC
///         - per participant charge   = 110 USDC per cycle
///         - per participant insurance total = 3 × 10 = 30 USDC
///         - no defaulters → slashedPool = 0
contract TandaLifecycleTest is MitandaTestBase {
    // ─── Convenience constants (6-decimal USDC) ────────────────────────
    uint256 internal constant USDC = 10 ** 6;
    uint256 internal constant CONTRIBUTION = 100 * USDC;
    uint256 internal constant PREMIUM_PER_CYCLE = 10 * USDC;
    uint256 internal constant CHARGE_PER_CYCLE = 110 * USDC;
    uint256 internal constant CYCLE_POT = 300 * USDC;
    uint256 internal constant CYCLE_PLATFORM = 6 * USDC;
    uint256 internal constant CYCLE_ORGANIZER = 9 * USDC;
    uint256 internal constant CYCLE_RECIPIENT = 285 * USDC;
    uint256 internal constant INSURANCE_PER_PARTICIPANT = 30 * USDC;

    // ─── Running expected credits (storage, not stack) ─────────────────
    uint256 internal expAlice;
    uint256 internal expBob;
    uint256 internal expCarol;
    uint256 internal expTreasury;

    // ─── tandaId remembered across helpers ─────────────────────────────
    uint256 internal currentTandaId;

    // ─── Captured recipients per cycle ─────────────────────────────────
    address internal r1;
    address internal r2;
    address internal r3;

    // ────────────────────────────────────────────────────────────────
    // Low-level helpers
    // ────────────────────────────────────────────────────────────────

    function _makePayment(address tandaAddr, address user, uint256 cycles) internal {
        uint256 charge = cycles * CHARGE_PER_CYCLE;
        _fundAndApprove(user, charge, tandaAddr);
        vm.prank(user);
        Tanda(tandaAddr).makePayment(cycles);
    }

    function _bumpRecipient(address recipient, uint256 amount) internal {
        if (recipient == alice) expAlice += amount;
        else if (recipient == bob) expBob += amount;
        else if (recipient == carol) expCarol += amount;
        else revert("unknown recipient");
    }

    function _assertCredits(Tanda t) internal {
        assertEq(t.pendingWithdrawals(alice), expAlice, "alice credit");
        assertEq(t.pendingWithdrawals(bob), expBob, "bob credit");
        assertEq(t.pendingWithdrawals(carol), expCarol, "carol credit");
        assertEq(t.pendingWithdrawals(TREASURY), expTreasury, "treasury credit");
    }

    // ────────────────────────────────────────────────────────────────
    // Phase helpers
    // ────────────────────────────────────────────────────────────────

    function _assertJustCreated(Tanda t) internal {
        assertEq(uint8(t.state()), uint8(Tanda.TandaState.OPEN), "state after create");
        assertEq(t.participantCount(), 3, "participantCount");
        assertEq(t.contributionAmount(), CONTRIBUTION, "contributionAmount");
        assertEq(t.payoutInterval(), DEFAULT_PAYOUT_INTERVAL, "payoutInterval");
        assertEq(t.gracePeriod(), DEFAULT_GRACE_PERIOD, "gracePeriod");
        assertEq(t.creator(), alice, "creator");
        assertEq(t.sponsoredCollectionId(), 1, "sponsoredCollectionId");
        // Charge-at-create: the creator is auto-enrolled as participant #1.
        assertEq(t.activeParticipantCount(), 1, "activeParticipantCount after create");
        assertTrue(t.isParticipant(alice), "creator enrolled at create");
    }

    function _fillAndCaptureRecipients(address tandaAddr) internal {
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = carol;
        _fillAndStart(tandaAddr, users, uint256(keccak256("seed_lifecycle")));

        uint256[] memory order = Tanda(tandaAddr).getPayoutOrder();
        address[3] memory pArr = [alice, bob, carol];
        r1 = pArr[order[0]];
        r2 = pArr[order[1]];
        r3 = pArr[order[2]];
        assertTrue(r1 != r2 && r2 != r3 && r1 != r3, "payout recipients must be distinct");
        emit log_named_address("cycle 1 recipient", r1);
        emit log_named_address("cycle 2 recipient", r2);
        emit log_named_address("cycle 3 recipient", r3);
    }

    function _assertJustFilled(address tandaAddr) internal {
        Tanda t = Tanda(tandaAddr);
        uint256 tandaId = currentTandaId;

        assertEq(uint8(t.state()), uint8(Tanda.TandaState.ACTIVE), "state after fill");
        assertTrue(t.payoutOrderAssigned(), "payoutOrderAssigned");
        assertEq(t.activeParticipantCount(), 3, "activeParticipantCount after fill");
        assertEq(t.currentCycle(), 1, "currentCycle after fill");

        // Pass NFTs
        assertTrue(passNFT.hasPass(alice, tandaId), "alice pass");
        assertTrue(passNFT.hasPass(bob, tandaId), "bob pass");
        assertTrue(passNFT.hasPass(carol, tandaId), "carol pass");
        assertEq(passNFT.balanceOf(alice), 1, "alice pass balanceOf");
        assertEq(passNFT.balanceOf(bob), 1, "bob pass balanceOf");
        assertEq(passNFT.balanceOf(carol), 1, "carol pass balanceOf");

        // paidUntilCycle + insurance
        assertEq(t.getParticipant(0).paidUntilCycle, 1, "alice paidUntilCycle after join");
        assertEq(t.getParticipant(1).paidUntilCycle, 1, "bob paidUntilCycle after join");
        assertEq(t.getParticipant(2).paidUntilCycle, 1, "carol paidUntilCycle after join");
        assertEq(t.insuranceBalance(alice), PREMIUM_PER_CYCLE, "alice insurance after join");
        assertEq(t.insuranceBalance(bob), PREMIUM_PER_CYCLE, "bob insurance after join");
        assertEq(t.insuranceBalance(carol), PREMIUM_PER_CYCLE, "carol insurance after join");

        // Contract balance after 3 joins
        assertEq(usdc.balanceOf(tandaAddr), 3 * CHARGE_PER_CYCLE, "balance after fill");
        _assertSnapshotAfterFill(t);
    }

    function _assertSnapshotAfterFill(Tanda t) internal {
        (
            uint256 snapBalance,
            uint256 snapOutstanding,
            uint256 snapPendingCredits,
            uint256 snapSlashPool,
            uint256 snapInsuranceReserve
        ) = t.getAccountingSnapshot();
        assertEq(snapBalance, 3 * CHARGE_PER_CYCLE, "snap balance after fill");
        assertEq(snapPendingCredits, 0, "snap pendingCredits after fill");
        assertEq(snapSlashPool, 0, "snap slashPool after fill");
        assertEq(snapInsuranceReserve, 3 * PREMIUM_PER_CYCLE, "snap insurance after fill");
        assertEq(snapOutstanding, 3 * PREMIUM_PER_CYCLE, "snap outstanding after fill");
        assertEq(snapBalance - snapOutstanding, CYCLE_POT, "residual after fill");
    }

    /// @dev Per-cycle: optional makePayments, warp, trigger, assert.
    ///      `cycleIndex` is the cycle number being settled (1, 2, 3).
    ///      `needsPayments` is false only for cycle 1 (covered by join).
    function _runCycle(address tandaAddr, uint256 cycleIndex, address recipient, bool needsPayments) internal {
        Tanda t = Tanda(tandaAddr);

        if (needsPayments) {
            _makePayment(tandaAddr, alice, 1);
            _makePayment(tandaAddr, bob, 1);
            _makePayment(tandaAddr, carol, 1);

            assertEq(t.getParticipant(0).paidUntilCycle, cycleIndex, "alice paidUntilCycle pre-cycle");
            assertEq(t.getParticipant(1).paidUntilCycle, cycleIndex, "bob paidUntilCycle pre-cycle");
            assertEq(t.getParticipant(2).paidUntilCycle, cycleIndex, "carol paidUntilCycle pre-cycle");
            assertEq(t.insuranceBalance(alice), cycleIndex * PREMIUM_PER_CYCLE, "alice insurance pre-cycle");
            assertEq(t.insuranceBalance(bob), cycleIndex * PREMIUM_PER_CYCLE, "bob insurance pre-cycle");
            assertEq(t.insuranceBalance(carol), cycleIndex * PREMIUM_PER_CYCLE, "carol insurance pre-cycle");
            // Total contract balance = (cycleIndex × 3 × 110).
            assertEq(usdc.balanceOf(tandaAddr), cycleIndex * 3 * CHARGE_PER_CYCLE, "balance pre-trigger");
        }

        _warpToNextCycle(tandaAddr);
        t.triggerPayout();

        // Credit accumulation
        _bumpRecipient(recipient, CYCLE_RECIPIENT);
        expAlice += CYCLE_ORGANIZER; // alice is creator → organizer fee every cycle
        expTreasury += CYCLE_PLATFORM;

        // For non-final cycles: assert state + credits in-place.
        // For the final cycle: defer credit assertion to caller, because
        // `triggerPayout` here also runs `_completeTanda` which credits
        // insurance refunds — the caller adds those to expectations and
        // then asserts.
        if (cycleIndex < 3) {
            assertEq(t.currentCycle(), cycleIndex + 1, "currentCycle after cycle");
            assertEq(uint8(t.state()), uint8(Tanda.TandaState.ACTIVE), "state after cycle");
            _assertCredits(t);
        }
    }

    function _assertCompletion(address tandaAddr) internal {
        Tanda t = Tanda(tandaAddr);
        uint256 tandaId = currentTandaId;

        assertEq(uint8(t.state()), uint8(Tanda.TandaState.COMPLETED), "state after cycle 3");
        assertEq(t.currentCycle(), 4, "currentCycle after cycle 3");
        assertEq(t.slashedPool(), 0, "slashedPool at completion");
        assertEq(t.totalInsuranceReserve(), 0, "totalInsuranceReserve after refunds");
        assertEq(t.insuranceBalance(alice), 0, "alice insurance after refund");
        assertEq(t.insuranceBalance(bob), 0, "bob insurance after refund");
        assertEq(t.insuranceBalance(carol), 0, "carol insurance after refund");

        // Completion NFTs
        assertTrue(completionNFT.hasCompletion(alice, tandaId), "alice completion");
        assertTrue(completionNFT.hasCompletion(bob, tandaId), "bob completion");
        assertTrue(completionNFT.hasCompletion(carol, tandaId), "carol completion");
        assertEq(completionNFT.reputationScore(alice), 1, "alice reputation");
        assertEq(completionNFT.reputationScore(bob), 1, "bob reputation");
        assertEq(completionNFT.reputationScore(carol), 1, "carol reputation");

        // Receipt NFTs: 3 total across r1, r2, r3 (some may overlap if recipient repeats — they don't here)
        uint256 receiptCount = receiptNFT.balanceOf(alice) + receiptNFT.balanceOf(bob) + receiptNFT.balanceOf(carol);
        assertEq(receiptCount, 3, "total receipts minted");

        // Contract balance equals sum of unclaimed credits
        assertEq(usdc.balanceOf(tandaAddr), expAlice + expBob + expCarol + expTreasury, "balance pre-withdraw");
    }

    function _withdrawAllAndAssert(address tandaAddr) internal {
        Tanda t = Tanda(tandaAddr);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 carolBefore = usdc.balanceOf(carol);
        uint256 treasuryBefore = usdc.balanceOf(TREASURY);

        vm.prank(alice);
        t.withdraw();
        vm.prank(bob);
        t.withdraw();
        vm.prank(carol);
        t.withdraw();
        vm.prank(TREASURY);
        t.withdraw();

        assertEq(usdc.balanceOf(alice) - aliceBefore, expAlice, "alice withdraw amount");
        assertEq(usdc.balanceOf(bob) - bobBefore, expBob, "bob withdraw amount");
        assertEq(usdc.balanceOf(carol) - carolBefore, expCarol, "carol withdraw amount");
        assertEq(usdc.balanceOf(TREASURY) - treasuryBefore, expTreasury, "treasury withdraw amount");

        assertEq(t.pendingWithdrawals(alice), 0, "alice pending after withdraw");
        assertEq(t.pendingWithdrawals(bob), 0, "bob pending after withdraw");
        assertEq(t.pendingWithdrawals(carol), 0, "carol pending after withdraw");
        assertEq(t.pendingWithdrawals(TREASURY), 0, "treasury pending after withdraw");

        assertEq(usdc.balanceOf(tandaAddr), 0, "contract drained");
        assertEq(t.totalPendingCredits(), 0, "totalPendingCredits final");

        (uint256 snapBalance, uint256 snapOutstanding,,,) = t.getAccountingSnapshot();
        assertEq(snapBalance, 0, "snap balance final");
        assertEq(snapOutstanding, 0, "snap outstanding final");
    }

    // ────────────────────────────────────────────────────────────────
    // Main test
    // ────────────────────────────────────────────────────────────────

    function test_fullLifecycle_threeParticipants() public {
        // a. Create
        (address tandaAddr, uint256 tandaId) = _createDefaultTanda(alice);
        currentTandaId = tandaId;
        _assertJustCreated(Tanda(tandaAddr));

        // b. Fill + capture order
        _fillAndCaptureRecipients(tandaAddr);
        _assertJustFilled(tandaAddr);

        // d. Cycle 1 (no makePayment — covered by join)
        _runCycle(tandaAddr, 1, r1, false);
        assertEq(receiptNFT.balanceOf(r1), 1, "r1 receipt after cycle 1");

        // f. Cycle 2
        _runCycle(tandaAddr, 2, r2, true);

        // h. Cycle 3 (completes tanda)
        _runCycle(tandaAddr, 3, r3, true);

        // Insurance refunds added at completion
        expAlice += INSURANCE_PER_PARTICIPANT;
        expBob += INSURANCE_PER_PARTICIPANT;
        expCarol += INSURANCE_PER_PARTICIPANT;
        _assertCredits(Tanda(tandaAddr));

        // Verify completion-level invariants
        _assertCompletion(tandaAddr);

        // i. Withdrawals
        _withdrawAllAndAssert(tandaAddr);
    }

    // ────────────────────────────────────────────────────────────────
    // State transitions
    // ────────────────────────────────────────────────────────────────

    function test_lifecycle_stateTransitions() public {
        (address tandaAddr,) = _createDefaultTanda(alice);
        Tanda t = Tanda(tandaAddr);

        // OPEN: triggerPayout reverts WrongTandaState(ACTIVE, OPEN)
        vm.expectRevert(
            abi.encodeWithSelector(
                WrongTandaState.selector, uint8(Tanda.TandaState.ACTIVE), uint8(Tanda.TandaState.OPEN)
            )
        );
        t.triggerPayout();

        // Fill to ACTIVE
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = carol;
        _fillAndStart(tandaAddr, users, uint256(keccak256("seed_state")));
        assertEq(uint8(t.state()), uint8(Tanda.TandaState.ACTIVE), "state after fill");

        // ACTIVE: dave's join reverts WrongTandaState(OPEN, ACTIVE)
        vm.expectRevert(
            abi.encodeWithSelector(
                WrongTandaState.selector, uint8(Tanda.TandaState.OPEN), uint8(Tanda.TandaState.ACTIVE)
            )
        );
        vm.prank(dave);
        t.join();

        // Run to COMPLETED
        _runRemainingCyclesToCompletion(tandaAddr);
        assertEq(uint8(t.state()), uint8(Tanda.TandaState.COMPLETED), "state after run");

        // COMPLETED: triggerPayout reverts WrongTandaState(ACTIVE, COMPLETED)
        vm.expectRevert(
            abi.encodeWithSelector(
                WrongTandaState.selector, uint8(Tanda.TandaState.ACTIVE), uint8(Tanda.TandaState.COMPLETED)
            )
        );
        t.triggerPayout();
    }

    function _runRemainingCyclesToCompletion(address tandaAddr) internal {
        Tanda t = Tanda(tandaAddr);

        // Cycle 1: no makePayment needed
        _warpToNextCycle(tandaAddr);
        t.triggerPayout();

        // Cycles 2..N until COMPLETED
        while (uint8(t.state()) == uint8(Tanda.TandaState.ACTIVE)) {
            _makePayment(tandaAddr, alice, 1);
            _makePayment(tandaAddr, bob, 1);
            _makePayment(tandaAddr, carol, 1);
            _warpToNextCycle(tandaAddr);
            t.triggerPayout();
        }
    }
}
