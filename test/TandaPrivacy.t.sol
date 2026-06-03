// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {MitandaTestBase} from "./helpers/MitandaTestBase.sol";
import {Tanda} from "../src/Tanda.sol";
import {ITanda} from "../src/interfaces/ITanda.sol";
import {ERC1271Wallet} from "./mocks/ERC1271Wallet.sol";
import {
    NotPublicTanda,
    NotPrivateTanda,
    InviteExpired,
    InviteSignerNotCreator,
    TicketAlreadyUsed,
    InviteAlreadyRevoked,
    NotCreator,
    ScheduledStartTooSoon,
    ScheduledStartNotReached,
    TandaNotFull
} from "../src/MitandaErrors.sol";

/// @title  TandaPrivacyTest
/// @notice Privacy modes (PUBLIC / PRIVATE_TICKETED), EIP-712 invite
///         tickets (sign / verify / replay / expire / revoke), and the
///         scheduled-start mechanics (auto-start vs delayed start).
contract TandaPrivacyTest is MitandaTestBase {
    // ─── Convenience constants ─────────────────────────────────────────
    uint256 internal constant USDC = 10 ** 6;
    uint256 internal constant CONTRIBUTION = 100 * USDC;
    uint256 internal constant CHARGE_PER_CYCLE = 110 * USDC;

    // ─── Signing identity ──────────────────────────────────────────────
    uint256 internal constant CREATOR_PK = 0xA11CE;
    uint256 internal constant ATTACKER_PK = 0xBAD;
    address internal signingCreator;

    // ─── Event redeclarations (for vm.expectEmit) ──────────────────────
    event ParticipantJoinedViaInvite(address indexed participant, uint256 timestamp, uint256 deadline);
    event InviteRevoked(address indexed invitee, uint256 deadline);

    function setUp() public override {
        super.setUp();
        signingCreator = vm.addr(CREATOR_PK);
        // Warp to a sensible non-zero baseline so "past" deadlines are well-defined.
        vm.warp(1_000_000);
    }

    // ────────────────────────────────────────────────────────────────
    // Tanda factories
    // ────────────────────────────────────────────────────────────────

    function _createPrivateTanda() internal returns (address tandaAddr, uint256 tandaId) {
        _enableCreate(signingCreator, CONTRIBUTION);
        vm.prank(signingCreator);
        tandaId = manager.createTanda(
            address(usdc),
            CONTRIBUTION,
            DEFAULT_PAYOUT_INTERVAL,
            DEFAULT_PARTICIPANT_COUNT,
            DEFAULT_GRACE_PERIOD,
            0,
            ITanda.TandaPrivacy.PRIVATE_TICKETED
        );
        tandaAddr = manager.tandaIdToAddress(tandaId);
    }

    function _createScheduledPublic(uint256 schedStart) internal returns (address tandaAddr, uint256 tandaId) {
        _enableCreate(alice, CONTRIBUTION);
        vm.prank(alice);
        tandaId = manager.createTanda(
            address(usdc),
            CONTRIBUTION,
            DEFAULT_PAYOUT_INTERVAL,
            DEFAULT_PARTICIPANT_COUNT,
            DEFAULT_GRACE_PERIOD,
            schedStart,
            ITanda.TandaPrivacy.PUBLIC
        );
        tandaAddr = manager.tandaIdToAddress(tandaId);
    }

    // ────────────────────────────────────────────────────────────────
    // EIP-712 signing
    // ────────────────────────────────────────────────────────────────

    /// @dev Reconstructs the contract's digest and signs as the creator.
    ///      Signature encoding is `r || s || v` to match OZ's ECDSA.recover.
    function _signInvite(address tandaAddr, address invitee, uint256 deadline, uint256 pk)
        internal
        view
        returns (bytes memory signature)
    {
        Tanda t = Tanda(tandaAddr);
        bytes32 typehash = t.inviteTypehash();
        uint256 tid = t.tandaId();
        bytes32 structHash = keccak256(abi.encode(typehash, invitee, tid, deadline));
        bytes32 domainSep = t.domainSeparatorV4();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        signature = abi.encodePacked(r, s, v);
    }

    function _joinPrivate(address tandaAddr, address invitee, uint256 deadline) internal {
        bytes memory sig = _signInvite(tandaAddr, invitee, deadline, CREATOR_PK);
        Tanda t = Tanda(tandaAddr);
        uint256 c = t.contributionAmount();
        uint256 premium = (c * t.INSURANCE_BPS()) / t.BPS_DENOMINATOR();
        _fundAndApprove(invitee, c + premium, tandaAddr);
        vm.prank(invitee);
        t.joinWithInvite(deadline, sig);
    }

    // ────────────────────────────────────────────────────────────────
    // Scenario 1: PUBLIC mode
    // ────────────────────────────────────────────────────────────────

    function test_publicTanda_joinSucceeds_joinWithInviteReverts() public {
        (address tandaAddr,) = _createDefaultTanda(alice); // base default is PUBLIC
        Tanda t = Tanda(tandaAddr);

        // Plain join works. Creator (alice) is auto-enrolled at create, so
        // after bob joins the active count is 2.
        _joinTanda(tandaAddr, bob);
        assertEq(t.activeParticipantCount(), 2, "alice (creator) + bob");
        assertTrue(t.isParticipant(bob), "bob is participant");

        // joinWithInvite reverts NotPrivateTanda. Signature can be empty —
        // the privacy check fires before any signature processing.
        vm.expectRevert(NotPrivateTanda.selector);
        vm.prank(carol);
        t.joinWithInvite(block.timestamp + 1 hours, "");
    }

    // ────────────────────────────────────────────────────────────────
    // Scenario 2: PRIVATE mode — join reverts, joinWithInvite succeeds
    // ────────────────────────────────────────────────────────────────

    function test_privateTanda_joinReverts_joinWithInviteSucceeds() public {
        (address tandaAddr, uint256 tandaId) = _createPrivateTanda();
        Tanda t = Tanda(tandaAddr);

        // Plain join reverts NotPublicTanda.
        vm.expectRevert(NotPublicTanda.selector);
        vm.prank(alice);
        t.join();

        // Valid invite for alice — sign + fund up front so the next
        // external call we make is the joinWithInvite itself (so that
        // vm.expectEmit captures the right call).
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signInvite(tandaAddr, alice, deadline, CREATOR_PK);
        _fundAndApprove(alice, CHARGE_PER_CYCLE, tandaAddr);

        // Set up expectEmit IMMEDIATELY before the call we're checking.
        vm.expectEmit(true, false, false, true, tandaAddr);
        emit ParticipantJoinedViaInvite(alice, block.timestamp, deadline);

        vm.prank(alice);
        t.joinWithInvite(deadline, sig);

        assertTrue(t.isParticipant(alice), "alice is participant");
        // Creator (signingCreator) is auto-enrolled as participant #0, alice
        // joins via invite as #1, so the active count is 2.
        assertEq(t.activeParticipantCount(), 2, "creator + alice");
        assertEq(t.getParticipant(1).paidUntilCycle, 1, "alice paidUntilCycle");
        assertTrue(passNFT.hasPass(alice, tandaId), "alice has pass NFT");
    }

    // ────────────────────────────────────────────────────────────────
    // Scenario 2b: SMART-ACCOUNT (ERC-1271) creator — invite validates
    // (Before the SignatureChecker change this reverted InviteSignerNotCreator.)
    // ────────────────────────────────────────────────────────────────

    uint256 internal constant SMART_OWNER_PK = 0x5A11;

    function _createPrivateTandaBy(address creator) internal returns (address tandaAddr, uint256 tandaId) {
        _enableCreate(creator, CONTRIBUTION);
        vm.prank(creator);
        tandaId = manager.createTanda(
            address(usdc),
            CONTRIBUTION,
            DEFAULT_PAYOUT_INTERVAL,
            DEFAULT_PARTICIPANT_COUNT,
            DEFAULT_GRACE_PERIOD,
            0,
            ITanda.TandaPrivacy.PRIVATE_TICKETED
        );
        tandaAddr = manager.tandaIdToAddress(tandaId);
    }

    function test_invite_smartAccountCreator_joinWithInviteSucceeds() public {
        // The tanda creator is a deployed ERC-1271 smart-contract wallet.
        ERC1271Wallet wallet = new ERC1271Wallet(vm.addr(SMART_OWNER_PK));
        (address tandaAddr,) = _createPrivateTandaBy(address(wallet));
        Tanda t = Tanda(tandaAddr);
        assertEq(t.creator(), address(wallet), "creator is the smart-contract wallet");

        // The wallet's owner signs the EIP-712 digest; the contract validates it
        // via ERC-1271 (isValidSignature). SignatureChecker accepts it.
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signInvite(tandaAddr, alice, deadline, SMART_OWNER_PK);
        _fundAndApprove(alice, CHARGE_PER_CYCLE, tandaAddr);

        vm.expectEmit(true, false, false, true, tandaAddr);
        emit ParticipantJoinedViaInvite(alice, block.timestamp, deadline);

        vm.prank(alice);
        t.joinWithInvite(deadline, sig);

        assertTrue(t.isParticipant(alice), "alice joined via smart-account invite");
        // Smart-account creator is auto-enrolled as #0, alice joins via invite
        // as #1, so the active count is 2.
        assertEq(t.activeParticipantCount(), 2, "creator wallet + alice");
        assertTrue(t.isParticipant(address(wallet)), "creator wallet enrolled at create");
    }

    function test_invite_smartAccountCreator_wrongOwner_reverts() public {
        ERC1271Wallet wallet = new ERC1271Wallet(vm.addr(SMART_OWNER_PK));
        (address tandaAddr,) = _createPrivateTandaBy(address(wallet));
        Tanda t = Tanda(tandaAddr);

        // A key that is NOT the wallet's owner signs — ERC-1271 returns invalid.
        uint256 deadline = block.timestamp + 1 days;
        bytes memory badSig = _signInvite(tandaAddr, alice, deadline, ATTACKER_PK);
        _fundAndApprove(alice, CHARGE_PER_CYCLE, tandaAddr);

        vm.expectRevert(InviteSignerNotCreator.selector);
        vm.prank(alice);
        t.joinWithInvite(deadline, badSig);
    }

    // ────────────────────────────────────────────────────────────────
    // Scenario 3: invalid signer reverts
    // ────────────────────────────────────────────────────────────────

    function test_invite_invalidSigner_reverts() public {
        (address tandaAddr,) = _createPrivateTanda();
        Tanda t = Tanda(tandaAddr);

        uint256 deadline = block.timestamp + 1 days;
        bytes memory badSig = _signInvite(tandaAddr, alice, deadline, ATTACKER_PK);

        // Fund alice so the revert isn't shadowed by allowance issues.
        _fundAndApprove(alice, CHARGE_PER_CYCLE, tandaAddr);

        vm.expectRevert(InviteSignerNotCreator.selector);
        vm.prank(alice);
        t.joinWithInvite(deadline, badSig);
    }

    // ────────────────────────────────────────────────────────────────
    // Scenario 4: replay protection — second redemption hits TicketAlreadyUsed
    // ────────────────────────────────────────────────────────────────

    function test_invite_replayProtection() public {
        (address tandaAddr,) = _createPrivateTanda();
        Tanda t = Tanda(tandaAddr);

        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signInvite(tandaAddr, alice, deadline, CREATOR_PK);

        // First redemption succeeds.
        _fundAndApprove(alice, CHARGE_PER_CYCLE, tandaAddr);
        vm.prank(alice);
        t.joinWithInvite(deadline, sig);
        assertTrue(t.isParticipant(alice), "alice joined");

        // Second redemption with the same (invitee, tandaId, deadline) +
        // signature: ticket lookup fires before _joinInternal's AlreadyJoined.
        // Re-fund + re-approve so the revert isn't shadowed by allowance issues.
        _fundAndApprove(alice, CHARGE_PER_CYCLE, tandaAddr);
        vm.expectRevert(TicketAlreadyUsed.selector);
        vm.prank(alice);
        t.joinWithInvite(deadline, sig);
    }

    // ────────────────────────────────────────────────────────────────
    // Scenario 5: expired deadline
    // ────────────────────────────────────────────────────────────────

    function test_invite_expiredDeadline_reverts() public {
        (address tandaAddr,) = _createPrivateTanda();
        Tanda t = Tanda(tandaAddr);

        uint256 deadline = block.timestamp; // valid right now
        bytes memory sig = _signInvite(tandaAddr, alice, deadline, CREATOR_PK);

        // Warp +1 so block.timestamp > deadline.
        vm.warp(block.timestamp + 1);

        _fundAndApprove(alice, CHARGE_PER_CYCLE, tandaAddr);
        vm.expectRevert(abi.encodeWithSelector(InviteExpired.selector, block.timestamp, deadline));
        vm.prank(alice);
        t.joinWithInvite(deadline, sig);
    }

    // ────────────────────────────────────────────────────────────────
    // Scenario 6: revocation + deadline-specific revoke
    // ────────────────────────────────────────────────────────────────

    function test_invite_revocation() public {
        (address tandaAddr,) = _createPrivateTanda();
        Tanda t = Tanda(tandaAddr);

        uint256 deadline1 = block.timestamp + 1 days;
        uint256 deadline2 = block.timestamp + 2 days;
        bytes memory sig1 = _signInvite(tandaAddr, alice, deadline1, CREATOR_PK);
        bytes memory sig2 = _signInvite(tandaAddr, alice, deadline2, CREATOR_PK);

        // Creator revokes the deadline-1 invite — InviteRevoked event fires.
        vm.expectEmit(true, false, false, true, tandaAddr);
        emit InviteRevoked(alice, deadline1);
        vm.prank(signingCreator);
        t.revokeInvite(alice, deadline1);

        // alice cannot redeem the deadline-1 invite — reverts InviteAlreadyRevoked.
        _fundAndApprove(alice, CHARGE_PER_CYCLE, tandaAddr);
        vm.expectRevert(InviteAlreadyRevoked.selector);
        vm.prank(alice);
        t.joinWithInvite(deadline1, sig1);

        // The deadline-2 invite is still valid — revocation is deadline-specific.
        _fundAndApprove(alice, CHARGE_PER_CYCLE, tandaAddr);
        vm.prank(alice);
        t.joinWithInvite(deadline2, sig2);
        assertTrue(t.isParticipant(alice), "alice joined via deadline-2 invite");
    }

    // ────────────────────────────────────────────────────────────────
    // Scenario 7: revokeInvite caller guard
    // ────────────────────────────────────────────────────────────────

    function test_revokeInvite_onlyCreator() public {
        (address tandaAddr,) = _createPrivateTanda();
        Tanda t = Tanda(tandaAddr);

        uint256 deadline = block.timestamp + 1 days;

        vm.expectRevert(NotCreator.selector);
        vm.prank(bob);
        t.revokeInvite(alice, deadline);
    }

    // ────────────────────────────────────────────────────────────────
    // Scenario 8: scheduled start blocks auto-start until time arrives
    // ────────────────────────────────────────────────────────────────

    function test_scheduledStart_autoStartBlockedUntilTime() public {
        uint256 schedStart = block.timestamp + 3 days;
        (address tandaAddr,) = _createScheduledPublic(schedStart);
        Tanda t = Tanda(tandaAddr);

        // Fill manually — auto-start should NOT fire.
        _joinTanda(tandaAddr, alice);
        _joinTanda(tandaAddr, bob);
        _joinTanda(tandaAddr, carol);

        assertEq(uint8(t.state()), uint8(Tanda.TandaState.OPEN), "state still OPEN after fill");
        assertFalse(t.payoutOrderAssigned(), "no payout order yet");
        assertEq(t.currentCycle(), 0, "currentCycle still 0");

        // start() before scheduledStart reverts ScheduledStartNotReached.
        vm.expectRevert(abi.encodeWithSelector(ScheduledStartNotReached.selector, block.timestamp, schedStart));
        t.start();

        // Warp to scheduledStart. start() succeeds, VRF fires.
        vm.warp(schedStart);
        vm.recordLogs();
        t.start();
        _captureAndFulfillVRF(uint256(keccak256("seed_sched")));

        assertEq(uint8(t.state()), uint8(Tanda.TandaState.ACTIVE), "state ACTIVE after start");
        assertTrue(t.payoutOrderAssigned(), "payout order assigned");
    }

    // ────────────────────────────────────────────────────────────────
    // Scenario 9: scheduled start too soon (< 1 day) reverts at creation
    // ────────────────────────────────────────────────────────────────

    function test_scheduledStart_tooSoonReverts() public {
        uint256 schedStart = block.timestamp + 1 hours; // < 1 day
        uint256 earliest = block.timestamp + 1 days;

        vm.expectRevert(abi.encodeWithSelector(ScheduledStartTooSoon.selector, schedStart, earliest));
        vm.prank(alice);
        manager.createTanda(
            address(usdc),
            CONTRIBUTION,
            DEFAULT_PAYOUT_INTERVAL,
            DEFAULT_PARTICIPANT_COUNT,
            DEFAULT_GRACE_PERIOD,
            schedStart,
            ITanda.TandaPrivacy.PUBLIC
        );
    }

    // ────────────────────────────────────────────────────────────────
    // Scenario 10: scheduledStart == 0 auto-starts on last join
    // ────────────────────────────────────────────────────────────────

    function test_scheduledStart_zeroAutoStartsWhenFull() public {
        (address tandaAddr,) = _createDefaultTanda(alice); // schedStart = 0 in default
        Tanda t = Tanda(tandaAddr);

        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = carol;
        _fillAndStart(tandaAddr, users, uint256(keccak256("seed_zero_sched")));

        // _fillAndStart already requires the auto-start path to fire (it
        // captures + fulfills the VRF that the last join triggers).
        assertEq(uint8(t.state()), uint8(Tanda.TandaState.ACTIVE), "auto-started");
        assertTrue(t.payoutOrderAssigned(), "payout order assigned");
        assertEq(t.activeParticipantCount(), 3, "all 3 in");
    }

    // ────────────────────────────────────────────────────────────────
    // Scenario 11: start() reverts when not full
    // ────────────────────────────────────────────────────────────────

    function test_start_revertsWhenNotFull() public {
        // Use a scheduled tanda so start() is the intended trigger.
        (address tandaAddr,) = _createScheduledPublic(block.timestamp + 1 days);
        Tanda t = Tanda(tandaAddr);

        // Only 2 of 3 join.
        _joinTanda(tandaAddr, alice);
        _joinTanda(tandaAddr, bob);
        assertEq(t.activeParticipantCount(), 2, "two joined");

        // Warp to scheduledStart so timing isn't the blocker.
        vm.warp(block.timestamp + 1 days);

        vm.expectRevert(TandaNotFull.selector);
        t.start();
    }
}
