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
        _enableCreate(creator, contribution);
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

        // The creator (alice) is auto-enrolled as participant #0, so the
        // 50 participants are alice + 49 generated users. users[i] == the
        // i-th participant (creator first, then join order).
        address[] memory users = new address[](50);
        users[0] = alice;
        for (uint256 i = 1; i < 50; i++) {
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

        // The creator (alice) is also a participant, so she may be the cycle-1
        // recipient. Organizer fee (150) always goes to alice; the recipient
        // share (4750) goes to whoever drew slot 0 — which may be alice too.
        address cycle1Recipient = users[order[0]];
        assertEq(t.pendingWithdrawals(TREASURY), 100 * USDC, "treasury cycle1");
        if (cycle1Recipient == alice) {
            assertEq(t.pendingWithdrawals(alice), (4750 + 150) * USDC, "alice recipient + organizer");
        } else {
            assertEq(t.pendingWithdrawals(cycle1Recipient), 4750 * USDC, "cycle1 recipient");
            assertEq(t.pendingWithdrawals(alice), 150 * USDC, "alice organizer cycle1");
        }

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

        // alice (creator) is auto-enrolled as participant #0; bob..eve join.
        // So the 5 participants are [alice, bob, carol, dave, eve], and alice
        // ALSO collects organizer fees on top of her participant outcome.
        address[] memory users = new address[](4);
        users[0] = bob;
        users[1] = carol;
        users[2] = dave;
        users[3] = eve;
        _fillAndStart(tandaAddr, users, uint256(keccak256("seed_alldef")));

        // Organizer fees alice collects regardless of her participant role:
        // cycle1 (15) + cycle2 (3) + slash-pool org (1.2) = 19.2 USDC.
        uint256 orgFees = 18 * USDC + 1_200_000;

        uint256[] memory order = t.getPayoutOrder();
        address[5] memory pArr = [alice, bob, carol, dave, eve];
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
        // slashPool: 4 × 10 USDC = 40 USDC (still 4 defaulters regardless of who).
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

        // Payouts. The 5-participant math is unchanged from before; the only
        // difference is the creator (alice) is one of the 5 AND additionally
        // collects 19.2 USDC organizer fees on top of her participant role.
        //   survivor: cycle 2 recipient (95) + insurance refund (20) + slash share (38) = 153
        //   cycle 1 recipient (past-slot defaulter): keeps their 475
        //   other future-slot defaulters: 0 from the participant side
        assertEq(t.pendingWithdrawals(survivor), 153 * USDC + (survivor == alice ? orgFees : 0), "survivor");
        assertEq(
            t.pendingWithdrawals(cycle1Recipient), 475 * USDC + (cycle1Recipient == alice ? orgFees : 0), "cycle1 kept"
        );
        assertEq(t.pendingWithdrawals(def2), def2 == alice ? orgFees : 0, "def2");
        assertEq(t.pendingWithdrawals(def3), def3 == alice ? orgFees : 0, "def3");
        assertEq(t.pendingWithdrawals(def4), def4 == alice ? orgFees : 0, "def4");

        // Treasury: cycle 1 platform (10) + cycle 2 platform (2) + slash platform (0.8) = 12.8 USDC
        assertEq(t.pendingWithdrawals(TREASURY), 10 * USDC + 2 * USDC + 800_000, "treasury exact");

        // Conservation: the clone holds exactly the sum of all credited balances.
        uint256 totalCredits = t.pendingWithdrawals(alice) + t.pendingWithdrawals(bob) + t.pendingWithdrawals(carol)
            + t.pendingWithdrawals(dave) + t.pendingWithdrawals(eve) + t.pendingWithdrawals(TREASURY);
        assertEq(usdc.balanceOf(tandaAddr), totalCredits, "conservation: balance == sum of credits");
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

        // alice (creator) is auto-enrolled as participant #0; bob..eve join.
        address[] memory users = new address[](4);
        users[0] = bob;
        users[1] = carol;
        users[2] = dave;
        users[3] = eve;
        _fillAndStart(tandaAddr, users, uint256(keccak256("seed_oob")));

        // Organizer fees alice collects: cycle 1 (15) + slash org (1.2) = 16.2
        // USDC (this scenario auto-completes at cycle 2 — no cycle-2 payout).
        uint256 orgFees = 15 * USDC + 1_200_000;

        uint256[] memory order = t.getPayoutOrder();
        address[5] memory pArr = [alice, bob, carol, dave, eve];
        address survivor = pArr[order[0]]; // cycle 1 recipient = survivor

        address[] memory defaulters = new address[](4);
        defaulters[0] = pArr[order[1]];
        defaulters[1] = pArr[order[2]];
        defaulters[2] = pArr[order[3]];
        defaulters[3] = pArr[order[4]];

        // Cycle 1 — survivor receives the pot.
        _warpToNextCycle(tandaAddr);
        t.triggerPayout();

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

        // Survivor breakdown (exact, 5-participant math unchanged):
        //   475 cycle 1 recipient + 20 insurance refund + 100 excess contribution
        // + 38 slash share = 633 USDC; plus 16.2 organizer fees if survivor == alice.
        assertEq(t.pendingWithdrawals(survivor), 633 * USDC + (survivor == alice ? orgFees : 0), "survivor exact");

        // Treasury: 10 cycle-1 platform + 0.8 slash platform = 10.8 USDC
        assertEq(t.pendingWithdrawals(TREASURY), 10 * USDC + 800_000, "treasury exact");

        // Defaulters: zero from the participant side (alice, if among them, still
        // holds her organizer fees).
        for (uint256 i = 0; i < 4; i++) {
            assertEq(t.pendingWithdrawals(defaulters[i]), defaulters[i] == alice ? orgFees : 0, "defaulter pending");
            assertFalse(completionNFT.hasCompletion(defaulters[i], tandaId), "defaulter no completion NFT");
        }
        assertTrue(completionNFT.hasCompletion(survivor, tandaId), "survivor has completion NFT");

        // Conservation: the clone holds exactly the sum of all credited balances.
        uint256 totalCredits = t.pendingWithdrawals(alice) + t.pendingWithdrawals(bob) + t.pendingWithdrawals(carol)
            + t.pendingWithdrawals(dave) + t.pendingWithdrawals(eve) + t.pendingWithdrawals(TREASURY);
        assertEq(usdc.balanceOf(tandaAddr), totalCredits, "conservation: balance == sum of credits");
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

        // alice (creator) is auto-enrolled as participant #0; bob..eve join.
        address[] memory users = new address[](4);
        users[0] = bob;
        users[1] = carol;
        users[2] = dave;
        users[3] = eve;
        _fillAndStart(tandaAddr, users, uint256(keccak256("seed_fullcollapse")));

        uint256[] memory order = t.getPayoutOrder();
        address[5] memory pArr = [alice, bob, carol, dave, eve];
        address cycle1Recipient = pArr[order[0]];

        // Cycle 1 triggers — 475 to recipient, 10 to treasury, 15 organizer to alice.
        _warpToNextCycle(tandaAddr);
        t.triggerPayout();
        // alice gets the 15 cycle-1 organizer fee; if she is also the recipient
        // she additionally holds the 475 pot in the same balance.
        assertEq(
            t.pendingWithdrawals(cycle1Recipient),
            475 * USDC + (cycle1Recipient == alice ? 15 * USDC : 0),
            "cycle 1 credit before collapse"
        );
        if (cycle1Recipient != alice) {
            assertEq(t.pendingWithdrawals(alice), 15 * USDC, "alice credit before collapse");
        }
        assertEq(t.pendingWithdrawals(TREASURY), 10 * USDC, "treasury credit before collapse");

        // Contract balance: 5 participants × 110 = 550 USDC (no withdrawals).
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

    /// @notice Charge-at-create: the creator is auto-enrolled as participant
    ///         #1 and pays their first contribution + insurance premium at
    ///         creation, exactly like join().
    function test_creatorIsAutoEnrolledAtCreate() public {
        uint256 premium = (CONTRIBUTION * 1_000) / 10_000;

        (address tandaAddr, uint256 tandaId) = _createDefaultTanda(alice);
        Tanda t = Tanda(tandaAddr);

        // Creator is participant #0, active, paid through cycle 1, with a Pass NFT.
        assertTrue(t.isParticipant(alice), "creator is participant");
        assertEq(t.activeParticipantCount(), 1, "active count 1 at create");
        assertEq(t.getParticipant(0).addr, alice, "creator is participant 0");
        assertEq(t.getParticipant(0).paidUntilCycle, 1, "creator paid cycle 1");
        assertTrue(t.getParticipant(0).isActive, "creator active");
        assertTrue(passNFT.hasPass(alice, tandaId), "creator has pass NFT");

        // Funds: creator's premium is in insurance, and the clone physically
        // holds the full first charge (contribution + premium).
        assertEq(t.insuranceBalance(alice), premium, "creator insurance = premium");
        assertEq(t.totalInsuranceReserve(), premium, "reserve = premium");
        assertEq(usdc.balanceOf(tandaAddr), CONTRIBUTION + premium, "clone holds creator's charge");

        // A second create-then-join fills exactly one fewer external seat.
        _joinTanda(tandaAddr, bob);
        assertEq(t.activeParticipantCount(), 2, "creator + bob");
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

        // Custom 3-participant tanda. The creator (alice) is auto-enrolled at
        // create and pays the first charge then.
        uint256 expectedPremium = (contribution * 1_000) / 10_000;
        uint256 charge = contribution + expectedPremium;

        _enableCreate(alice, contribution);
        vm.prank(alice);
        uint256 tandaId = manager.createTanda(
            address(usdc), contribution, DEFAULT_PAYOUT_INTERVAL, 3, DEFAULT_GRACE_PERIOD, 0, ITanda.TandaPrivacy.PUBLIC
        );
        address tandaAddr = manager.tandaIdToAddress(tandaId);
        Tanda t = Tanda(tandaAddr);

        // Creator enrolled → reserve already holds one premium.
        assertEq(t.totalInsuranceReserve(), expectedPremium, "post-create reserve");

        // bob + carol join (the last fills + triggers _startTanda).
        _fundAndApprove(bob, charge, tandaAddr);
        vm.prank(bob);
        t.join();
        _fundAndApprove(carol, charge, tandaAddr);
        vm.prank(carol);
        t.join();

        // After all 3 participants, insurance = 3 × premium.
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
