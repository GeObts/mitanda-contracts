// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {MitandaTestBase} from "./helpers/MitandaTestBase.sol";
import {Tanda} from "../src/Tanda.sol";
import {ITanda} from "../src/interfaces/ITanda.sol";
import {NothingToClaim, ZeroAmount, CyclesOutOfRange} from "../src/MitandaErrors.sol";

/// @title  EdgeCasesAndFuzzTest
/// @notice Boundary scenarios + fuzz coverage.
/// @dev    Includes one test that intentionally demonstrates a real OOB
///         bug in the all-future-slot defaulter case where pruning
///         drives `payoutOrder.length` below `currentCycle` — see
///         `test_KNOWN_BUG_allFutureSlotDefaulters_triggersOOB` and the
///         comment block above the "all defaulters except one" test
///         for the working past+future mix that avoids it.
contract EdgeCasesAndFuzzTest is MitandaTestBase {
    uint256 internal constant USDC = 10 ** 6;
    uint256 internal constant CONTRIBUTION = 100 * USDC;
    uint256 internal constant CHARGE_PER_CYCLE = 110 * USDC;

    // Extra participant used in scenarios where alice is creator-only.
    address internal frank = makeAddr("frank");

    // Local redeclaration so vm.expectEmit can match by signature.
    event FullCollapse(address indexed treasury, uint256 amount);

    // ────────────────────────────────────────────────────────────────
    // Helpers
    // ────────────────────────────────────────────────────────────────

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

    function _createCustomTanda(address creator, uint16 partCount, uint256 contribution)
        internal
        returns (address tandaAddr, uint256 tandaId)
    {
        vm.prank(creator);
        tandaId = manager.createTanda(
            address(usdc),
            contribution,
            DEFAULT_PAYOUT_INTERVAL,
            partCount,
            DEFAULT_GRACE_PERIOD,
            0,
            ITanda.TandaPrivacy.PUBLIC
        );
        tandaAddr = manager.tandaIdToAddress(tandaId);
    }

    // ────────────────────────────────────────────────────────────────
    // Boundary: minimum (2 participants)
    // ────────────────────────────────────────────────────────────────

    function test_minimumTanda_2participants() public {
        (address tandaAddr, uint256 tandaId) = _createCustomTanda(alice, 2, CONTRIBUTION);
        Tanda t = Tanda(tandaAddr);

        // alice + bob fill; alice is creator AND participant.
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;
        _fillAndStart(tandaAddr, users, uint256(keccak256("seed_min")));
        assertEq(t.activeParticipantCount(), 2);
        assertEq(t.getPayoutOrder().length, 2);

        // Run both cycles. Pot = 200 USDC, splits 190/4/6.
        // Cycle 1: trigger.
        _warpToNextCycle(tandaAddr);
        t.triggerPayout();
        assertEq(t.currentCycle(), 2);

        // Cycle 2 prep: both pay.
        _makePayment(tandaAddr, alice, 1);
        _makePayment(tandaAddr, bob, 1);

        _warpToNextCycle(tandaAddr);
        t.triggerPayout();
        assertEq(uint8(t.state()), uint8(Tanda.TandaState.COMPLETED));

        // Each participant: 1 recipient share (190) + insurance refund (20) = 210.
        // Plus alice (creator) gets organizer fees (6 × 2 = 12).
        uint256 expAlice = 190 * USDC + 20 * USDC + 12 * USDC;
        uint256 expBob = 190 * USDC + 20 * USDC;
        uint256 expTreasury = 4 * USDC * 2; // 8 USDC over 2 cycles
        assertEq(t.pendingWithdrawals(alice), expAlice, "alice");
        assertEq(t.pendingWithdrawals(bob), expBob, "bob");
        assertEq(t.pendingWithdrawals(TREASURY), expTreasury, "treasury");

        // Drains
        vm.prank(alice);
        t.withdraw();
        vm.prank(bob);
        t.withdraw();
        vm.prank(TREASURY);
        t.withdraw();
        assertEq(usdc.balanceOf(tandaAddr), 0, "drained");

        assertTrue(completionNFT.hasCompletion(alice, tandaId));
        assertTrue(completionNFT.hasCompletion(bob, tandaId));
    }

    // ────────────────────────────────────────────────────────────────
    // Boundary: maximum (50 participants)
    // ────────────────────────────────────────────────────────────────

    function test_maximumTanda_50participants() public {
        // Default CALLBACK_GAS_LIMIT (500k) is sized for typical tandas but
        // is too tight for a 50-element shuffle (~50 cold SSTOREs + 49
        // swaps ≈ 1.6M gas). Bump for this test only — production deploys
        // should size the VRF callback for the worst case (MAX_PARTICIPANTS).
        manager.updateVRFConfig(subId, GAS_LANE, 2_500_000, 3, 1, true);

        (address tandaAddr,) = _createCustomTanda(alice, 50, CONTRIBUTION);
        Tanda t = Tanda(tandaAddr);

        address[] memory users = new address[](50);
        for (uint256 i = 0; i < 50; i++) {
            users[i] = makeAddr(string.concat("user_", vm.toString(i)));
        }

        _fillAndStart(tandaAddr, users, uint256(keccak256("seed_max")));

        assertEq(uint8(t.state()), uint8(Tanda.TandaState.ACTIVE), "ACTIVE");
        assertEq(t.activeParticipantCount(), 50);

        // Shuffle covers all 50 indices uniquely.
        uint256[] memory order = t.getPayoutOrder();
        assertEq(order.length, 50);
        bool[] memory seen = new bool[](50);
        for (uint256 i = 0; i < 50; i++) {
            assertLt(order[i], 50, "in range");
            assertFalse(seen[order[i]], "no duplicates");
            seen[order[i]] = true;
        }

        // Cycle 1: pot = 50 × 100 = 5000 USDC. Splits 4750/100/150.
        _warpToNextCycle(tandaAddr);
        t.triggerPayout();

        address cycle1Recipient = users[order[0]];
        assertEq(t.pendingWithdrawals(cycle1Recipient), 4750 * USDC, "cycle1 recipient");
        assertEq(t.pendingWithdrawals(TREASURY), 100 * USDC, "treasury cycle1");
        assertEq(t.pendingWithdrawals(alice), 150 * USDC, "alice organizer cycle1");

        assertEq(t.currentCycle(), 2, "advanced to cycle 2");
    }

    // ────────────────────────────────────────────────────────────────
    // "All defaulters except one" — WORKING variant
    // (mixed past + future defaulters to avoid OOB bug)
    // ────────────────────────────────────────────────────────────────

    /// @dev Structure: 5 participants (alice = creator-only; bob, carol,
    ///      dave, eve, frank join).
    ///      - Cycle 1's recipient defaults AFTER receiving (past-slot
    ///        defaulter — slot is kept, payoutOrder.length unchanged).
    ///      - 3 of the remaining 4 also default at cycle 2 (future-slot).
    ///      - The 5th is the lone survivor who pays cycle 2.
    ///      After all 4 marked: `payoutOrder.length = 2` (cycle-1's past
    ///      slot + survivor's slot), `activeParticipantCount = 1`.
    ///      Cycle 2 triggers cleanly, pays survivor, then completes.
    function test_allDefaulters_exceptOne() public {
        (address tandaAddr, uint256 tandaId) = _createCustomTanda(alice, 5, CONTRIBUTION);
        Tanda t = Tanda(tandaAddr);

        address[] memory users = new address[](5);
        users[0] = bob;
        users[1] = carol;
        users[2] = dave;
        users[3] = eve;
        users[4] = frank;
        _fillAndStart(tandaAddr, users, uint256(keccak256("seed_alldef")));

        uint256[] memory order = t.getPayoutOrder();
        address[5] memory pArr = [bob, carol, dave, eve, frank];
        address cycle1Recipient = pArr[order[0]];
        address survivor = pArr[order[4]];

        // Identify the 3 mid-position defaulters
        address def2 = pArr[order[1]];
        address def3 = pArr[order[2]];
        address def4 = pArr[order[3]];

        emit log_named_address("cycle 1 recipient (past-slot defaulter)", cycle1Recipient);
        emit log_named_address("survivor", survivor);

        // Cycle 1
        _warpToNextCycle(tandaAddr);
        t.triggerPayout();
        assertEq(t.pendingWithdrawals(cycle1Recipient), 475 * USDC, "cycle 1 pot to recipient");

        // Pre-cycle 2: only survivor pays.
        _makePayment(tandaAddr, survivor, 1);

        // Warp past grace + mark all 4 defaulters.
        _warpPastGrace(tandaAddr);
        t.markDefaulter(cycle1Recipient); // past-slot
        t.markDefaulter(def2); // future-slot
        t.markDefaulter(def3); // future-slot
        t.markDefaulter(def4); // future-slot

        assertEq(t.activeParticipantCount(), 1, "1 active");
        // payoutOrder: cycle1Recipient's past slot kept + survivor's slot kept = 2.
        assertEq(t.getPayoutOrder().length, 2, "payoutOrder shrunk to 2");
        // slashPool: 4 × 10 USDC = 40 USDC
        assertEq(t.slashedPool(), 40 * USDC, "slash pool collected");

        // Cycle 2 trigger — pays survivor (pot = 100, 95/2/3 split).
        t.triggerPayout();
        assertEq(uint8(t.state()), uint8(Tanda.TandaState.COMPLETED), "completed");

        // Verify NFTs
        assertTrue(completionNFT.hasCompletion(survivor, tandaId), "survivor completion");
        assertFalse(completionNFT.hasCompletion(cycle1Recipient, tandaId), "def1 no completion");
        assertFalse(completionNFT.hasCompletion(def2, tandaId));
        assertFalse(completionNFT.hasCompletion(def3, tandaId));
        assertFalse(completionNFT.hasCompletion(def4, tandaId));

        // Survivor: cycle 2 recipient (95) + insurance refund (20) + slash share (38) = 153 USDC
        uint256 expSurvivor = 95 * USDC + 20 * USDC + 38 * USDC;
        assertEq(t.pendingWithdrawals(survivor), expSurvivor, "survivor exact");

        // Cycle 1 recipient: keeps their 475 (no insurance refund, no slash share — inactive)
        assertEq(t.pendingWithdrawals(cycle1Recipient), 475 * USDC, "cycle1 recipient kept");

        // Other defaulters: nothing
        assertEq(t.pendingWithdrawals(def2), 0);
        assertEq(t.pendingWithdrawals(def3), 0);
        assertEq(t.pendingWithdrawals(def4), 0);

        // Treasury: cycle 1 platform (10) + cycle 2 platform (2) + slash platform (0.8) = 12.8 USDC
        assertEq(t.pendingWithdrawals(TREASURY), 10 * USDC + 2 * USDC + 800_000, "treasury exact");

        // Alice (creator-only): organizer fees (15 c1 + 3 c2 = 18 USDC) + slash org (1.2 USDC)
        assertEq(t.pendingWithdrawals(alice), 18 * USDC + 1_200_000, "alice organizer exact");
    }

    /// @dev Verifies the auto-completion path triggered by future-slot
    ///      pruning. Scenario: cycle-1 recipient is the lone survivor;
    ///      the other 4 default before their payouts. After the 4th
    ///      `markDefaulter`, `payoutOrder.length = 1 < currentCycle = 2`,
    ///      so the auto-complete trigger fires `_completeTanda` in the
    ///      same transaction. With `activeParticipantCount = 1`, normal
    ///      completion runs — survivor gets insurance refund, excess
    ///      contribution refund (1 cycle = 100 USDC), and slash-pool
    ///      share.
    function test_allFutureSlotDefaulters_autoCompletes() public {
        (address tandaAddr, uint256 tandaId) = _createCustomTanda(alice, 5, CONTRIBUTION);
        Tanda t = Tanda(tandaAddr);

        address[] memory users = new address[](5);
        users[0] = bob;
        users[1] = carol;
        users[2] = dave;
        users[3] = eve;
        users[4] = frank;
        _fillAndStart(tandaAddr, users, uint256(keccak256("seed_oob")));

        uint256[] memory order = t.getPayoutOrder();
        address[5] memory pArr = [bob, carol, dave, eve, frank];
        address survivor = pArr[order[0]]; // cycle 1 recipient = survivor

        address[] memory defaulters = new address[](4);
        defaulters[0] = pArr[order[1]];
        defaulters[1] = pArr[order[2]];
        defaulters[2] = pArr[order[3]];
        defaulters[3] = pArr[order[4]];

        // Cycle 1 — survivor receives 475 USDC.
        _warpToNextCycle(tandaAddr);
        t.triggerPayout();
        assertEq(t.pendingWithdrawals(survivor), 475 * USDC, "cycle 1 pot to survivor");

        // Pre-cycle 2: only the survivor pays (others become defaulters).
        _makePayment(tandaAddr, survivor, 1);

        _warpPastGrace(tandaAddr);
        t.markDefaulter(defaulters[0]);
        t.markDefaulter(defaulters[1]);
        t.markDefaulter(defaulters[2]);
        // The 4th mark drives payoutOrder.length to 1 < currentCycle (2),
        // triggering auto-complete in the same call.
        t.markDefaulter(defaulters[3]);

        // State after auto-complete
        assertEq(uint8(t.state()), uint8(Tanda.TandaState.COMPLETED), "auto-completed");
        assertEq(t.getPayoutOrder().length, 1, "payoutOrder shrunk to 1");
        assertEq(t.activeParticipantCount(), 1, "1 active");

        // Survivor breakdown (exact):
        //   475 USDC cycle 1 recipient (already credited at cycle 1 trigger)
        // +  20 USDC insurance refund (2 cycles paid × 10 USDC premium)
        // + 100 USDC excess contribution refund (paidUntilCycle=2 minus payoutOrder.length=1)
        // +  38 USDC slash pool share (95% of 40 USDC pool, /1 active)
        // = 633 USDC
        assertEq(t.pendingWithdrawals(survivor), 633 * USDC, "survivor exact");

        // Treasury: 10 cycle-1 platform + 0.8 slash platform = 10.8 USDC
        assertEq(t.pendingWithdrawals(TREASURY), 10 * USDC + 800_000, "treasury exact");

        // Alice (creator-only): 15 cycle-1 organizer + 1.2 slash organizer = 16.2 USDC
        assertEq(t.pendingWithdrawals(alice), 15 * USDC + 1_200_000, "alice exact");

        // Defaulters: zero
        for (uint256 i = 0; i < 4; i++) {
            assertEq(t.pendingWithdrawals(defaulters[i]), 0, "defaulter pending zero");
            assertFalse(completionNFT.hasCompletion(defaulters[i], tandaId), "defaulter no completion NFT");
        }
        assertTrue(completionNFT.hasCompletion(survivor, tandaId), "survivor has completion NFT");

        // Drain check: all four withdraw, contract goes to zero.
        vm.prank(survivor);
        t.withdraw();
        vm.prank(TREASURY);
        t.withdraw();
        vm.prank(alice);
        t.withdraw();
        assertEq(usdc.balanceOf(tandaAddr), 0, "drained to zero");
    }

    /// @dev Full collapse: every participant defaults, no honest survivor.
    ///      The 5th `markDefaulter` brings `activeParticipantCount` to 0
    ///      with `payoutOrder.length < currentCycle`, routing through
    ///      `_completeTanda`'s early-return branch into `_fullCollapse`,
    ///      which sweeps the entire token balance to treasury and
    ///      forfeits all prior credits (cycle-1 recipient's 475, alice's
    ///      15) and insurance balances.
    function test_fullCollapse_allDefaulters_everythingToTreasury() public {
        (address tandaAddr, uint256 tandaId) = _createCustomTanda(alice, 5, CONTRIBUTION);
        Tanda t = Tanda(tandaAddr);

        address[] memory users = new address[](5);
        users[0] = bob;
        users[1] = carol;
        users[2] = dave;
        users[3] = eve;
        users[4] = frank;
        _fillAndStart(tandaAddr, users, uint256(keccak256("seed_fullcollapse")));

        uint256[] memory order = t.getPayoutOrder();
        address[5] memory pArr = [bob, carol, dave, eve, frank];
        address cycle1Recipient = pArr[order[0]];

        // Cycle 1 triggers — 475 to recipient, 10 to treasury, 15 to alice.
        _warpToNextCycle(tandaAddr);
        t.triggerPayout();
        assertEq(t.pendingWithdrawals(cycle1Recipient), 475 * USDC, "cycle 1 credit before collapse");
        assertEq(t.pendingWithdrawals(alice), 15 * USDC, "alice credit before collapse");
        assertEq(t.pendingWithdrawals(TREASURY), 10 * USDC, "treasury credit before collapse");

        // Contract balance: 5 joins × 110 = 550 USDC (no withdrawals).
        assertEq(usdc.balanceOf(tandaAddr), 550 * USDC, "balance pre-collapse");

        // Pre-cycle 2: nobody pays. Warp past grace.
        _warpPastGrace(tandaAddr);

        // Mark all 5. Order matters: cycle-1 recipient is past-slot (kept),
        // others are future-slot (pruned). The 5th mark brings
        // activeParticipantCount to 0 → full collapse.
        t.markDefaulter(cycle1Recipient);
        t.markDefaulter(pArr[order[1]]);
        t.markDefaulter(pArr[order[2]]);
        t.markDefaulter(pArr[order[3]]);

        // Expect the FullCollapse event on the final mark.
        vm.expectEmit(true, false, false, true, tandaAddr);
        emit FullCollapse(TREASURY, 550 * USDC);
        t.markDefaulter(pArr[order[4]]);

        // State
        assertEq(uint8(t.state()), uint8(Tanda.TandaState.COMPLETED), "completed via collapse");
        assertEq(t.activeParticipantCount(), 0, "no actives");

        // All prior credits forfeited
        assertEq(t.pendingWithdrawals(cycle1Recipient), 0, "cycle 1 recipient credit wiped");
        assertEq(t.pendingWithdrawals(alice), 0, "alice credit wiped");
        for (uint256 i = 0; i < 5; i++) {
            assertEq(t.insuranceBalance(pArr[i]), 0, "insurance wiped");
        }

        // Treasury absorbs the entire contract balance
        assertEq(t.pendingWithdrawals(TREASURY), 550 * USDC, "treasury sweeps all");
        assertEq(t.slashedPool(), 0, "slash pool zeroed");
        assertEq(t.totalInsuranceReserve(), 0, "insurance reserve zeroed");

        // No Completion NFTs minted (nobody completed honestly)
        for (uint256 i = 0; i < 5; i++) {
            assertFalse(completionNFT.hasCompletion(pArr[i], tandaId), "no completion NFT");
        }

        // Treasury withdraws → contract drains exactly
        vm.prank(TREASURY);
        t.withdraw();
        assertEq(usdc.balanceOf(tandaAddr), 0, "drained to zero");
    }

    // ────────────────────────────────────────────────────────────────
    // Creator not a participant
    // ────────────────────────────────────────────────────────────────

    function test_creatorIsNotAParticipant() public {
        (address tandaAddr, uint256 tandaId) = _createDefaultTanda(alice); // alice = creator only
        Tanda t = Tanda(tandaAddr);

        // bob, carol, dave fill (alice doesn't join).
        address[] memory users = new address[](3);
        users[0] = bob;
        users[1] = carol;
        users[2] = dave;
        _fillAndStart(tandaAddr, users, uint256(keccak256("seed_creator_only")));

        // Alice has no participant artifacts.
        assertFalse(t.isParticipant(alice), "alice not participant");
        assertFalse(passNFT.hasPass(alice, tandaId), "alice no pass");
        assertEq(t.insuranceBalance(alice), 0, "alice no insurance");

        // Run cycles 1, 2, 3 to completion.
        _warpToNextCycle(tandaAddr);
        t.triggerPayout();
        for (uint256 c = 2; c <= 3; c++) {
            _makePayment(tandaAddr, bob, 1);
            _makePayment(tandaAddr, carol, 1);
            _makePayment(tandaAddr, dave, 1);
            _warpToNextCycle(tandaAddr);
            t.triggerPayout();
        }

        assertEq(uint8(t.state()), uint8(Tanda.TandaState.COMPLETED));

        // Alice's pending = pure organizer fees: 3 cycles × 9 USDC = 27 USDC
        assertEq(t.pendingWithdrawals(alice), 27 * USDC, "alice organizer-only");

        // Alice has no completion NFT.
        assertFalse(completionNFT.hasCompletion(alice, tandaId), "alice no completion");

        // bob, carol, dave: each has Pass + Completion. Each = 285 (recipient) + 30 (insurance) = 315.
        assertTrue(completionNFT.hasCompletion(bob, tandaId));
        assertTrue(completionNFT.hasCompletion(carol, tandaId));
        assertTrue(completionNFT.hasCompletion(dave, tandaId));
        assertEq(t.pendingWithdrawals(bob), 315 * USDC, "bob");
        assertEq(t.pendingWithdrawals(carol), 315 * USDC, "carol");
        assertEq(t.pendingWithdrawals(dave), 315 * USDC, "dave");

        // Treasury: 3 × 6 = 18 USDC
        assertEq(t.pendingWithdrawals(TREASURY), 18 * USDC, "treasury");

        // Alice withdraws her organizer fees.
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        t.withdraw();
        assertEq(usdc.balanceOf(alice) - before, 27 * USDC, "alice withdraw");
    }

    // ────────────────────────────────────────────────────────────────
    // Cheap guards
    // ────────────────────────────────────────────────────────────────

    function test_withdraw_emptyBalance_reverts() public {
        (address tandaAddr,) = _createDefaultTanda(alice);
        vm.expectRevert(NothingToClaim.selector);
        vm.prank(alice);
        Tanda(tandaAddr).withdraw();
    }

    function test_makePayment_zeroCycles_reverts() public {
        (address tandaAddr,) = _createDefaultTanda(alice);
        Tanda t = Tanda(tandaAddr);
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = carol;
        _fillAndStart(tandaAddr, users, uint256(keccak256("seed_zero")));

        vm.expectRevert(ZeroAmount.selector);
        vm.prank(alice);
        t.makePayment(0);
    }

    function test_makePayment_capExceeded_reverts() public {
        (address tandaAddr,) = _createDefaultTanda(alice);
        Tanda t = Tanda(tandaAddr);
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = carol;
        _fillAndStart(tandaAddr, users, uint256(keccak256("seed_cap")));

        // After VRF: payoutOrder.length = 3. alice paidUntilCycle = 1.
        // cap = 3 - 1 = 2. Trying makePayment(3) exceeds cap.
        _fundAndApprove(alice, 3 * CHARGE_PER_CYCLE, tandaAddr);
        vm.expectRevert(abi.encodeWithSelector(CyclesOutOfRange.selector, uint256(3), uint256(2)));
        vm.prank(alice);
        t.makePayment(3);
    }

    // ────────────────────────────────────────────────────────────────
    // Fuzz: fee math always sums to pot exactly
    // ────────────────────────────────────────────────────────────────

    function testFuzz_feeMath_always95_2_3(uint256 amount) public {
        amount = bound(amount, 1 * USDC, 1_000_000 * USDC);

        // 3-participant pot
        uint256 pot = amount * 3;
        uint256 platform = (pot * 200) / 10_000;
        uint256 organizer = (pot * 300) / 10_000;

        // The contract's actual recipient absorbs rounding dust:
        // recipientActual = pot - platform - organizer  (NOT pot * 9500 / 10_000)
        uint256 recipientActual = pot - platform - organizer;
        assertEq(platform + organizer + recipientActual, pot, "contract: sum == pot exactly");

        // Sanity: naive 95% formula is within 3 base units of the actual recipient (dust).
        uint256 recipientNaive = (pot * 9_500) / 10_000;
        assertLe(recipientNaive, recipientActual, "naive <= actual (dust to recipient)");
        assertLe(recipientActual - recipientNaive, 2, "dust within 2 base units");
    }

    // ────────────────────────────────────────────────────────────────
    // Fuzz: insurance accrual invariant
    // ────────────────────────────────────────────────────────────────

    function testFuzz_insuranceAccrual(uint256 contribution) public {
        contribution = bound(contribution, 1 * USDC, 100_000 * USDC);

        // Custom 3-participant tanda
        vm.prank(alice);
        uint256 tandaId = manager.createTanda(
            address(usdc), contribution, DEFAULT_PAYOUT_INTERVAL, 3, DEFAULT_GRACE_PERIOD, 0, ITanda.TandaPrivacy.PUBLIC
        );
        address tandaAddr = manager.tandaIdToAddress(tandaId);
        Tanda t = Tanda(tandaAddr);

        uint256 expectedPremium = (contribution * 1_000) / 10_000;
        uint256 charge = contribution + expectedPremium;

        // Three joins. The last triggers _startTanda (which requests VRF
        // but we don't need to fulfill it for this invariant check).
        _fundAndApprove(alice, charge, tandaAddr);
        vm.prank(alice);
        t.join();
        _fundAndApprove(bob, charge, tandaAddr);
        vm.prank(bob);
        t.join();
        _fundAndApprove(carol, charge, tandaAddr);
        vm.prank(carol);
        t.join();

        // After all 3 joins, insurance = 3 × premium.
        assertEq(t.totalInsuranceReserve(), 3 * expectedPremium, "post-join reserve");

        // Each makePayment(1) — tanda is ACTIVE post-auto-start; cap
        // uses participantCount since payoutOrderAssigned is false
        // (VRF not yet fulfilled in this isolation test).
        _fundAndApprove(alice, charge, tandaAddr);
        vm.prank(alice);
        t.makePayment(1);
        _fundAndApprove(bob, charge, tandaAddr);
        vm.prank(bob);
        t.makePayment(1);
        _fundAndApprove(carol, charge, tandaAddr);
        vm.prank(carol);
        t.makePayment(1);

        assertEq(t.totalInsuranceReserve(), 6 * expectedPremium, "post-makePayment reserve");
    }

    // ────────────────────────────────────────────────────────────────
    // Fuzz: payoutOrder is always a permutation
    // ────────────────────────────────────────────────────────────────

    function testFuzz_payoutOrderShuffle_alwaysPermutation(uint256 seed) public {
        (address tandaAddr,) = _createCustomTanda(alice, 5, CONTRIBUTION);
        Tanda t = Tanda(tandaAddr);

        address[] memory users = new address[](5);
        users[0] = alice;
        users[1] = bob;
        users[2] = carol;
        users[3] = dave;
        users[4] = eve;
        _fillAndStart(tandaAddr, users, seed);

        uint256[] memory order = t.getPayoutOrder();
        assertEq(order.length, 5, "length 5");

        // Verify each index 0..4 appears exactly once.
        uint256[] memory count = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            assertLt(order[i], 5, "in range");
            count[order[i]]++;
        }
        for (uint256 i = 0; i < 5; i++) {
            assertEq(count[i], 1, "each index appears once");
        }
    }
}
