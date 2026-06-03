// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {MitandaTestBase} from "./helpers/MitandaTestBase.sol";
import {Tanda} from "../src/Tanda.sol";
import {ITanda} from "../src/interfaces/ITanda.sol";
import {
    WrongTandaState,
    NotDefaulter,
    NotParticipant,
    AlreadyMarkedDefaulter,
    GracePeriodNotExpired
} from "../src/MitandaErrors.sol";

/// @title  TandaDefaulterTest
/// @notice Defaulter scenarios and slash pool distribution.
///         Hand-verified math (100 USDC contribution × 10% premium):
///
///         5-participant tanda — cycle 1 pot 500, splits 475/10/15.
///         After 1 future-slot defaulter (active=4): cycles 2+ pot 400,
///         splits 380/8/12.
///
///         4-participant tanda (used in slash dust test) — cycle 1 pot
///         400, splits 380/8/12. After 1 future-slot defaulter
///         (active=3): cycles 2+ pot 300, splits 285/6/9.
///
///         Slash pool from 1-cycle defaulter = 10 USDC = 10_000_000
///         base units. 95% = 9_500_000.
///         - With 4 active: perActive = 2_375_000, dust = 0
///         - With 3 active: perActive = 3_166_666, dust = 2
contract TandaDefaulterTest is MitandaTestBase {
    // ─── Convenience constants (6-decimal USDC) ────────────────────────
    uint256 internal constant USDC = 10 ** 6;
    uint256 internal constant CONTRIBUTION = 100 * USDC;
    uint256 internal constant PREMIUM_PER_CYCLE = 10 * USDC;
    uint256 internal constant CHARGE_PER_CYCLE = 110 * USDC;

    // ─── Per-test storage (avoid stack pressure) ───────────────────────
    address internal target;
    uint256 internal targetParticipantIdx;
    uint256 internal targetPositionInOrder;

    // ────────────────────────────────────────────────────────────────
    // Tanda factories
    // ────────────────────────────────────────────────────────────────

    function _create5(address creator) internal returns (address tandaAddr, uint256 tandaId) {
        _enableCreate(creator, CONTRIBUTION);
        vm.prank(creator);
        tandaId = manager.createTanda(
            address(usdc), CONTRIBUTION, DEFAULT_PAYOUT_INTERVAL, 5, DEFAULT_GRACE_PERIOD, 0, ITanda.TandaPrivacy.PUBLIC
        );
        tandaAddr = manager.tandaIdToAddress(tandaId);
    }

    function _create4(address creator) internal returns (address tandaAddr, uint256 tandaId) {
        _enableCreate(creator, CONTRIBUTION);
        vm.prank(creator);
        tandaId = manager.createTanda(
            address(usdc), CONTRIBUTION, DEFAULT_PAYOUT_INTERVAL, 4, DEFAULT_GRACE_PERIOD, 0, ITanda.TandaPrivacy.PUBLIC
        );
        tandaAddr = manager.tandaIdToAddress(tandaId);
    }

    function _fill5(address tandaAddr, uint256 seed) internal {
        address[] memory users = new address[](5);
        users[0] = alice;
        users[1] = bob;
        users[2] = carol;
        users[3] = dave;
        users[4] = eve;
        _fillAndStart(tandaAddr, users, seed);
    }

    function _fill4(address tandaAddr, uint256 seed) internal {
        address[] memory users = new address[](4);
        users[0] = alice;
        users[1] = bob;
        users[2] = carol;
        users[3] = dave;
        _fillAndStart(tandaAddr, users, seed);
    }

    function _makePayment(address tandaAddr, address user, uint256 cycles) internal {
        uint256 charge = cycles * CHARGE_PER_CYCLE;
        _fundAndApprove(user, charge, tandaAddr);
        vm.prank(user);
        Tanda(tandaAddr).makePayment(cycles);
    }

    function _warpPastGrace(address tandaAddr) internal {
        Tanda t = Tanda(tandaAddr);
        uint256 expires = t.startTimestamp() + t.currentCycle() * t.payoutInterval() + t.gracePeriod();
        vm.warp(expires + 1);
    }

    // ────────────────────────────────────────────────────────────────
    // Scenario 1: future-slot defaulter
    // ────────────────────────────────────────────────────────────────

    function test_defaulter_futureSlot_prunedAndShortens() public {
        (address tandaAddr, uint256 tandaId) = _create5(alice);
        Tanda t = Tanda(tandaAddr);
        _fill5(tandaAddr, uint256(keccak256("seed_futslot")));

        // Find target: latest non-alice future-slot participant.
        uint256[] memory order = t.getPayoutOrder();
        address[5] memory pArr = [alice, bob, carol, dave, eve];
        for (uint256 i = 5; i > 1; i--) {
            address candidate = pArr[order[i - 1]];
            if (candidate != alice) {
                target = candidate;
                targetParticipantIdx = order[i - 1];
                targetPositionInOrder = i - 1;
                break;
            }
        }
        require(target != address(0), "no non-alice future slot");
        emit log_named_address("target", target);

        assertEq(t.activeParticipantCount(), 5, "initial active");
        assertEq(t.getPayoutOrder().length, 5, "initial payoutOrder.length");
        assertEq(t.insuranceBalance(target), PREMIUM_PER_CYCLE, "target insurance before");

        // Cycle 1 — everyone paid via join.
        _warpToNextCycle(tandaAddr);
        t.triggerPayout();
        assertEq(t.currentCycle(), 2, "currentCycle after cycle 1");

        // Cycle 2 prep — all except target pay.
        for (uint256 i = 0; i < 5; i++) {
            if (pArr[i] != target) _makePayment(tandaAddr, pArr[i], 1);
        }

        // Warp past grace. Permissionless mark by a random caller.
        _warpPastGrace(tandaAddr);
        vm.prank(address(0xCAFEBEEF));
        t.markDefaulter(target);

        // Post-mark assertions
        assertFalse(t.getParticipant(targetParticipantIdx).isActive, "target inactive");
        assertEq(t.activeParticipantCount(), 4, "active count after mark");
        assertEq(t.insuranceBalance(target), 0, "target insurance forfeited");
        assertEq(t.slashedPool(), PREMIUM_PER_CYCLE, "slash pool gained");
        assertEq(t.getPayoutOrder().length, 4, "payout order shrunk");

        // Pass NFT defaulted flag
        {
            uint256 passId = passNFT.getPassId(target, tandaId);
            (,,, bool defaulted) = passNFT.getPassInfo(passId);
            assertTrue(defaulted, "pass NFT defaulted flag");
        }

        // Continue: cycle 2 trigger (all active paid).
        t.triggerPayout();
        assertEq(t.currentCycle(), 3, "currentCycle after cycle 2");

        // Cycles 3, 4 — actives pay then trigger.
        _runActiveCyclesToCompletion(tandaAddr, pArr);

        // Completion
        assertEq(uint8(t.state()), uint8(Tanda.TandaState.COMPLETED), "completed");

        // Verify credits
        _assertScenario1Credits(t, order, pArr, tandaId);
    }

    function _runActiveCyclesToCompletion(address tandaAddr, address[5] memory pArr) internal {
        Tanda t = Tanda(tandaAddr);
        while (uint8(t.state()) == uint8(Tanda.TandaState.ACTIVE)) {
            for (uint256 i = 0; i < 5; i++) {
                if (pArr[i] != target) _makePayment(tandaAddr, pArr[i], 1);
            }
            _warpToNextCycle(tandaAddr);
            t.triggerPayout();
        }
    }

    function _assertScenario1Credits(Tanda t, uint256[] memory order, address[5] memory pArr, uint256 tandaId)
        internal
    {
        // Target gets nothing — no pending, no completion NFT.
        assertEq(t.pendingWithdrawals(target), 0, "target zero pending");
        assertFalse(completionNFT.hasCompletion(target, tandaId), "target no completion");

        // 4 active each get insurance refund (40) + slash share (2.375).
        uint256 perActiveBaseRefund = 40 * USDC + 2_375_000; // 40 USDC + 2.375 USDC

        // Treasury: 34 cycle platforms (10+8+8+8) + 200_000 slash + 0 dust
        assertEq(t.pendingWithdrawals(TREASURY), 34 * USDC + 200_000, "treasury");

        // For each non-target participant, compute expected credits.
        for (uint256 i = 0; i < 5; i++) {
            address p = pArr[i];
            if (p == target) continue;

            uint256 expected = perActiveBaseRefund;

            // Recipient share based on position in payoutOrder.
            // Position 0 → cycle 1 (pot 500) → 475
            // Other positions → cycles 2-4 (pot 400) → 380
            for (uint256 j = 0; j < 5; j++) {
                if (pArr[order[j]] == p) {
                    expected += (j == 0) ? 475 * USDC : 380 * USDC;
                    break;
                }
            }

            // Alice is creator → +51 USDC organizer fees + 300_000 slash org share
            if (p == alice) {
                expected += 51 * USDC + 300_000;
            }

            assertEq(t.pendingWithdrawals(p), expected, "non-target credit");
            assertTrue(completionNFT.hasCompletion(p, tandaId), "non-target completion");
        }
    }

    // ────────────────────────────────────────────────────────────────
    // Scenario 2: past-slot defaulter
    // ────────────────────────────────────────────────────────────────

    function test_defaulter_pastSlot_keptInOrder() public {
        (address tandaAddr, uint256 tandaId) = _create5(alice);
        Tanda t = Tanda(tandaAddr);
        _fill5(tandaAddr, uint256(keccak256("seed_pastslot")));

        // Target = cycle 1 recipient (position 0). Skip if it's alice.
        uint256[] memory order = t.getPayoutOrder();
        address[5] memory pArr = [alice, bob, carol, dave, eve];
        target = pArr[order[0]];
        targetParticipantIdx = order[0];
        targetPositionInOrder = 0;

        require(target != alice, "test setup: target must not be alice (re-seed)");
        emit log_named_address("target (cycle-1 recipient who later defaults)", target);

        // Cycle 1 — trigger. Target receives the cycle 1 pot.
        _warpToNextCycle(tandaAddr);
        t.triggerPayout();
        assertEq(t.currentCycle(), 2);
        assertEq(t.pendingWithdrawals(target), 475 * USDC, "target gets cycle 1 pot");

        // Cycle 2 prep — all except target pay.
        for (uint256 i = 0; i < 5; i++) {
            if (pArr[i] != target) _makePayment(tandaAddr, pArr[i], 1);
        }

        // Warp + mark
        _warpPastGrace(tandaAddr);
        t.markDefaulter(target);

        // Post-mark: past-slot is KEPT; payoutOrder.length unchanged.
        assertFalse(t.getParticipant(targetParticipantIdx).isActive, "target inactive");
        assertEq(t.activeParticipantCount(), 4, "active count");
        assertEq(t.insuranceBalance(target), 0, "target insurance forfeited");
        assertEq(t.slashedPool(), PREMIUM_PER_CYCLE, "slash pool from target");
        assertEq(t.getPayoutOrder().length, 5, "payoutOrder.length unchanged (past slot)");

        // Continue: cycle 2 trigger, then cycles 3, 4, 5.
        t.triggerPayout(); // cycle 2
        assertEq(t.currentCycle(), 3);

        _runActiveCyclesToCompletion(tandaAddr, pArr);

        // Completion
        assertEq(uint8(t.state()), uint8(Tanda.TandaState.COMPLETED), "completed");
        assertEq(t.currentCycle(), 6, "currentCycle past last");

        // Cycles ran: 5 total (cycle 1 paid target, cycles 2-5 paid other 4)
        // Treasury: 10 + 8×4 = 42 USDC + 200_000 slash share = 42_200_000
        assertEq(t.pendingWithdrawals(TREASURY), 42 * USDC + 200_000, "treasury");

        // Target: still has the 475 USDC from cycle 1 in pending (unchanged by default).
        assertEq(t.pendingWithdrawals(target), 475 * USDC, "target pending = cycle 1 pot");

        // Target gets no completion NFT.
        assertFalse(completionNFT.hasCompletion(target, tandaId), "target no completion");

        // Active participants:
        //   - cycle pot: 380 USDC each (positions 1-4 in payoutOrder all paid at 4-active pot)
        //   - insurance refund: 5 cycles × 10 = 50 USDC each
        //   - slash share: 2.375 USDC (10 USDC pool, 95% / 4)
        //   - alice (creator): + 63 USDC organizer fees (15 + 12×4) + 300_000 slash org
        uint256 nonAliceCredit = 380 * USDC + 50 * USDC + 2_375_000;
        uint256 aliceCredit = nonAliceCredit + 63 * USDC + 300_000;

        for (uint256 i = 0; i < 5; i++) {
            address p = pArr[i];
            if (p == target) continue;
            uint256 expected = (p == alice) ? aliceCredit : nonAliceCredit;
            assertEq(t.pendingWithdrawals(p), expected, "active credit");
            assertTrue(completionNFT.hasCompletion(p, tandaId), "active completion");
        }
    }

    // ────────────────────────────────────────────────────────────────
    // Scenario 3: guard tests
    // ────────────────────────────────────────────────────────────────

    function test_markDefaulter_revertsOnPaidUpParticipant() public {
        (address tandaAddr,) = _create5(alice);
        Tanda t = Tanda(tandaAddr);
        _fill5(tandaAddr, uint256(keccak256("seed_g1")));

        // All are paid up (paidUntilCycle == 1 == currentCycle).
        vm.expectRevert(abi.encodeWithSelector(NotDefaulter.selector, bob));
        t.markDefaulter(bob);
    }

    function test_markDefaulter_revertsBeforeGracePeriodExpires() public {
        (address tandaAddr,) = _create5(alice);
        Tanda t = Tanda(tandaAddr);
        _fill5(tandaAddr, uint256(keccak256("seed_g2")));

        // Cycle 1
        _warpToNextCycle(tandaAddr);
        t.triggerPayout();
        // Now currentCycle = 2. bob hasn't paid for cycle 2.
        // Warp to JUST the cycle 2 deadline (no grace yet).
        uint256 readyAt = t.startTimestamp() + 2 * t.payoutInterval();
        vm.warp(readyAt);

        // block.timestamp = readyAt; expiresAt = readyAt + gracePeriod.
        // Condition is `block.timestamp <= expiresAt` → revert.
        uint256 expiresAt = readyAt + t.gracePeriod();
        vm.expectRevert(abi.encodeWithSelector(GracePeriodNotExpired.selector, readyAt, expiresAt));
        t.markDefaulter(bob);
    }

    function test_markDefaulter_revertsOnNonParticipant() public {
        (address tandaAddr,) = _create5(alice);
        Tanda t = Tanda(tandaAddr);
        _fill5(tandaAddr, uint256(keccak256("seed_g3")));

        address randomAddr = address(0x1234);
        vm.expectRevert(NotParticipant.selector);
        t.markDefaulter(randomAddr);
    }

    function test_markDefaulter_revertsOnDoubleMark() public {
        (address tandaAddr,) = _create5(alice);
        Tanda t = Tanda(tandaAddr);
        _fill5(tandaAddr, uint256(keccak256("seed_g4")));

        // Cycle 1
        _warpToNextCycle(tandaAddr);
        t.triggerPayout();

        // bob doesn't pay cycle 2. Warp past grace.
        _warpPastGrace(tandaAddr);
        t.markDefaulter(bob);

        // Second call should revert AlreadyMarkedDefaulter.
        vm.expectRevert(abi.encodeWithSelector(AlreadyMarkedDefaulter.selector, bob));
        t.markDefaulter(bob);
    }

    function test_markDefaulter_revertsWhenOpen() public {
        (address tandaAddr,) = _create5(alice);
        Tanda t = Tanda(tandaAddr);
        // No fill — still OPEN.
        vm.expectRevert(
            abi.encodeWithSelector(
                WrongTandaState.selector, uint8(Tanda.TandaState.ACTIVE), uint8(Tanda.TandaState.OPEN)
            )
        );
        t.markDefaulter(bob);
    }

    function test_markDefaulter_revertsWhenCompleted() public {
        (address tandaAddr,) = _create5(alice);
        Tanda t = Tanda(tandaAddr);
        _fill5(tandaAddr, uint256(keccak256("seed_g6")));

        // Run all cycles to completion.
        address[5] memory pArr = [alice, bob, carol, dave, eve];
        _warpToNextCycle(tandaAddr);
        t.triggerPayout(); // cycle 1
        while (uint8(t.state()) == uint8(Tanda.TandaState.ACTIVE)) {
            for (uint256 i = 0; i < 5; i++) {
                _makePayment(tandaAddr, pArr[i], 1);
            }
            _warpToNextCycle(tandaAddr);
            t.triggerPayout();
        }

        // Now COMPLETED — markDefaulter reverts.
        vm.expectRevert(
            abi.encodeWithSelector(
                WrongTandaState.selector, uint8(Tanda.TandaState.ACTIVE), uint8(Tanda.TandaState.COMPLETED)
            )
        );
        t.markDefaulter(bob);
    }

    function test_markDefaulter_isPermissionless() public {
        (address tandaAddr,) = _create5(alice);
        Tanda t = Tanda(tandaAddr);
        _fill5(tandaAddr, uint256(keccak256("seed_g7")));

        _warpToNextCycle(tandaAddr);
        t.triggerPayout(); // cycle 1
        // bob doesn't pay cycle 2.

        _warpPastGrace(tandaAddr);

        // Random non-participant address can call markDefaulter.
        address randomCaller = address(0xBEEFCAFE);
        vm.prank(randomCaller);
        t.markDefaulter(bob);

        assertFalse(t.getParticipant(1).isActive, "bob marked by random caller");
    }

    // ────────────────────────────────────────────────────────────────
    // Scenario 4: slash pool math with engineered dust
    // ────────────────────────────────────────────────────────────────

    function test_slashPool_mathExact() public {
        // Setup: 4 participants (alice + 3 others). Pick a non-alice target
        // at a future slot. After default → 3 active. Slash pool = 10 USDC
        // (1 cycle of insurance). 95% = 9.5 USDC. perActive = 3.166666 USDC.
        // Dust = 9_500_000 - 3 × 3_166_666 = 2 base units.
        (address tandaAddr,) = _create4(alice);
        Tanda t = Tanda(tandaAddr);
        _fill4(tandaAddr, uint256(keccak256("seed_dust")));

        // Find latest non-alice future-slot target.
        uint256[] memory order = t.getPayoutOrder();
        address[4] memory pArr = [alice, bob, carol, dave];
        for (uint256 i = 4; i > 1; i--) {
            address candidate = pArr[order[i - 1]];
            if (candidate != alice) {
                target = candidate;
                targetParticipantIdx = order[i - 1];
                targetPositionInOrder = i - 1;
                break;
            }
        }
        require(target != address(0), "no non-alice future slot");

        // Cycle 1
        _warpToNextCycle(tandaAddr);
        t.triggerPayout();

        // Cycle 2 prep: 3 of 4 pay
        for (uint256 i = 0; i < 4; i++) {
            if (pArr[i] != target) _makePayment(tandaAddr, pArr[i], 1);
        }

        // Snapshot pre-mark treasury to isolate slash pool contribution.
        uint256 treasuryBeforeMark = t.pendingWithdrawals(TREASURY);
        // Cycle 1 platform = 8 USDC (pot 400, 2%).
        assertEq(treasuryBeforeMark, 8 * USDC, "treasury before mark = cycle 1 platform");

        _warpPastGrace(tandaAddr);
        t.markDefaulter(target);

        assertEq(t.slashedPool(), PREMIUM_PER_CYCLE, "slash pool = 10 USDC");
        assertEq(t.getPayoutOrder().length, 3, "payoutOrder shrunk to 3");
        assertEq(t.activeParticipantCount(), 3, "3 active");

        // Continue to completion (cycles 2 and 3).
        t.triggerPayout(); // cycle 2
        _makePayment(tandaAddr, pArr[0], 1);
        if (pArr[1] != target) _makePayment(tandaAddr, pArr[1], 1);
        if (pArr[2] != target) _makePayment(tandaAddr, pArr[2], 1);
        if (pArr[3] != target) _makePayment(tandaAddr, pArr[3], 1);
        _warpToNextCycle(tandaAddr);
        t.triggerPayout(); // cycle 3 → completion

        assertEq(uint8(t.state()), uint8(Tanda.TandaState.COMPLETED), "completed");

        // Now verify the exact slash pool numbers.
        //
        // Treasury cycle platforms: 8 (c1) + 6 (c2) + 6 (c3) = 20 USDC.
        // Treasury slash share: 200_000 + dust 2 = 200_002.
        // Treasury total: 20_200_002.
        assertEq(t.pendingWithdrawals(TREASURY), 20 * USDC + 200_002, "treasury exact w/ dust");

        // Alice (creator) organizer fees: 12 (c1) + 9 (c2) + 9 (c3) = 30 USDC.
        // Alice slash org share: 300_000.
        //
        // Alice insurance refund: 3 cycles × 10 = 30 USDC.
        // Alice slash recipient share: 3_166_666 (perActive).
        // Alice recipient share: 380 (cycle 1) or 285 (cycles 2-3) depending on position.
        {
            uint256 expAlice = 30 * USDC // organizer fees
                + 300_000 // slash org share
                + 30 * USDC // insurance refund
                + 3_166_666; // slash recipient share

            for (uint256 i = 0; i < 4; i++) {
                if (pArr[order[i]] == alice) {
                    expAlice += (i == 0) ? 380 * USDC : 285 * USDC;
                    break;
                }
            }
            assertEq(t.pendingWithdrawals(alice), expAlice, "alice exact");
        }

        // Each non-alice non-target participant: insurance refund 30 + slash share 3_166_666 + recipient share.
        for (uint256 i = 0; i < 4; i++) {
            address p = pArr[i];
            if (p == alice || p == target) continue;
            uint256 expected = 30 * USDC + 3_166_666;
            for (uint256 j = 0; j < 4; j++) {
                if (pArr[order[j]] == p) {
                    expected += (j == 0) ? 380 * USDC : 285 * USDC;
                    break;
                }
            }
            assertEq(t.pendingWithdrawals(p), expected, "non-alice non-target exact");
        }

        // Target: zero pending (defaulted at cycle 2 before being paid).
        assertEq(t.pendingWithdrawals(target), 0, "target zero");

        // Sum-of-credits sanity: contract balance == sum of pendingWithdrawals.
        uint256 sumPending = t.pendingWithdrawals(alice) + t.pendingWithdrawals(bob) + t.pendingWithdrawals(carol)
            + t.pendingWithdrawals(dave) + t.pendingWithdrawals(TREASURY);
        assertEq(usdc.balanceOf(tandaAddr), sumPending, "contract balance == sum pending");
    }
}
