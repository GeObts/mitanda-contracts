// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {MitandaTestBase} from "./helpers/MitandaTestBase.sol";
import {Tanda} from "../src/Tanda.sol";
import {ITanda} from "../src/interfaces/ITanda.sol";

/// @title  FullLifecycleIntegrationTest
/// @notice End-to-end lifecycle: create → fill (VRF) → pay + trigger every
///         cycle by warping time → completion. Asserts the per-cycle 95/2/3
///         split (recipient / treasury / creator) and the insurance refund at
///         completion, then proves the pull-payment model (credits are accrued
///         and claimed via withdraw(), never pushed). Includes a one-defaulter
///         variant asserting the slashed premium is redistributed and honest
///         refunds still settle.
contract FullLifecycleIntegrationTest is MitandaTestBase {
    uint256 internal constant USDC = 10 ** 6;
    uint256 internal constant CONTRIBUTION = 100 * USDC; // == DEFAULT_CONTRIBUTION
    uint256 internal constant CHARGE_PER_CYCLE = 110 * USDC; // contribution + 10% premium

    // 95/2/3 split of a 3-participant pot (3 × 100 = 300 USDC):
    uint256 internal constant PLATFORM = 6 * USDC; // 2%
    uint256 internal constant ORGANIZER = 9 * USDC; // 3%
    uint256 internal constant RECIPIENT = 285 * USDC; // 95%
    uint256 internal constant PREMIUM = 10 * USDC; // 10% per cycle

    function _makePayment(address tandaAddr, address user, uint256 cycles) internal {
        _fundAndApprove(user, cycles * CHARGE_PER_CYCLE, tandaAddr);
        vm.prank(user);
        Tanda(tandaAddr).makePayment(cycles);
    }

    function _warpPastGrace(address tandaAddr) internal {
        Tanda t = Tanda(tandaAddr);
        vm.warp(t.startTimestamp() + t.currentCycle() * t.payoutInterval() + t.gracePeriod() + 1);
    }

    // ─────────────────────────────────────────────────────────────────────
    // (a) Full happy-path lifecycle — per-cycle splits + insurance refund
    // ─────────────────────────────────────────────────────────────────────

    function test_fullLifecycle_perCycleSplits_andInsuranceRefund() public {
        // 3-participant tanda: creator alice (auto-enrolled #0) + bob + carol.
        (address tandaAddr,) = _createDefaultTanda(alice);
        Tanda t = Tanda(tandaAddr);

        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = carol;
        _fillAndStart(tandaAddr, users, uint256(keccak256("seed_lifecycle_integ")));

        assertEq(uint8(t.state()), uint8(Tanda.TandaState.ACTIVE), "ACTIVE after fill");
        assertEq(t.activeParticipantCount(), 3, "3 participants (creator + 2 joiners)");

        uint256[] memory order = t.getPayoutOrder();
        address[3] memory pArr = [alice, bob, carol];

        // Cycles 1 and 2: clean per-cycle split assertions (no completion yet).
        for (uint256 c = 1; c <= 2; c++) {
            if (c > 1) {
                _makePayment(tandaAddr, alice, 1);
                _makePayment(tandaAddr, bob, 1);
                _makePayment(tandaAddr, carol, 1);
            }
            address recipient = pArr[order[c - 1]];
            uint256 trBefore = t.pendingWithdrawals(TREASURY);
            uint256 crBefore = t.pendingWithdrawals(alice); // creator
            uint256 rcBefore = t.pendingWithdrawals(recipient);

            _warpToNextCycle(tandaAddr);
            t.triggerPayout();

            // Treasury gets exactly 2% EVERY cycle.
            assertEq(t.pendingWithdrawals(TREASURY) - trBefore, PLATFORM, "treasury 2% this cycle");

            if (recipient == alice) {
                // The creator is also the recipient this cycle: 95% + 3%.
                assertEq(
                    t.pendingWithdrawals(alice) - crBefore, RECIPIENT + ORGANIZER, "creator-as-recipient gets 95% + 3%"
                );
            } else {
                assertEq(t.pendingWithdrawals(recipient) - rcBefore, RECIPIENT, "recipient gets 95%");
                assertEq(t.pendingWithdrawals(alice) - crBefore, ORGANIZER, "creator gets 3%");
            }
        }

        // Cycle 3 completes the tanda. Pay all, warp, trigger.
        _makePayment(tandaAddr, alice, 1);
        _makePayment(tandaAddr, bob, 1);
        _makePayment(tandaAddr, carol, 1);
        uint256 trBefore3 = t.pendingWithdrawals(TREASURY);
        _warpToNextCycle(tandaAddr);
        t.triggerPayout();

        assertEq(uint8(t.state()), uint8(Tanda.TandaState.COMPLETED), "COMPLETED after 3 cycles");
        // Treasury 2% on the final cycle too (treasury is not a participant — no insurance).
        assertEq(t.pendingWithdrawals(TREASURY) - trBefore3, PLATFORM, "treasury 2% cycle 3");

        // Final cumulative credits (order-independent — each participant is the
        // recipient exactly once over the run):
        //   alice = 285 (her recipient cycle) + 27 (organizer 3% × 3) + 30 (insurance 10 × 3)
        //   bob   = 285 + 30 ;  carol = 285 + 30 ;  treasury = 18 (6 × 3)
        uint256 insuranceRefund = PREMIUM * 3; // 30 USDC = three cycles of premium
        assertEq(
            t.pendingWithdrawals(alice),
            RECIPIENT + ORGANIZER * 3 + insuranceRefund,
            "alice: recipient + organizer + insurance"
        );
        assertEq(t.pendingWithdrawals(bob), RECIPIENT + insuranceRefund, "bob: recipient + insurance refund");
        assertEq(t.pendingWithdrawals(carol), RECIPIENT + insuranceRefund, "carol: recipient + insurance refund");
        assertEq(t.pendingWithdrawals(TREASURY), PLATFORM * 3, "treasury: 2% x 3 cycles");

        // Insurance premiums were REFUNDED (balances zeroed at completion).
        assertEq(t.insuranceBalance(alice), 0, "alice insurance refunded");
        assertEq(t.insuranceBalance(bob), 0, "bob insurance refunded");
        assertEq(t.insuranceBalance(carol), 0, "carol insurance refunded");

        // ── Pull-payment: credits are ACCRUED, claimed via withdraw() — not pushed.
        // The creator's 3% organizer fee + insurance refund sit in pendingWithdrawals
        // until the creator calls withdraw(); nothing reached their wallet at payout.
        uint256 aliceWalletBefore = usdc.balanceOf(alice);
        uint256 alicePending = t.pendingWithdrawals(alice);
        vm.prank(alice);
        t.withdraw();
        assertEq(usdc.balanceOf(alice) - aliceWalletBefore, alicePending, "creator pulled credits via withdraw()");
        assertEq(t.pendingWithdrawals(alice), 0, "alice pending cleared after withdraw");

        // Everyone else withdraws — the clone drains to exactly zero.
        vm.prank(bob);
        t.withdraw();
        vm.prank(carol);
        t.withdraw();
        vm.prank(TREASURY);
        t.withdraw();
        assertEq(usdc.balanceOf(tandaAddr), 0, "clone fully drained - all value is pull-payment");
    }

    // ─────────────────────────────────────────────────────────────────────
    // (a, variant) One defaulter — premium slashed/redistributed, honest settle
    // ─────────────────────────────────────────────────────────────────────

    function test_lifecycle_oneDefaulter_premiumSlashed_honestRefundsSettle() public {
        (address tandaAddr,) = _createDefaultTanda(alice);
        Tanda t = Tanda(tandaAddr);

        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = carol;
        _fillAndStart(tandaAddr, users, uint256(keccak256("seed_defaulter_integ")));

        uint256[] memory order = t.getPayoutOrder();
        address[3] memory pArr = [alice, bob, carol];
        // The cycle-3 slot holder is a future-slot participant after cycle 1 —
        // they'll default. The other two are the honest actives.
        address defaulter = pArr[order[2]];
        address honestA = pArr[order[0]]; // cycle-1 recipient
        address honestB = pArr[order[1]]; // cycle-2 recipient

        // Cycle 1: everyone paid at join/create. Trigger pays honestA.
        _warpToNextCycle(tandaAddr);
        t.triggerPayout();
        assertEq(t.currentCycle(), 2, "advanced to cycle 2");

        // Cycle 2: the two honest actives pay; the defaulter does not.
        _makePayment(tandaAddr, honestA, 1);
        _makePayment(tandaAddr, honestB, 1);

        // Past grace → mark the defaulter. Their cycle-1 premium is slashed.
        _warpPastGrace(tandaAddr);
        t.markDefaulter(defaulter);
        assertEq(t.insuranceBalance(defaulter), 0, "defaulter insurance forfeited");
        assertEq(t.slashedPool(), PREMIUM, "defaulter's premium moved into the slash pool");
        assertEq(t.activeParticipantCount(), 2, "2 active after the default");

        // Cycle 2 trigger pays honestB; pruning drove payoutOrder to length 2 so
        // currentCycle (3) > payoutOrder.length (2) → the tanda auto-completes.
        t.triggerPayout();
        assertEq(uint8(t.state()), uint8(Tanda.TandaState.COMPLETED), "completed");

        // The slashed premium was REDISTRIBUTED at completion (pool drained 95/2/3).
        assertEq(t.slashedPool(), 0, "slash pool distributed");
        assertEq(t.insuranceBalance(defaulter), 0, "defaulter still forfeited");

        // Honest refunds settled: both honest actives had their insurance refunded
        // (balances zeroed) and have a positive, withdrawable credit.
        assertEq(t.insuranceBalance(honestA), 0, "honestA insurance refunded");
        assertEq(t.insuranceBalance(honestB), 0, "honestB insurance refunded");
        assertGt(t.pendingWithdrawals(honestA), 0, "honestA has a credit");
        assertGt(t.pendingWithdrawals(honestB), 0, "honestB has a credit");

        // Conservation: the clone holds exactly the sum of all credits (nothing
        // lost or created by the slash + redistribution).
        uint256 totalCredits = t.pendingWithdrawals(alice) + t.pendingWithdrawals(bob) + t.pendingWithdrawals(carol)
            + t.pendingWithdrawals(TREASURY);
        assertEq(usdc.balanceOf(tandaAddr), totalCredits, "conservation: balance == sum of credits");

        // Honest refunds are actually withdrawable (pull-payment settles).
        uint256 walletBefore = usdc.balanceOf(honestA);
        uint256 pending = t.pendingWithdrawals(honestA);
        vm.prank(honestA);
        t.withdraw();
        assertEq(usdc.balanceOf(honestA) - walletBefore, pending, "honest refund withdrawn to wallet");
        assertEq(t.pendingWithdrawals(honestA), 0, "honestA credit cleared");
    }

    // ─────────────────────────────────────────────────────────────────────
    // (audit #3/#4) Liveness: always reaches COMPLETED + funds never trapped
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Create + start a 5-participant PUBLIC tanda: creator alice
    ///      (auto-enrolled #0) + bob/carol/dave/eve. `pArr[i]` == participant i;
    ///      `pArr[payoutOrder[c-1]]` is cycle `c`'s recipient.
    function _start5(uint256 seed) internal returns (address tandaAddr, address[5] memory pArr) {
        _enableCreate(alice, CONTRIBUTION);
        vm.prank(alice);
        uint256 id = manager.createTanda(
            address(usdc), CONTRIBUTION, DEFAULT_PAYOUT_INTERVAL, 5, DEFAULT_GRACE_PERIOD, 0, ITanda.TandaPrivacy.PUBLIC
        );
        tandaAddr = manager.tandaIdToAddress(id);
        address[] memory users = new address[](4);
        users[0] = bob;
        users[1] = carol;
        users[2] = dave;
        users[3] = eve;
        _fillAndStart(tandaAddr, users, seed);
        pArr = [alice, bob, carol, dave, eve];
    }

    function _drainIfAny(address tandaAddr, address a) internal {
        if (Tanda(tandaAddr).pendingWithdrawals(a) > 0) {
            vm.prank(a);
            Tanda(tandaAddr).withdraw();
        }
    }

    /// @notice MAJORITY default (3 of 5): the tanda still reaches COMPLETED,
    ///         honest survivors' refunds settle, and every wei is claimable
    ///         (clone drains to zero — no funds can be trapped).
    function test_majorityDefault_completes_honestRefundsSettle_noTrappedFunds() public {
        (address tandaAddr, address[5] memory pArr) = _start5(uint256(keccak256("seed_majority")));
        Tanda t = Tanda(tandaAddr);
        uint256[] memory order = t.getPayoutOrder();
        address surv0 = pArr[order[0]]; // cycle-1 recipient — survives
        address surv1 = pArr[order[1]]; // cycle-2 recipient — survives
        // The three future-slot holders default before they ever receive.
        address[3] memory defs = [pArr[order[2]], pArr[order[3]], pArr[order[4]]];

        // Cycle 1 pays surv0.
        _warpToNextCycle(tandaAddr);
        t.triggerPayout();

        // Only the two survivors pay cycle 2.
        _makePayment(tandaAddr, surv0, 1);
        _makePayment(tandaAddr, surv1, 1);

        // Past grace → mark the three defaulters; their future slots are pruned.
        _warpPastGrace(tandaAddr);
        for (uint256 i = 0; i < 3; i++) {
            t.markDefaulter(defs[i]);
        }
        assertEq(t.activeParticipantCount(), 2, "2 survivors remain active");
        assertEq(t.slashedPool(), 3 * PREMIUM, "three premiums slashed into the pool");

        // Cycle 2 pays surv1; pruning drove payoutOrder.length (2) below the next
        // cycle index (3), so the tanda AUTO-COMPLETES — it can always finish.
        t.triggerPayout();
        assertEq(uint8(t.state()), uint8(Tanda.TandaState.COMPLETED), "reaches COMPLETED despite majority default");
        assertEq(t.slashedPool(), 0, "slashed premiums redistributed at completion");

        // Honest refunds settled.
        assertEq(t.insuranceBalance(surv0), 0, "surv0 insurance refunded");
        assertEq(t.insuranceBalance(surv1), 0, "surv1 insurance refunded");
        assertGt(t.pendingWithdrawals(surv0), 0, "surv0 has a claim");
        assertGt(t.pendingWithdrawals(surv1), 0, "surv1 has a claim");

        // NO TRAPPED FUNDS: conservation, then every credit drains to zero.
        uint256 credits = t.pendingWithdrawals(TREASURY);
        for (uint256 i = 0; i < 5; i++) {
            credits += t.pendingWithdrawals(pArr[i]);
        }
        assertEq(usdc.balanceOf(tandaAddr), credits, "conservation: balance == sum of all credits");
        for (uint256 i = 0; i < 5; i++) {
            _drainIfAny(tandaAddr, pArr[i]);
        }
        _drainIfAny(tandaAddr, TREASURY);
        assertEq(usdc.balanceOf(tandaAddr), 0, "no trapped funds: clone drains to zero");
    }

    /// @notice TOTAL default (all 5): full collapse still reaches COMPLETED, the
    ///         treasury absorbs the entire balance (lender-of-last-resort), and
    ///         nothing is trapped — the clone drains to zero.
    function test_totalDefault_fullCollapse_completes_noTrappedFunds() public {
        (address tandaAddr, address[5] memory pArr) = _start5(uint256(keccak256("seed_total")));
        Tanda t = Tanda(tandaAddr);
        uint256[] memory order = t.getPayoutOrder();

        // Cycle 1 pays order[0].
        _warpToNextCycle(tandaAddr);
        t.triggerPayout();

        // Nobody pays cycle 2. Past grace → mark ALL FIVE. The final mark drives
        // activeParticipantCount to 0 → _fullCollapse → COMPLETED (never stuck).
        _warpPastGrace(tandaAddr);
        for (uint256 i = 0; i < 5; i++) {
            t.markDefaulter(pArr[order[i]]);
        }

        assertEq(uint8(t.state()), uint8(Tanda.TandaState.COMPLETED), "full collapse reaches COMPLETED");
        assertEq(t.activeParticipantCount(), 0, "no survivors");

        // Every participant claim + insurance is forfeited; treasury absorbs all.
        for (uint256 i = 0; i < 5; i++) {
            assertEq(t.pendingWithdrawals(pArr[i]), 0, "participant credit forfeited");
            assertEq(t.insuranceBalance(pArr[i]), 0, "participant insurance forfeited");
        }
        assertEq(t.pendingWithdrawals(TREASURY), usdc.balanceOf(tandaAddr), "treasury holds the entire balance");

        // NO TRAPPED FUNDS: treasury withdraws everything; clone drains to zero.
        vm.prank(TREASURY);
        t.withdraw();
        assertEq(usdc.balanceOf(tandaAddr), 0, "no trapped funds after full collapse");
    }
}
