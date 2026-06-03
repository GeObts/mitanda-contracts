// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {ITanda} from "./interfaces/ITanda.sol";
import "./MitandaErrors.sol";

/// @notice Minimum slice of `TandaManager` that a Tanda needs to read at
///         runtime. We intentionally do NOT import the concrete
///         `TandaManager` to avoid coupling the build order; the
///         interface stays right here in the Tanda file because it is
///         only used here.
/// @dev    Fee basis points and the insurance bps are mirrored as
///         constants on `Tanda` itself (see `PLATFORM_FEE_BPS` etc.)
///         to avoid external calls per payout and to keep stack
///         pressure manageable. The deploy script MUST verify that
///         Manager's and Tanda's constants agree before going live.
interface ITandaManager {
    function treasury() external view returns (address);
    function requestRandomnessForTanda(uint256 tandaId) external;
}

/// @notice Soulbound Pass NFT entry points the Tanda calls on join /
///         defaulter mark. Singleton; address snapshotted at init.
interface IMitandaPassNFT {
    function mint(address participant, uint256 tandaId) external returns (uint256);
    function markDefaulted(address participant, uint256 tandaId) external;
}

/// @notice Transferable Receipt NFT entry point used on each cycle
///         payout. Singleton; address snapshotted at init.
interface IMitandaReceiptNFT {
    function mintReceipt(address recipient, uint256 tandaId, uint256 cycle, uint256 collectionId)
        external
        returns (uint256);
}

/// @notice Soulbound Completion NFT entry point used at tanda
///         completion. Singleton; address snapshotted at init.
interface IMitandaCompletionNFT {
    function batchMint(address[] calldata participants, uint256 tandaId) external returns (uint256[] memory);
}

/// @title  Tanda
/// @author Mi Tanda
/// @notice Per-tanda state machine. **EIP-1167 implementation contract**:
///         deployed once per chain, then cloned by `TandaManager.createTanda`
///         and initialized via `initialize(InitParams)`. Holds the
///         contributions, executes the cycle payouts, enforces defaulter
///         timing, and credits all outflows via the pull-payment pattern.
/// @dev    Uses OZ v5 upgradeable variants `Initializable`,
///         `ReentrancyGuardUpgradeable`, `EIP712Upgradeable` (from the
///         openzeppelin-contracts-upgradeable package). The upgradeable
///         variants use ERC-7201 namespaced storage, leaving slot 0+
///         entirely free for `Tanda`'s own state. `EIP712Upgradeable`
///         is required (vs. the non-upgradeable `EIP712`) because the
///         non-upgradeable version sets `_HASHED_NAME` and
///         `_HASHED_VERSION` as immutables in its constructor, which
///         never runs for clones, breaking signature verification.
///
///         **Insurance model (real-funds slash pool):** every contribution
///         is paired with a 10% insurance premium (`INSURANCE_BPS`).
///         Premiums accumulate in `insuranceBalance[participant]` and the
///         running `totalInsuranceReserve`. On default, the defaulter's
///         insurance moves to `slashedPool` (physical funds, not
///         notional). On completion, every still-active participant's
///         insurance is refunded to their `pendingWithdrawals`, then
///         `slashedPool` is split 95% / 2% / 3% across active
///         participants, treasury, and creator. The 95% slash share is
///         the honest-participant reward for staying paid up.
///
///         **Scheduled start:** a tanda may optionally specify a
///         `scheduledStart` timestamp at init. If `scheduledStart == 0`
///         the tanda auto-starts when the last seat fills. Otherwise,
///         filling the seats keeps the tanda OPEN until
///         `block.timestamp >= scheduledStart`, at which point anyone
///         can call `start()`. `scheduledStart` (when nonzero) must be
///         at least `block.timestamp + 1 days` at creation time —
///         enforced by `TandaManager.createTanda`.
///
///         **Privacy modes:** `PUBLIC` tandas accept any caller via
///         `join()`. `PRIVATE_TICKETED` tandas only accept callers
///         holding a creator-signed EIP-712 invite via
///         `joinWithInvite(deadline, signature)`. Tickets are keyed by
///         `(invitee, tandaId, deadline)`, single-use, and revocable by
///         the creator via `revokeInvite`.
///
///         **Cycle accounting invariants** (subtle — refer back here when
///         reading the code in three months):
///
///         - `participantCount` is set once in `initialize` and never
///           changes. It is the original seat count.
///         - `activeParticipantCount` starts at 0, increments on each
///           `join`, and decrements on each `markDefaulter`. It is the
///           count of participants still in good standing — NOT the
///           number of cycles remaining.
///         - `payoutOrder.length` starts at `participantCount` when the
///           VRF callback populates it via `assignPayoutOrder`. It
///           decreases by 1 each time a future-slot defaulter is pruned
///           by `_removeFromPayoutOrder`; past-slot defaulters
///           (defaulters who already received their pot before
///           defaulting) keep their slot, so `payoutOrder.length` may
///           exceed `activeParticipantCount`.
///         - **`payoutOrder.length` is the source of truth for total
///           cycles the tanda will run.** Not `participantCount`, not
///           `activeParticipantCount`.
///         - `currentCycle > payoutOrder.length` is the completion
///           trigger inside `triggerPayout`.
///         - `makePayment` cap = `payoutOrder.length - paidUntilCycle`
///           after VRF, or `participantCount - paidUntilCycle` before
///           VRF (clamped to ≥0 if defaulter pruning has dropped
///           `payoutOrder.length` below a pre-paid participant's
///           `paidUntilCycle`).
///         - Per-cycle pot at `triggerPayout` =
///           `contributionAmount * activeParticipantCount`. The pot
///           shrinks as defaulters are marked.
contract Tanda is ITanda, Initializable, ReentrancyGuardUpgradeable, EIP712Upgradeable {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────
    // Constants — mirror of `TandaManager` fee + insurance config
    // (must be kept in lockstep with Manager; deploy script verifies all four)
    // ─────────────────────────────────────────────────────────────────────

    uint16 public constant PLATFORM_FEE_BPS = 200; // 2%
    uint16 public constant ORGANIZER_FEE_BPS = 300; // 3%
    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant INSURANCE_BPS = 1_000; // 10% — per-cycle premium

    /// @notice EIP-712 typehash for an Invite struct. Domain is set via
    ///         `__EIP712_init("MiTanda", "1")` in `initialize`; the
    ///         domain separator therefore includes `chainId` and this
    ///         clone's address — so an invite signed for tanda A on
    ///         chain X cannot be replayed on tanda B or chain Y.
    bytes32 private constant INVITE_TYPEHASH = keccak256("Invite(address invitee,uint256 tandaId,uint256 deadline)");

    // ─────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────

    enum TandaState {
        OPEN, // accepting joins
        ACTIVE, // running cycles
        COMPLETED // all scheduled cycles paid, slash pool distributed
    }

    struct Participant {
        address addr;
        uint256 paidUntilCycle; // last cycle they have paid for (incl. join)
        bool isActive; // false once marked defaulter
        uint256 joinTimestamp;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Storage — set in initialize()
    // ─────────────────────────────────────────────────────────────────────

    uint256 public tandaId;
    address public token;
    uint256 public contributionAmount;
    uint256 public payoutInterval;
    uint16 public participantCount;
    uint256 public gracePeriod;
    address public manager;
    address public creator;

    /// @notice Snapshot of `TandaManager.activeCollectionId` at the moment
    ///         this clone was initialized. Permanent for the lifetime of
    ///         this tanda. `0` means the tanda was created during a
    ///         no-sponsor (go-dark) period; receipt mints will fall back
    ///         to `MitandaReceiptNFT.defaultFallbackBaseURI`.
    uint256 public sponsoredCollectionId;

    /// @notice Earliest block timestamp at which the tanda may transition
    ///         to ACTIVE. `0` means "start immediately when full".
    uint256 public scheduledStart;

    /// @notice Membership policy. PUBLIC accepts `join()` from any
    ///         address; PRIVATE_TICKETED only accepts `joinWithInvite`
    ///         calls backed by a creator-signed EIP-712 invite.
    TandaPrivacy public privacy;

    /// @notice Singleton NFT contracts wired by the Manager at clone
    ///         init. Stored as regular slots (not immutable — clones
    ///         can't have immutables). Set once in `initialize` and
    ///         never reassigned. NFT calls are unconditional: if any
    ///         of these is zero or misconfigured, every lifecycle
    ///         action that touches the NFT will revert — the intended
    ///         failure mode.
    address public passNFT;
    address public receiptNFT;
    address public completionNFT;

    // ─────────────────────────────────────────────────────────────────────
    // Storage — lifecycle state
    // ─────────────────────────────────────────────────────────────────────

    TandaState public state;
    uint256 public startTimestamp;

    /// @notice Current cycle index, 1-based. Starts at 1 when state
    ///         transitions to ACTIVE. Incremented after each payout.
    ///         When `currentCycle > payoutOrder.length` the tanda
    ///         transitions to COMPLETED.
    uint256 public currentCycle;

    /// @notice Count of participants still in good standing. Decremented
    ///         on `markDefaulter`. NOT the source of truth for total
    ///         cycles — `payoutOrder.length` is, since past-defaulter
    ///         slots (defaulters who already received their pot) are
    ///         kept in `payoutOrder` to preserve historical cycle-index
    ///         mappings, so `payoutOrder.length` may exceed
    ///         `activeParticipantCount` after a past-paid defaulter is
    ///         marked.
    uint16 public activeParticipantCount;

    Participant[] public participants;

    /// @notice address → `index + 1` into `participants`. Zero means
    ///         "not a participant".
    mapping(address => uint256) public addressToParticipantIndex;

    bool public payoutOrderAssigned;

    /// @notice Pre-shuffled list of participant indices in payout order.
    ///         `payoutOrder[k-1]` is the recipient slot for cycle `k`.
    uint256[] public payoutOrder;

    // ─────────────────────────────────────────────────────────────────────
    // Storage — pull-payment ledger
    // ─────────────────────────────────────────────────────────────────────

    mapping(address => uint256) public pendingWithdrawals;
    uint256 public totalPendingCredits;

    /// @notice Pool of forfeited insurance from defaulters. Distributed
    ///         95% / 2% / 3% at completion. Physical funds.
    uint256 public slashedPool;

    // ─────────────────────────────────────────────────────────────────────
    // Storage — insurance reserve
    // ─────────────────────────────────────────────────────────────────────

    mapping(address => uint256) public insuranceBalance;
    uint256 public totalInsuranceReserve;

    // ─────────────────────────────────────────────────────────────────────
    // Storage — invite tickets (PRIVATE_TICKETED only)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Ticket fingerprint (`keccak256(invitee, tandaId, deadline)`)
    ///         → whether it has been redeemed by a `joinWithInvite` call.
    mapping(bytes32 => bool) public usedTickets;

    /// @notice Ticket fingerprint → whether the creator revoked the invite
    ///         before redemption.
    mapping(bytes32 => bool) public revokedTickets;

    // ─────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────

    event ParticipantJoined(address indexed participant, uint256 timestamp);
    event ParticipantJoinedViaInvite(address indexed participant, uint256 timestamp, uint256 deadline);
    event InviteRevoked(address indexed invitee, uint256 deadline);
    event PaymentMade(address indexed participant, uint256 cyclesPaid, uint256 amount, uint256 timestamp);
    event TandaStarted(uint256 startTimestamp);
    event PayoutOrderAssigned(uint256[] order, uint256 timestamp);
    event PayoutCredited(
        address indexed recipient,
        address indexed treasury,
        address indexed creator,
        uint256 recipientAmount,
        uint256 treasuryAmount,
        uint256 creatorAmount,
        uint256 cycle,
        uint256 timestamp
    );
    event ParticipantDefaulted(
        address indexed participant, uint256 cycle, uint256 forfeitedInsurance, uint256 timestamp
    );
    event InsuranceRefunded(address indexed participant, uint256 amount);
    event ContributionExcessRefunded(address indexed participant, uint256 excessCycles, uint256 amount);
    event SlashPoolDistributed(
        uint256 totalPool, uint256 perActiveParticipant, uint256 treasuryShare, uint256 creatorShare, uint256 dust
    );
    event TandaCompleted(uint256 completionTimestamp);
    /// @notice Emitted when a tanda completes via full collapse — every
    ///         participant defaulted, no honest survivors. The treasury
    ///         absorbs the entire remaining token balance; all prior
    ///         pendingWithdrawals and insurance balances are forfeited.
    event FullCollapse(address indexed treasury, uint256 amount);
    event Withdrawn(address indexed claimant, uint256 amount);

    // ─────────────────────────────────────────────────────────────────────
    // Constructor — implementation only
    // ─────────────────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ─────────────────────────────────────────────────────────────────────
    // Initializer
    // ─────────────────────────────────────────────────────────────────────

    /// @notice One-shot initializer called by `TandaManager.createTanda`
    ///         immediately after cloning. Sets per-clone parameters,
    ///         initializes `ReentrancyGuardUpgradeable`, and sets up
    ///         the EIP-712 domain ("MiTanda", "1").
    /// @dev    Manager already validates parameter ranges + scheduled-
    ///         start lead time before calling; the checks here are
    ///         defense-in-depth, focused on "non-zero" invariants we
    ///         cannot recover from later.
    function initialize(InitParams calldata params) external override initializer {
        if (params.token == address(0)) revert ZeroAddress();
        if (params.manager == address(0)) revert ZeroAddress();
        if (params.creator == address(0)) revert ZeroAddress();
        if (params.contributionAmount == 0) revert ZeroAmount();
        if (params.passNFT == address(0)) revert ZeroAddress();
        if (params.receiptNFT == address(0)) revert ZeroAddress();
        if (params.completionNFT == address(0)) revert ZeroAddress();

        __ReentrancyGuard_init();
        __EIP712_init("MiTanda", "1");

        tandaId = params.tandaId;
        token = params.token;
        contributionAmount = params.contributionAmount;
        payoutInterval = params.payoutInterval;
        participantCount = params.participantCount;
        gracePeriod = params.gracePeriod;
        manager = params.manager;
        creator = params.creator;
        sponsoredCollectionId = params.sponsoredCollectionId;
        scheduledStart = params.scheduledStart;
        privacy = params.privacy;
        passNFT = params.passNFT;
        receiptNFT = params.receiptNFT;
        completionNFT = params.completionNFT;

        state = TandaState.OPEN;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────

    modifier onlyManager() {
        if (msg.sender != manager) revert CallerNotManager();
        _;
    }

    modifier onlyParticipant() {
        uint256 idxPlus1 = addressToParticipantIndex[msg.sender];
        if (idxPlus1 == 0) revert NotParticipant();
        if (!participants[idxPlus1 - 1].isActive) revert DefaultedParticipant();
        _;
    }

    modifier onlyInState(TandaState expected) {
        if (state != expected) revert WrongTandaState(uint8(expected), uint8(state));
        _;
    }

    // ─────────────────────────────────────────────────────────────────────
    // User: join (PUBLIC tandas)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Reserve a seat in a PUBLIC tanda by paying the first
    ///         contribution + insurance premium. The contribution counts
    ///         as cycle 1's payment; `paidUntilCycle` is set to 1.
    /// @dev    Reverts if the tanda is PRIVATE_TICKETED — callers must
    ///         use `joinWithInvite` instead. When the last seat fills,
    ///         the tanda auto-starts (transitions to ACTIVE and requests
    ///         VRF randomness) IF `scheduledStart == 0` or
    ///         `block.timestamp >= scheduledStart`. Otherwise the tanda
    ///         stays OPEN; anyone can call `start()` after the scheduled
    ///         time.
    /// @custom:reverts WrongTandaState  if not OPEN.
    /// @custom:reverts NotPublicTanda   if privacy is PRIVATE_TICKETED.
    /// @custom:reverts TandaFull        if all seats are filled.
    /// @custom:reverts AlreadyJoined    if caller is already a participant.
    /// @custom:emits   ParticipantJoined.
    /// @custom:emits   TandaStarted (if this join triggers auto-start).
    function join() external nonReentrant onlyInState(TandaState.OPEN) {
        if (privacy != TandaPrivacy.PUBLIC) revert NotPublicTanda();
        _joinInternal(msg.sender);
    }

    // ─────────────────────────────────────────────────────────────────────
    // User: joinWithInvite (PRIVATE_TICKETED tandas)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Redeem a creator-signed EIP-712 invite to join a
    ///         PRIVATE_TICKETED tanda.
    /// @dev    The signature must be over the typed struct
    ///         `Invite(address invitee, uint256 tandaId, uint256 deadline)`
    ///         with `invitee == msg.sender`. The EIP-712 domain is
    ///         `("MiTanda", "1", chainId, address(this))` — so an invite
    ///         is bound to a specific tanda clone on a specific chain.
    ///         Tickets are keyed by `keccak256(msg.sender, tandaId,
    ///         deadline)`; each is single-use and may be pre-revoked by
    ///         the creator via `revokeInvite`.
    /// @param deadline  Latest `block.timestamp` at which this invite is
    ///                  still redeemable.
    /// @param signature Creator's signature over the EIP-712 typed-data
    ///                  digest. Validated via SignatureChecker, so either a
    ///                  65-byte EOA ECDSA signature or an ERC-1271
    ///                  smart-account signature is accepted.
    /// @custom:reverts WrongTandaState         if not OPEN.
    /// @custom:reverts NotPrivateTanda         if privacy is PUBLIC.
    /// @custom:reverts InviteExpired           if `block.timestamp > deadline`.
    /// @custom:reverts TicketAlreadyUsed       if already redeemed.
    /// @custom:reverts InviteAlreadyRevoked    if the creator revoked it.
    /// @custom:reverts InviteSignerNotCreator  if the recovered signer is not the creator.
    /// @custom:reverts TandaFull               if all seats are filled.
    /// @custom:reverts AlreadyJoined           if caller is already a participant.
    /// @custom:emits   ParticipantJoined.
    /// @custom:emits   ParticipantJoinedViaInvite.
    function joinWithInvite(uint256 deadline, bytes calldata signature)
        external
        nonReentrant
        onlyInState(TandaState.OPEN)
    {
        if (privacy != TandaPrivacy.PRIVATE_TICKETED) revert NotPrivateTanda();
        if (block.timestamp > deadline) revert InviteExpired(block.timestamp, deadline);

        bytes32 ticket = keccak256(abi.encode(msg.sender, tandaId, deadline));
        if (usedTickets[ticket]) revert TicketAlreadyUsed();
        if (revokedTickets[ticket]) revert InviteAlreadyRevoked();

        bytes32 structHash = keccak256(abi.encode(INVITE_TYPEHASH, msg.sender, tandaId, deadline));
        bytes32 digest = _hashTypedDataV4(structHash);
        // SignatureChecker validates both EOA (ECDSA) and ERC-1271 smart-account
        // signatures, so smart-account creators (e.g. Privy) can issue invites.
        // The creator's account is always deployed by redeem time (they sent the
        // createTanda tx), so plain ERC-1271 is sufficient — no ERC-6492 needed.
        if (!SignatureChecker.isValidSignatureNow(creator, digest, signature)) {
            revert InviteSignerNotCreator();
        }

        // Mark used BEFORE joining (CEI: state writes before external call
        // in _joinInternal's safeTransferFrom).
        usedTickets[ticket] = true;

        _joinInternal(msg.sender);

        emit ParticipantJoinedViaInvite(msg.sender, block.timestamp, deadline);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Internal: shared join logic
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Common path for both `join` and `joinWithInvite`. NOT
    ///      `nonReentrant` itself — that guard is on the public entry
    ///      points so legitimate internal composition isn't blocked.
    function _joinInternal(address participant) internal {
        if (activeParticipantCount >= participantCount) revert TandaFull();
        if (addressToParticipantIndex[participant] != 0) revert AlreadyJoined();

        uint256 premium = _premiumPerCycle();
        uint256 chargeAmount = contributionAmount + premium;

        participants.push(
            Participant({addr: participant, paidUntilCycle: 1, isActive: true, joinTimestamp: block.timestamp})
        );
        addressToParticipantIndex[participant] = participants.length;
        activeParticipantCount++;

        insuranceBalance[participant] += premium;
        totalInsuranceReserve += premium;

        emit ParticipantJoined(participant, block.timestamp);

        // Soulbound EIP-5192 Pass NFT — minted BEFORE the token transfer
        // so the NFT existence tracks join-attempt, not transfer-success.
        // If the safeTransferFrom below reverts, the whole tx (incl. this
        // mint) rolls back atomically.
        IMitandaPassNFT(passNFT).mint(participant, tandaId);

        IERC20(token).safeTransferFrom(participant, address(this), chargeAmount);

        // Auto-start when seats fill — IF either auto-start is enabled
        // (`scheduledStart == 0`) or the scheduled time has arrived.
        if (activeParticipantCount == participantCount) {
            if (scheduledStart == 0 || block.timestamp >= scheduledStart) {
                _startTanda();
            }
        }
    }

    /// @dev Per-cycle insurance premium derived from `contributionAmount`
    ///      and `INSURANCE_BPS`. Integer division — for very small
    ///      `contributionAmount` the premium may be zero.
    function _premiumPerCycle() internal view returns (uint256) {
        return (contributionAmount * INSURANCE_BPS) / BPS_DENOMINATOR;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Manager: enrollCreator (charge-at-create)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Enroll the creator as the first participant at creation.
    /// @dev    Called exactly once by `TandaManager.createTanda`, AFTER the
    ///         Manager has already pulled the creator's first contribution +
    ///         insurance premium into this clone (the creator approves the
    ///         Manager, not the not-yet-deployed clone). So this mirrors
    ///         `_joinInternal` EXACTLY except:
    ///           - it does NOT `safeTransferFrom` (the Manager funded the
    ///             clone), and
    ///           - it never auto-starts (a single participant can never fill
    ///             a tanda — `participantCount` is always >= 2).
    ///         `paidUntilCycle = 1` (cycle 1 covered) and the premium lands
    ///         in `insuranceBalance`, identical to a normal join.
    /// @custom:reverts CallerNotManager if not called by the Manager.
    /// @custom:reverts WrongTandaState  if not OPEN.
    /// @custom:reverts NotCreator       if `creator_` is not the recorded creator.
    /// @custom:reverts AlreadyJoined    if the creator is already enrolled.
    /// @custom:emits   ParticipantJoined.
    function enrollCreator(address creator_) external override onlyManager onlyInState(TandaState.OPEN) {
        if (creator_ != creator) revert NotCreator();
        if (addressToParticipantIndex[creator_] != 0) revert AlreadyJoined();

        uint256 premium = _premiumPerCycle();

        participants.push(
            Participant({addr: creator_, paidUntilCycle: 1, isActive: true, joinTimestamp: block.timestamp})
        );
        addressToParticipantIndex[creator_] = participants.length;
        activeParticipantCount++;

        insuranceBalance[creator_] += premium;
        totalInsuranceReserve += premium;

        emit ParticipantJoined(creator_, block.timestamp);

        // Soulbound Pass NFT. The clone is already registered in the Manager
        // (registration precedes initialize in createTanda), so onlyTanda passes.
        IMitandaPassNFT(passNFT).mint(creator_, tandaId);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Permissionless: start() — scheduled-start trigger
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Start a tanda that filled its seats before its
    ///         `scheduledStart` deadline. Permissionless.
    /// @dev    No-op for `scheduledStart == 0` tandas (those auto-start
    ///         in `_joinInternal` when the last seat fills). For
    ///         `scheduledStart > 0`, callable once both:
    ///           - all seats are filled (`activeParticipantCount == participantCount`)
    ///           - `block.timestamp >= scheduledStart`
    ///         A pause on `TandaManager` will indirectly block this by
    ///         causing the subsequent `requestRandomnessForTanda` call
    ///         to revert.
    /// @custom:reverts WrongTandaState           if not OPEN.
    /// @custom:reverts TandaNotFull              if seats not full yet.
    /// @custom:reverts ScheduledStartNotReached  if before scheduled start.
    /// @custom:emits   TandaStarted.
    function start() external nonReentrant onlyInState(TandaState.OPEN) {
        if (activeParticipantCount < participantCount) revert TandaNotFull();
        if (scheduledStart > 0 && block.timestamp < scheduledStart) {
            revert ScheduledStartNotReached(block.timestamp, scheduledStart);
        }
        _startTanda();
    }

    function _startTanda() internal {
        state = TandaState.ACTIVE;
        startTimestamp = block.timestamp;
        currentCycle = 1;

        emit TandaStarted(block.timestamp);

        ITandaManager(manager).requestRandomnessForTanda(tandaId);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Creator: revokeInvite
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Revoke a previously-issued invite ticket. Only callable
    ///         by the creator. The ticket fingerprint is computed
    ///         exactly as `joinWithInvite` would — so an invite can be
    ///         revoked even if the signature is not yet on-chain.
    /// @dev    No state-machine check; revocation may happen at any time
    ///         and is harmless after the tanda has started (since
    ///         `joinWithInvite` already reverts on non-OPEN states).
    /// @param invitee   Address named in the original invite.
    /// @param deadline  Deadline named in the original invite.
    /// @custom:reverts NotCreator if `msg.sender != creator`.
    /// @custom:emits   InviteRevoked.
    function revokeInvite(address invitee, uint256 deadline) external {
        if (msg.sender != creator) revert NotCreator();
        bytes32 ticket = keccak256(abi.encode(invitee, tandaId, deadline));
        revokedTickets[ticket] = true;
        emit InviteRevoked(invitee, deadline);
    }

    // ─────────────────────────────────────────────────────────────────────
    // User: makePayment
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Pay contribution + insurance premium for one or more
    ///         upcoming cycles. A participant may pay 1 cycle ahead
    ///         (typical) or multiple cycles ahead (pre-fund).
    /// @dev    The cap is `totalCycles - paidUntilCycle` where
    ///         `totalCycles` = `payoutOrder.length` (after VRF) or
    ///         `participantCount` (before VRF). When defaulters prune
    ///         future slots, the cap shrinks. Pre-paid excess (if any)
    ///         is refunded at completion via `_refundActiveParticipants`.
    ///
    ///         Each cycle paid charges `contributionAmount + premium`
    ///         where `premium = contributionAmount * INSURANCE_BPS /
    ///         BPS_DENOMINATOR`. The base flows to that cycle's pot at
    ///         `triggerPayout` time; the premium accumulates in
    ///         `insuranceBalance[msg.sender]`.
    /// @custom:reverts WrongTandaState   if not ACTIVE.
    /// @custom:reverts NotParticipant    if caller never joined or has been marked defaulter.
    /// @custom:reverts ZeroAmount        if `cyclesToPay == 0`.
    /// @custom:reverts CyclesOutOfRange  if requested exceeds the remaining cycle cap.
    /// @custom:emits   PaymentMade — `amount` includes contribution + premium.
    function makePayment(uint256 cyclesToPay) external nonReentrant onlyInState(TandaState.ACTIVE) onlyParticipant {
        if (cyclesToPay == 0) revert ZeroAmount();

        Participant storage p = participants[addressToParticipantIndex[msg.sender] - 1];

        uint256 totalCycles = payoutOrderAssigned ? payoutOrder.length : participantCount;
        uint256 cap = totalCycles > p.paidUntilCycle ? totalCycles - p.paidUntilCycle : 0;
        if (cyclesToPay > cap) revert CyclesOutOfRange(cyclesToPay, cap);

        uint256 premium = _premiumPerCycle();
        uint256 contributionTotal = contributionAmount * cyclesToPay;
        uint256 premiumTotal = premium * cyclesToPay;
        uint256 chargeTotal = contributionTotal + premiumTotal;

        p.paidUntilCycle += cyclesToPay;
        insuranceBalance[msg.sender] += premiumTotal;
        totalInsuranceReserve += premiumTotal;

        IERC20(token).safeTransferFrom(msg.sender, address(this), chargeTotal);

        emit PaymentMade(msg.sender, cyclesToPay, chargeTotal, block.timestamp);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Permissionless: markDefaulter
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Permissionlessly mark a participant as defaulted on the
    ///         current cycle. Anyone may call.
    /// @dev    On success: `participant.isActive = false`,
    ///         `activeParticipantCount--`, their accumulated insurance
    ///         is moved to `slashedPool`, and (if their slot in
    ///         `payoutOrder` is still pending) it is removed via O(n)
    ///         left-shift.
    /// @dev    If pruning drives `payoutOrder.length < currentCycle`
    ///         (no remaining cycles can pay out), the tanda
    ///         auto-completes in the same transaction via
    ///         `_completeTanda`. With surviving actives, normal
    ///         completion runs; with zero actives, full collapse
    ///         sweeps the entire token balance to treasury
    ///         (`FullCollapse` event). Defensive: the
    ///         `payoutOrderAssigned` guard prevents auto-completion
    ///         in the (unreachable in practice) window before the
    ///         VRF callback assigns the payout order.
    /// @custom:reverts WrongTandaState           if not ACTIVE.
    /// @custom:reverts NotParticipant            if `participant` isn't in the tanda.
    /// @custom:reverts AlreadyMarkedDefaulter    if already inactive.
    /// @custom:reverts NotDefaulter              if `paidUntilCycle >= currentCycle`.
    /// @custom:reverts GracePeriodNotExpired     if called before deadline + grace.
    /// @custom:emits   ParticipantDefaulted, plus TandaCompleted or FullCollapse if auto-completion fires.
    function markDefaulter(address participant) external nonReentrant onlyInState(TandaState.ACTIVE) {
        uint256 idxPlus1 = addressToParticipantIndex[participant];
        if (idxPlus1 == 0) revert NotParticipant();
        uint256 idx = idxPlus1 - 1;

        Participant storage p = participants[idx];
        if (!p.isActive) revert AlreadyMarkedDefaulter(participant);
        if (p.paidUntilCycle >= currentCycle) revert NotDefaulter(participant);

        uint256 expiresAt = startTimestamp + currentCycle * payoutInterval + gracePeriod;
        if (block.timestamp <= expiresAt) revert GracePeriodNotExpired(block.timestamp, expiresAt);

        p.isActive = false;
        activeParticipantCount--;

        uint256 forfeitedInsurance = insuranceBalance[participant];
        if (forfeitedInsurance > 0) {
            insuranceBalance[participant] = 0;
            totalInsuranceReserve -= forfeitedInsurance;
            slashedPool += forfeitedInsurance;
        }

        if (payoutOrderAssigned) {
            _removeFromPayoutOrder(idx);
        }

        emit ParticipantDefaulted(participant, currentCycle, forfeitedInsurance, block.timestamp);

        // Pass NFT flag last: if it fails (it shouldn't — the Pass NFT's
        // `markDefaulted` is a silent no-op when the pass doesn't exist),
        // Tanda's own `isActive = false` state has already been written
        // and the event emitted. The pass NFT itself stays soulbound on
        // the participant as reputation evidence; only its `isDefaulted`
        // flag flips.
        IMitandaPassNFT(passNFT).markDefaulted(participant, tandaId);

        // Auto-complete: pruning may have driven `payoutOrder.length`
        // below `currentCycle`, meaning no payouts remain. Without this,
        // the next `triggerPayout` would access `payoutOrder[currentCycle-1]`
        // out of bounds and the tanda would be stuck in ACTIVE forever.
        // The `payoutOrderAssigned` clause prevents auto-completion in
        // the (in-practice unreachable) window before VRF callback fires.
        if (payoutOrderAssigned && payoutOrder.length < currentCycle) {
            _completeTanda();
        }
    }

    /// @dev Remove `participantIndex` from `payoutOrder` IF its slot is
    ///      at or after `currentCycle`. Past slots stay.
    function _removeFromPayoutOrder(uint256 participantIndex) internal {
        uint256 len = payoutOrder.length;
        for (uint256 i = currentCycle - 1; i < len; i++) {
            if (payoutOrder[i] == participantIndex) {
                for (uint256 j = i; j < len - 1; j++) {
                    payoutOrder[j] = payoutOrder[j + 1];
                }
                payoutOrder.pop();
                return;
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Permissionless: triggerPayout
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Settle the current cycle: credit recipient (95%),
    ///         treasury (2%), creator (3%). Permissionless once payout
    ///         time has arrived and all active participants have paid up.
    /// @dev    Reverts with `DefaultersOutstanding` if any active hasn't
    ///         paid this cycle. Cure: `markDefaulter(...)` once grace
    ///         expires, then re-call.
    function triggerPayout() external nonReentrant onlyInState(TandaState.ACTIVE) {
        if (!payoutOrderAssigned) revert PayoutOrderNotAssigned();

        uint256 readyAt = startTimestamp + currentCycle * payoutInterval;
        if (block.timestamp < readyAt) revert PayoutNotReady(block.timestamp, readyAt);

        if (!_allActiveParticipantsPaid()) revert DefaultersOutstanding();

        uint256 cyclePaid = currentCycle;
        address recipient = participants[payoutOrder[cyclePaid - 1]].addr;
        address treasuryAddr = ITandaManager(manager).treasury();

        uint256 pot = contributionAmount * activeParticipantCount;
        uint256 platformAmount = (pot * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
        uint256 organizerAmount = (pot * ORGANIZER_FEE_BPS) / BPS_DENOMINATOR;
        uint256 recipientAmount = pot - platformAmount - organizerAmount;

        currentCycle = cyclePaid + 1;
        _settleCyclePayout(recipient, treasuryAddr, recipientAmount, platformAmount, organizerAmount, cyclePaid);

        // Receipt NFT mint with frozen-at-mint baseURI + ERC-2981 royalty.
        // `cyclePaid` is the cycle that just paid out (NOT the new
        // `currentCycle`). `sponsoredCollectionId` may be 0 — Receipt
        // NFT handles go-dark via its default fallback URI.
        IMitandaReceiptNFT(receiptNFT).mintReceipt(recipient, tandaId, cyclePaid, sponsoredCollectionId);

        if (currentCycle > payoutOrder.length) {
            _completeTanda();
        }
    }

    function _settleCyclePayout(
        address recipient,
        address treasuryAddr,
        uint256 recipientAmount,
        uint256 platformAmount,
        uint256 organizerAmount,
        uint256 cyclePaid
    ) internal {
        _credit(recipient, recipientAmount);
        _credit(treasuryAddr, platformAmount);
        _credit(creator, organizerAmount);

        emit PayoutCredited(
            recipient,
            treasuryAddr,
            creator,
            recipientAmount,
            platformAmount,
            organizerAmount,
            cyclePaid,
            block.timestamp
        );
    }

    function _allActiveParticipantsPaid() internal view returns (bool) {
        uint256 len = participants.length;
        for (uint256 i = 0; i < len; i++) {
            Participant storage p = participants[i];
            if (p.isActive && p.paidUntilCycle < currentCycle) return false;
        }
        return true;
    }

    /// @dev Two completion paths:
    ///      1. Normal (`activeParticipantCount > 0`): refund insurance
    ///         and excess contributions to actives, distribute slash
    ///         pool 95/2/3, mint Completion NFTs.
    ///      2. Full collapse (`activeParticipantCount == 0`): every
    ///         participant defaulted. Existing pendingWithdrawals and
    ///         insurance balances are forfeited; the entire token
    ///         balance sweeps to treasury. No Completion NFTs minted.
    function _completeTanda() internal {
        if (activeParticipantCount == 0) {
            _fullCollapse();
            return;
        }

        state = TandaState.COMPLETED;
        _refundActiveParticipants();
        if (slashedPool > 0) {
            _distributeSlashPool();
        }
        emit TandaCompleted(block.timestamp);

        // Completion NFTs minted LAST so all financial state is final
        // before badges are issued. Build the active-participants array
        // by scanning `participants` once and collecting `isActive`
        // addresses. `activeParticipantCount == 0` produces an empty
        // array, which `MitandaCompletionNFT.batchMint` handles as a
        // no-op — no defensive branching needed here.
        uint256 activeCount = activeParticipantCount;
        address[] memory actives = new address[](activeCount);
        uint256 outIdx = 0;
        uint256 len = participants.length;
        for (uint256 i = 0; i < len; i++) {
            if (participants[i].isActive) {
                actives[outIdx] = participants[i].addr;
                outIdx++;
            }
        }
        IMitandaCompletionNFT(completionNFT).batchMint(actives, tandaId);
    }

    /// @dev Full-collapse settlement: every participant defaulted.
    ///      Platform is lender-of-last-resort — the entire token
    ///      balance (including any pendingWithdrawals that were
    ///      credited but never withdrawn) sweeps to treasury. All
    ///      prior credits and insurance balances are zeroed.
    function _fullCollapse() internal {
        address treasuryAddr = ITandaManager(manager).treasury();

        // Zero every per-address credit and insurance balance — full
        // collapse forfeits every existing claim. The token balance
        // is the only thing that matters; credits are rebuilt from it.
        uint256 n = participants.length;
        for (uint256 i = 0; i < n; i++) {
            address p = participants[i].addr;
            delete pendingWithdrawals[p];
            delete insuranceBalance[p];
        }
        delete pendingWithdrawals[creator];
        delete pendingWithdrawals[treasuryAddr];

        // Sweep entire token balance to treasury.
        uint256 sweepable = IERC20(token).balanceOf(address(this));
        pendingWithdrawals[treasuryAddr] = sweepable;
        totalPendingCredits = sweepable;

        slashedPool = 0;
        totalInsuranceReserve = 0;

        state = TandaState.COMPLETED;

        emit FullCollapse(treasuryAddr, sweepable);
        // No Completion NFTs minted — by definition nobody completed honestly.
    }

    /// @dev Refund each active participant's insurance balance + any
    ///      contribution paid for cycles that didn't run.
    function _refundActiveParticipants() internal {
        uint256 totalCyclesRun = payoutOrder.length;
        uint256 len = participants.length;
        for (uint256 i = 0; i < len; i++) {
            Participant storage p = participants[i];
            if (!p.isActive) continue;

            uint256 ins = insuranceBalance[p.addr];
            if (ins > 0) {
                insuranceBalance[p.addr] = 0;
                totalInsuranceReserve -= ins;
                _credit(p.addr, ins);
                emit InsuranceRefunded(p.addr, ins);
            }

            if (p.paidUntilCycle > totalCyclesRun) {
                uint256 excessCycles = p.paidUntilCycle - totalCyclesRun;
                uint256 excessAmount = excessCycles * contributionAmount;
                _credit(p.addr, excessAmount);
                emit ContributionExcessRefunded(p.addr, excessCycles, excessAmount);
            }
        }
    }

    /// @dev Distribute the slashed pool 95% / 2% / 3% at completion.
    ///      Pool is physically backed by forfeited insurance.
    function _distributeSlashPool() internal {
        uint256 pool = slashedPool;
        slashedPool = 0;

        uint256 needed = totalPendingCredits + pool;
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < needed) revert InsufficientContractBalance(needed, balance);

        address treasuryAddr = ITandaManager(manager).treasury();
        uint256 platformShare = (pool * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
        uint256 organizerShare = (pool * ORGANIZER_FEE_BPS) / BPS_DENOMINATOR;
        uint256 recipientPool = pool - platformShare - organizerShare;

        uint256 perActive = recipientPool / activeParticipantCount;
        uint256 dust = recipientPool - (perActive * activeParticipantCount);

        _credit(treasuryAddr, platformShare + dust);
        _credit(creator, organizerShare);

        uint256 len = participants.length;
        for (uint256 i = 0; i < len; i++) {
            if (participants[i].isActive) {
                _credit(participants[i].addr, perActive);
            }
        }

        emit SlashPoolDistributed(pool, perActive, platformShare + dust, organizerShare, dust);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Manager → Tanda: VRF callback
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Receive a VRF-resolved random seed and derive payout
    ///         order via Fisher–Yates shuffle.
    /// @custom:reverts CallerNotManager             if `msg.sender != manager`.
    /// @custom:reverts WrongTandaState              if not ACTIVE.
    /// @custom:reverts PayoutOrderAlreadyAssigned   if already shuffled.
    /// @custom:emits   PayoutOrderAssigned.
    function assignPayoutOrder(uint256 randomSeed) external override onlyManager onlyInState(TandaState.ACTIVE) {
        if (payoutOrderAssigned) revert PayoutOrderAlreadyAssigned();

        uint256 n = participantCount;
        payoutOrder = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            payoutOrder[i] = i;
        }

        for (uint256 i = n - 1; i > 0; i--) {
            uint256 j = uint256(keccak256(abi.encode(randomSeed, i))) % (i + 1);
            (payoutOrder[i], payoutOrder[j]) = (payoutOrder[j], payoutOrder[i]);
        }

        payoutOrderAssigned = true;
        emit PayoutOrderAssigned(payoutOrder, block.timestamp);
    }

    // ─────────────────────────────────────────────────────────────────────
    // User: withdraw (pull-payment claim)
    // ─────────────────────────────────────────────────────────────────────

    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToClaim();

        pendingWithdrawals[msg.sender] = 0;
        totalPendingCredits -= amount;

        IERC20(token).safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    function _credit(address to, uint256 amount) internal {
        if (amount == 0) return;
        pendingWithdrawals[to] += amount;
        totalPendingCredits += amount;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────

    function getParticipantCount() external view returns (uint256) {
        return participants.length;
    }

    function getParticipant(uint256 index) external view returns (Participant memory) {
        return participants[index];
    }

    function getAllParticipants() external view returns (Participant[] memory) {
        return participants;
    }

    function isParticipant(address account) external view returns (bool) {
        return addressToParticipantIndex[account] != 0;
    }

    function isActiveParticipant(address account) external view returns (bool) {
        uint256 idxPlus1 = addressToParticipantIndex[account];
        if (idxPlus1 == 0) return false;
        return participants[idxPlus1 - 1].isActive;
    }

    function getPayoutOrder() external view returns (uint256[] memory) {
        if (!payoutOrderAssigned) revert PayoutOrderNotAssigned();
        return payoutOrder;
    }

    /// @notice Returns the contract's token balance and the sum of all
    ///         outstanding claims. `balance - outstanding` equals the
    ///         current cycle's in-flight contributions.
    function getAccountingSnapshot()
        external
        view
        returns (
            uint256 balance,
            uint256 outstanding,
            uint256 pendingCredits,
            uint256 slashPool,
            uint256 insuranceReserve
        )
    {
        balance = IERC20(token).balanceOf(address(this));
        pendingCredits = totalPendingCredits;
        slashPool = slashedPool;
        insuranceReserve = totalInsuranceReserve;
        outstanding = pendingCredits + slashPool + insuranceReserve;
    }

    /// @notice Domain separator for EIP-712 invite signatures. Each
    ///         clone has its own separator (includes `address(this)`).
    function domainSeparatorV4() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice The EIP-712 typehash for an Invite. Exposed for frontends
    ///         that want to sanity-check the struct layout matches.
    function inviteTypehash() external pure returns (bytes32) {
        return INVITE_TYPEHASH;
    }
}
