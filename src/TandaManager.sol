// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

import {ITanda} from "./interfaces/ITanda.sol";
import "./MitandaErrors.sol";

/// @title  TandaManager
/// @author Mi Tanda
/// @notice Singleton orchestrator for the Mi Tanda system. Holds the
///         token allowlist, the sponsored-collection registry, the
///         Chainlink VRF v2.5 configuration, the treasury address, and
///         the rolling factory of per-tanda EIP-1167 clones.
/// @dev    Inherits `VRFConsumerBaseV2Plus` (which inherits Chainlink's
///         `ConfirmedOwner` — that is the source of `onlyOwner` and
///         the two-step ownership transfer used throughout this file).
///         Inherits `Pausable` from OZ v5 to gate user-facing state
///         transitions during incident response. VRF callbacks
///         intentionally bypass the pause guard so randomness already
///         requested before a pause still lands.
contract TandaManager is VRFConsumerBaseV2Plus, Pausable {
    // ─────────────────────────────────────────────────────────────────────
    // Constants — fees, basis points, parameter ranges
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Platform fee in basis points (2%). Deducted on every payout.
    uint16 public constant PLATFORM_FEE_BPS = 200;

    /// @notice Organizer fee in basis points (3%). Paid to the tanda creator.
    uint16 public constant ORGANIZER_FEE_BPS = 300;

    /// @notice Sum of platform + organizer fees (500 bps = 5%). Recipient
    ///         receives the remaining 9_500 bps (95%).
    uint16 public constant TOTAL_FEE_BPS = 500;

    /// @notice Basis-point denominator. `bps / BPS_DENOMINATOR` = ratio.
    uint16 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Hard cap on sponsor royalty basis points (1_000 bps = 10%).
    uint96 public constant MAX_ROYALTY_BPS = 1_000;

    /// @notice Per-cycle insurance premium in basis points (10%). The
    ///         premium is charged on top of every contribution and held
    ///         in `Tanda.insuranceBalance` per participant. On default,
    ///         the defaulter's accumulated insurance moves to the slash
    ///         pool; on completion, active participants get their own
    ///         insurance refunded plus a pro-rata share of the slash
    ///         pool (95% / 2% / 3% split).
    /// @dev    MUST match `Tanda.INSURANCE_BPS`. The deploy script
    ///         verifies equality before going live.
    uint16 public constant INSURANCE_BPS = 1_000; // 10%

    /// @notice Minimum payout interval (1 day).
    uint256 public constant MIN_PAYOUT_INTERVAL = 1 days;

    /// @notice Maximum payout interval (30 days).
    uint256 public constant MAX_PAYOUT_INTERVAL = 30 days;

    /// @notice Minimum number of participants per tanda.
    uint16 public constant MIN_PARTICIPANT_COUNT = 2;

    /// @notice Maximum number of participants per tanda.
    uint16 public constant MAX_PARTICIPANT_COUNT = 50;

    /// @notice Minimum grace period (1 day).
    uint256 public constant MIN_GRACE_PERIOD = 1 days;

    /// @notice Maximum grace period (7 days).
    uint256 public constant MAX_GRACE_PERIOD = 7 days;

    // ─────────────────────────────────────────────────────────────────────
    // Immutables
    // ─────────────────────────────────────────────────────────────────────

    /// @notice EIP-1167 implementation address that all per-tanda clones
    ///         delegate to. Deployed once per chain; cannot be changed.
    address public immutable tandaImplementation;

    /// @notice Soulbound Pass NFT contract. Auto-minted on `join` /
    ///         `joinWithInvite` and flagged on `markDefaulter`.
    ///         Immutable — set once at Manager deployment.
    address public immutable passNFT;

    /// @notice Transferable Receipt NFT contract. Minted on each
    ///         payout to the cycle's recipient with frozen-at-mint
    ///         sponsored-collection metadata. Immutable.
    address public immutable receiptNFT;

    /// @notice Soulbound Completion NFT contract. Batch-minted at
    ///         tanda completion to every still-active participant.
    ///         Immutable.
    address public immutable completionNFT;

    // ─────────────────────────────────────────────────────────────────────
    // Storage — treasury
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Platform treasury. Receives the 2% platform fee on every
    ///         payout. Owner-configurable via `setTreasury`.
    address public treasury;

    // ─────────────────────────────────────────────────────────────────────
    // Storage — token allowlist
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Token addresses approved for use as a tanda's contribution
    ///         currency. Managed by owner via `allowlistToken` /
    ///         `delistToken`.
    mapping(address => bool) public isAllowedToken;

    /// @notice Ordered list of currently-allowlisted tokens. Kept in
    ///         lockstep with `isAllowedToken` to enable enumeration
    ///         (e.g. for frontend display). Add is O(1) push; remove
    ///         is O(n) swap-and-pop. Owner-only entry points, so cost
    ///         is acceptable.
    address[] private allowedTokensList;

    // ─────────────────────────────────────────────────────────────────────
    // Storage — Tanda registry
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Next tanda ID to assign. IDs are monotonic and start at 1
    ///         (0 reserved as "unset" / "not a tanda").
    uint256 public nextTandaId;

    /// @notice Tanda ID -> deployed clone address.
    mapping(uint256 => address) public tandaIdToAddress;

    /// @notice Deployed clone address -> Tanda ID. Returns 0 for any
    ///         address that has never been created by this manager.
    mapping(address => uint256) public addressToTandaId;

    // ─────────────────────────────────────────────────────────────────────
    // Storage — sponsored collection registry
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Metadata for a sponsored NFT collection. Each new tanda
    ///         snapshots the currently-active `collectionId` at
    ///         construction time and references this entry for its
    ///         receipt mints (via the frozen-at-mint pattern in
    ///         `MitandaReceiptNFT`).
    struct SponsoredCollection {
        string name; // e.g. "Mi Tanda Genesis", "Bitso x Mi Tanda"
        string baseURI; // ipfs:// or https:// folder
        address royaltyReceiver; // artist or sponsor brand wallet
        uint96 royaltyBps; // out of 10_000; e.g. 500 = 5%
        uint256 activatedAt; // timestamp of registration
        bool exists;
    }

    /// @notice Registry of sponsored collections, keyed by collection ID.
    mapping(uint256 => SponsoredCollection) public collections;

    /// @notice Next collection ID to assign. IDs are monotonic and start
    ///         at 1; ID 0 is reserved as "unset" (no active sponsor).
    uint256 public nextCollectionId;

    /// @notice Currently-active sponsored collection. Newly-created
    ///         tandas snapshot this value. `0` means no active sponsor
    ///         ("go-dark" mode); receipts minted by such tandas use the
    ///         Receipt NFT's default fallback URI.
    uint256 public activeCollectionId;

    // ─────────────────────────────────────────────────────────────────────
    // Storage — VRF v2.5 config
    // ─────────────────────────────────────────────────────────────────────

    uint256 private subscriptionId;
    bytes32 private gasLane;
    uint32 private callbackGasLimit;
    uint16 private requestConfirmations;
    uint32 private numWords;
    bool private nativePayment;

    /// @notice VRF request ID -> originating Tanda ID. Populated when the
    ///         Manager requests randomness on behalf of a Tanda; consumed
    ///         in `fulfillRandomWords` to route the seed back.
    mapping(uint256 => uint256) public vrfRequestIdToTandaId;

    // ─────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────

    /// @notice A new Tanda clone has been created and initialized.
    event TandaCreated(
        uint256 indexed tandaId,
        address indexed tandaAddress,
        address indexed creator,
        address token,
        uint256 contributionAmount,
        uint256 payoutInterval,
        uint16 participantCount,
        uint256 gracePeriod,
        uint256 sponsoredCollectionId,
        uint256 scheduledStart,
        ITanda.TandaPrivacy privacy
    );

    /// @notice An ERC-20 token has been added to the allowlist.
    event TokenAllowlisted(address indexed token);

    /// @notice An ERC-20 token has been removed from the allowlist.
    event TokenDelisted(address indexed token);

    /// @notice A new sponsored collection has been registered. Does NOT
    ///         imply activation — call `setActiveCollection(id)` to
    ///         rotate the active slot.
    event CollectionRegistered(
        uint256 indexed collectionId, string name, string baseURI, address indexed royaltyReceiver, uint96 royaltyBps
    );

    /// @notice The active sponsored collection slot has been changed.
    ///         Emitted by both `setActiveCollection` and
    ///         `clearActiveCollection` (the latter with `newId == 0`).
    event ActiveCollectionChanged(uint256 indexed oldId, uint256 indexed newId);

    /// @notice EMERGENCY: a collection's stored baseURI has been overwritten.
    ///         Does NOT mutate already-minted receipts — those carry
    ///         their own frozen snapshot.
    event CollectionBaseURIForceUpdated(uint256 indexed collectionId, string oldBaseURI, string newBaseURI);

    /// @notice Treasury address has been changed.
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /// @notice A randomness request has been forwarded to the VRF coordinator.
    event RandomnessRequested(uint256 indexed tandaId, uint256 indexed requestId);

    /// @notice The VRF coordinator delivered randomness and the Tanda
    ///         was successfully notified with its payout seed.
    event PayoutOrderAssigned(uint256 indexed tandaId, uint256 randomSeed);

    /// @notice VRF parameters were updated.
    event VRFConfigUpdated(
        uint256 subscriptionId,
        bytes32 gasLane,
        uint32 callbackGasLimit,
        uint16 requestConfirmations,
        uint32 numWords,
        bool nativePayment
    );

    // ─────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Deploys the Manager as the singleton orchestrator.
    /// @dev    `VRFConsumerBaseV2Plus` hard-wires the owner to `msg.sender`
    ///         via `ConfirmedOwner(msg.sender)`. To run with a different
    ///         initial owner, call `transferOwnership` immediately
    ///         post-deploy (Chainlink's two-step transfer).
    /// @param _tandaImplementation  EIP-1167 implementation that
    ///                              `createTanda` will clone. Must already
    ///                              be deployed and verified on this chain.
    /// @param _vrfCoordinator       Chainlink VRF v2.5 coordinator address.
    /// @param _subscriptionId       Funded VRF subscription ID.
    /// @param _gasLane              Key hash for the desired gas lane.
    /// @param _callbackGasLimit     Gas budget the coordinator will use to
    ///                              call back into this contract.
    /// @param _treasury             Initial treasury address (2% platform
    ///                              fee recipient). Owner-configurable later.
    /// @param _passNFT              Soulbound Pass NFT contract address.
    ///                              Immutable; deployed once per chain.
    /// @param _receiptNFT           Transferable Receipt NFT contract
    ///                              address. Immutable.
    /// @param _completionNFT        Soulbound Completion NFT contract
    ///                              address. Immutable.
    constructor(
        address _tandaImplementation,
        address _vrfCoordinator,
        uint256 _subscriptionId,
        bytes32 _gasLane,
        uint32 _callbackGasLimit,
        address _treasury,
        address _passNFT,
        address _receiptNFT,
        address _completionNFT
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        if (_tandaImplementation == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        if (_callbackGasLimit == 0) revert ZeroAmount();
        if (_passNFT == address(0)) revert ZeroAddress();
        if (_receiptNFT == address(0)) revert ZeroAddress();
        if (_completionNFT == address(0)) revert ZeroAddress();
        // _vrfCoordinator zero-check is handled by VRFConsumerBaseV2Plus.

        tandaImplementation = _tandaImplementation;
        passNFT = _passNFT;
        receiptNFT = _receiptNFT;
        completionNFT = _completionNFT;
        treasury = _treasury;

        subscriptionId = _subscriptionId;
        gasLane = _gasLane;
        callbackGasLimit = _callbackGasLimit;
        requestConfirmations = 3;
        numWords = 1;
        nativePayment = true;

        nextTandaId = 1;
        nextCollectionId = 1;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Owner — treasury
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Update the platform treasury address.
    /// @dev    Owner-only. Future payouts route the 2% platform fee here;
    ///         pending pull-payment balances already credited to the
    ///         previous treasury are unaffected and must be claimed from
    ///         that address.
    /// @param newTreasury  New treasury wallet. Must not be zero.
    /// @custom:reverts ZeroAddress  if `newTreasury == address(0)`.
    /// @custom:emits   TreasuryUpdated(oldTreasury, newTreasury).
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Owner — token allowlist
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Add an ERC-20 token to the allowlist of currencies
    ///         creators can pick for new tandas.
    /// @dev    Owner-only. Appends to `allowedTokensList` for
    ///         enumeration. Existing tandas continue to function
    ///         regardless of allowlist changes — their token is set
    ///         in `initialize` and cannot be altered.
    /// @param token ERC-20 to allow. Must not be zero. Must not already
    ///              be on the allowlist.
    /// @custom:reverts ZeroAddress              if `token == address(0)`.
    /// @custom:reverts TokenAlreadyAllowlisted  if already allowlisted.
    /// @custom:emits   TokenAllowlisted(token).
    function allowlistToken(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (isAllowedToken[token]) revert TokenAlreadyAllowlisted(token);
        isAllowedToken[token] = true;
        allowedTokensList.push(token);
        emit TokenAllowlisted(token);
    }

    /// @notice Remove an ERC-20 token from the allowlist.
    /// @dev    Owner-only. **Existing tandas using this token continue
    ///         to operate normally** — the allowlist is a creation-time
    ///         check only. Delisting blocks new tandas from being
    ///         created with this token but does not brick live tandas.
    ///         Their cycles continue to settle in the now-delisted
    ///         token until the tanda completes.
    ///
    ///         Removal does an O(n) swap-and-pop on `allowedTokensList`.
    ///         The order of remaining entries is not preserved.
    /// @param token ERC-20 to remove. Must currently be allowlisted.
    /// @custom:reverts TokenNotAllowlisted if not on the allowlist.
    /// @custom:emits   TokenDelisted(token).
    function delistToken(address token) external onlyOwner {
        if (!isAllowedToken[token]) revert TokenNotAllowlisted(token);
        isAllowedToken[token] = false;

        // O(n) swap-and-pop removal from allowedTokensList.
        uint256 len = allowedTokensList.length;
        for (uint256 i = 0; i < len; i++) {
            if (allowedTokensList[i] == token) {
                allowedTokensList[i] = allowedTokensList[len - 1];
                allowedTokensList.pop();
                break;
            }
        }

        emit TokenDelisted(token);
    }

    /// @notice Returns every token currently on the allowlist.
    /// @dev    Order is insertion-order with swap-and-pop semantics on
    ///         removal; do not rely on positional stability across
    ///         delistings.
    function getAllowedTokens() external view returns (address[] memory) {
        return allowedTokensList;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Owner — sponsored collection registry
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Register a new sponsored NFT collection slot.
    /// @dev    Owner-only. Records the slot on-chain but does NOT
    ///         activate it; a separate `setActiveCollection(id)` call
    ///         rotates the active pointer. Sponsors pay for slot
    ///         rotation off-chain — this function just writes the
    ///         metadata other contracts will snapshot from.
    ///         Collection ID 0 is reserved as "unset"; IDs are assigned
    ///         monotonically from `nextCollectionId` starting at 1.
    /// @param name             Display name (e.g. "Mi Tanda Genesis",
    ///                         "Bitso x Mi Tanda"). Stored verbatim.
    /// @param baseURI          IPFS or HTTPS folder under which receipt
    ///                         token metadata lives.
    ///                         `MitandaReceiptNFT.tokenURI` appends
    ///                         `"/" + tokenId + ".json"` at mint time
    ///                         (snapshotted; see frozen-at-mint).
    /// @param royaltyReceiver  Wallet that receives ERC-2981 royalties
    ///                         on secondary sales of receipts minted
    ///                         while this collection is active. Must
    ///                         not be zero.
    /// @param royaltyBps       Royalty rate in basis points
    ///                         (10_000 = 100%). Capped at 1_000 (10%).
    /// @return collectionId    The newly-assigned ID.
    /// @custom:reverts ZeroAddress      if `royaltyReceiver == address(0)`.
    /// @custom:reverts RoyaltyTooHigh   if `royaltyBps > MAX_ROYALTY_BPS`.
    /// @custom:emits   CollectionRegistered(collectionId, name, baseURI,
    ///                                       royaltyReceiver, royaltyBps).
    function registerCollection(
        string calldata name,
        string calldata baseURI,
        address royaltyReceiver,
        uint96 royaltyBps
    ) external onlyOwner returns (uint256 collectionId) {
        if (royaltyReceiver == address(0)) revert ZeroAddress();
        if (royaltyBps > MAX_ROYALTY_BPS) revert RoyaltyTooHigh(royaltyBps, MAX_ROYALTY_BPS);

        collectionId = nextCollectionId++;

        collections[collectionId] = SponsoredCollection({
            name: name,
            baseURI: baseURI,
            royaltyReceiver: royaltyReceiver,
            royaltyBps: royaltyBps,
            activatedAt: block.timestamp,
            exists: true
        });

        emit CollectionRegistered(collectionId, name, baseURI, royaltyReceiver, royaltyBps);
    }

    /// @notice Switch the currently-active sponsored collection slot.
    /// @dev    Owner-only. Subsequent `Tanda` constructions will snapshot
    ///         this new ID. Does NOT retroactively touch existing tandas
    ///         — each tanda captured `activeCollectionId` in its
    ///         `initialize` call and keeps that value for life. Also
    ///         does not touch already-minted receipts; those carry
    ///         their own frozen snapshot.
    ///
    ///         **Cannot be used to clear the active slot.** Passing
    ///         `0` here always reverts with `UnknownCollection(0)`,
    ///         because collection ID 0 is reserved and never has
    ///         `exists == true`. To enter no-sponsor / go-dark mode,
    ///         call `clearActiveCollection()` instead.
    /// @param collectionId  ID of a previously-registered collection.
    ///                      Must satisfy `collections[collectionId].exists`.
    /// @custom:reverts UnknownCollection if `!collections[collectionId].exists`.
    /// @custom:emits   ActiveCollectionChanged(oldId, newId).
    function setActiveCollection(uint256 collectionId) external onlyOwner {
        if (!collections[collectionId].exists) revert UnknownCollection(collectionId);
        uint256 oldId = activeCollectionId;
        activeCollectionId = collectionId;
        emit ActiveCollectionChanged(oldId, collectionId);
    }

    /// @notice Enter no-sponsor mode by clearing the active collection slot.
    /// @dev    Owner-only. After this call, newly-created tandas snapshot
    ///         `sponsoredCollectionId == 0` and their receipts fall back
    ///         to `MitandaReceiptNFT.defaultFallbackBaseURI` with zero
    ///         ERC-2981 royalty. Already-created tandas are unaffected.
    /// @custom:emits ActiveCollectionChanged(oldId, 0).
    function clearActiveCollection() external onlyOwner {
        uint256 oldId = activeCollectionId;
        activeCollectionId = 0;
        emit ActiveCollectionChanged(oldId, 0);
    }

    /// @notice EMERGENCY ONLY — overwrite a collection's stored `baseURI`.
    /// @dev    Owner-only. Use cases: original IPFS pin disappeared,
    ///         sponsor needs to relocate hosting, metadata folder must
    ///         be migrated.
    ///
    ///         IMPORTANT — this function does NOT mutate already-minted
    ///         receipts. Each `MitandaReceiptNFT` token freezes its own
    ///         `frozenBaseURI` at mint time and returns it from
    ///         `tokenURI()` without re-reading the Manager. This
    ///         function therefore only affects FUTURE mints under the
    ///         same `collectionId`.
    ///
    ///         Logged loudly via `CollectionBaseURIForceUpdated` so
    ///         block explorers and indexers surface every invocation.
    /// @param collectionId  Existing collection to modify. Must exist.
    /// @param newBaseURI    Replacement folder URI. Stored verbatim; no
    ///                      trailing-slash normalization.
    /// @custom:reverts UnknownCollection if `!collections[collectionId].exists`.
    /// @custom:emits   CollectionBaseURIForceUpdated(collectionId,
    ///                                                 oldBaseURI, newBaseURI).
    function forceUpdateCollectionBaseURI(uint256 collectionId, string calldata newBaseURI) external onlyOwner {
        SponsoredCollection storage c = collections[collectionId];
        if (!c.exists) revert UnknownCollection(collectionId);
        string memory oldBaseURI = c.baseURI;
        c.baseURI = newBaseURI;
        emit CollectionBaseURIForceUpdated(collectionId, oldBaseURI, newBaseURI);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Views — sponsored collection registry
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Returns the currently-active collection ID and its data.
    /// @dev    If `activeCollectionId == 0` (no-sponsor mode), `data`
    ///         comes back as the zero-valued `SponsoredCollection` with
    ///         `exists == false`.
    function getActiveCollection() external view returns (uint256 collectionId, SponsoredCollection memory data) {
        collectionId = activeCollectionId;
        data = collections[collectionId];
    }

    /// @notice Returns a previously-registered collection by ID.
    /// @param collectionId  Existing collection ID.
    /// @custom:reverts UnknownCollection if the collection does not exist.
    function getCollection(uint256 collectionId) external view returns (SponsoredCollection memory) {
        if (!collections[collectionId].exists) revert UnknownCollection(collectionId);
        return collections[collectionId];
    }

    // ─────────────────────────────────────────────────────────────────────
    // Tanda factory
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Create a new Tanda as an EIP-1167 clone and initialize it.
    /// @dev    Validates parameters against the Manager's configured
    ///         ranges, clones `tandaImplementation`, registers the
    ///         clone in the manager's bookkeeping, then calls
    ///         `ITanda(clone).initialize(...)`. The active sponsored
    ///         collection is snapshotted into the clone at this moment
    ///         and remains fixed for the clone's lifetime.
    ///
    ///         Reverts cleanly if the system is paused (`whenNotPaused`).
    /// @param token              ERC-20 used as contribution / payout
    ///                           currency. Must be on the allowlist.
    /// @param contributionAmount Per-cycle contribution in `token` base
    ///                           units. Must be positive.
    /// @param payoutInterval     Seconds between cycle payouts. Must be
    ///                           in `[MIN_PAYOUT_INTERVAL, MAX_PAYOUT_INTERVAL]`.
    /// @param participantCount   Number of seats (also the number of
    ///                           cycles). Must be in
    ///                           `[MIN_PARTICIPANT_COUNT, MAX_PARTICIPANT_COUNT]`.
    /// @param gracePeriod        Seconds of grace before late
    ///                           contributors become defaultable. Must
    ///                           be in `[MIN_GRACE_PERIOD, MAX_GRACE_PERIOD]`.
    /// @return tandaId           ID assigned to the new tanda.
    /// @custom:reverts TokenNotAllowlisted          if `token` is not allowlisted.
    /// @custom:reverts ZeroAmount                   if `contributionAmount == 0`.
    /// @custom:reverts PayoutIntervalOutOfRange     for out-of-range `payoutInterval`.
    /// @custom:reverts ParticipantCountOutOfRange   for out-of-range `participantCount`.
    /// @custom:reverts GracePeriodOutOfRange        for out-of-range `gracePeriod`.
    /// @custom:emits   TandaCreated(tandaId, tandaAddress, creator, ...).
    function createTanda(
        address token,
        uint256 contributionAmount,
        uint256 payoutInterval,
        uint16 participantCount,
        uint256 gracePeriod,
        uint256 scheduledStart,
        ITanda.TandaPrivacy privacyMode
    ) external whenNotPaused returns (uint256 tandaId) {
        if (!isAllowedToken[token]) revert TokenNotAllowlisted(token);
        if (contributionAmount == 0) revert ZeroAmount();
        if (payoutInterval < MIN_PAYOUT_INTERVAL || payoutInterval > MAX_PAYOUT_INTERVAL) {
            revert PayoutIntervalOutOfRange(payoutInterval, MIN_PAYOUT_INTERVAL, MAX_PAYOUT_INTERVAL);
        }
        if (participantCount < MIN_PARTICIPANT_COUNT || participantCount > MAX_PARTICIPANT_COUNT) {
            revert ParticipantCountOutOfRange(participantCount, MIN_PARTICIPANT_COUNT, MAX_PARTICIPANT_COUNT);
        }
        if (gracePeriod < MIN_GRACE_PERIOD || gracePeriod > MAX_GRACE_PERIOD) {
            revert GracePeriodOutOfRange(gracePeriod, MIN_GRACE_PERIOD, MAX_GRACE_PERIOD);
        }

        // scheduledStart == 0 means "auto-start when full". Any positive
        // value must give at least 1 day of lead time so participants
        // have a window to join before the deadline locks.
        if (scheduledStart > 0) {
            uint256 earliest = block.timestamp + 1 days;
            if (scheduledStart < earliest) {
                revert ScheduledStartTooSoon(scheduledStart, earliest);
            }
        }

        tandaId = nextTandaId++;

        // Snapshot the active sponsored collection at THIS moment. 0 is a
        // legitimate value (go-dark mode); the Tanda passes it through to
        // the Receipt NFT, which falls back to its default URI on mint.
        uint256 collectionId = activeCollectionId;

        // Clone, register, then initialize. Registration happens before
        // initialize so any internal callback by the new clone (now or
        // ever) sees itself as a registered tanda.
        address tandaAddress = Clones.clone(tandaImplementation);
        tandaIdToAddress[tandaId] = tandaAddress;
        addressToTandaId[tandaAddress] = tandaId;

        ITanda(tandaAddress)
            .initialize(
                ITanda.InitParams({
                tandaId: tandaId,
                token: token,
                contributionAmount: contributionAmount,
                payoutInterval: payoutInterval,
                participantCount: participantCount,
                gracePeriod: gracePeriod,
                manager: address(this),
                creator: msg.sender,
                sponsoredCollectionId: collectionId,
                scheduledStart: scheduledStart,
                privacy: privacyMode,
                passNFT: passNFT,
                receiptNFT: receiptNFT,
                completionNFT: completionNFT
            })
            );

        emit TandaCreated(
            tandaId,
            tandaAddress,
            msg.sender,
            token,
            contributionAmount,
            payoutInterval,
            participantCount,
            gracePeriod,
            collectionId,
            scheduledStart,
            privacyMode
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // VRF — request entry point for Tandas
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Forward a randomness request from a Tanda clone to the
    ///         Chainlink VRF v2.5 coordinator.
    /// @dev    Only callable by a registered Tanda clone (validated via
    ///         `addressToTandaId`). The `tandaId` parameter is checked
    ///         to match the caller — a mismatched ID means a clone is
    ///         lying about its own identity and the call reverts.
    ///         Reverts cleanly when the Manager is paused.
    /// @param tandaId  The caller's own Tanda ID.
    /// @custom:reverts CallerNotTanda   if `msg.sender` is not a registered tanda.
    /// @custom:reverts UnknownTanda     if `tandaId` does not match the caller.
    /// @custom:emits   RandomnessRequested(tandaId, requestId).
    function requestRandomnessForTanda(uint256 tandaId) external whenNotPaused {
        uint256 callerTandaId = addressToTandaId[msg.sender];
        if (callerTandaId == 0) revert CallerNotTanda();
        if (callerTandaId != tandaId) revert UnknownTanda(tandaId);

        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: gasLane,
                subId: subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: numWords,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: nativePayment}))
            })
        );

        vrfRequestIdToTandaId[requestId] = tandaId;
        emit RandomnessRequested(tandaId, requestId);
    }

    /// @notice Chainlink VRF v2.5 callback. Routes the delivered seed
    ///         back to the originating Tanda via `assignPayoutOrder`.
    /// @dev    `internal override` is mandated by VRFConsumerBaseV2Plus.
    ///         Intentionally NOT pause-gated: randomness requests issued
    ///         before a pause must still resolve so the Tanda state
    ///         machine doesn't strand.
    /// @param requestId    The VRF request ID.
    /// @param randomWords  The delivered random word(s). Only
    ///                     `randomWords[0]` is forwarded.
    /// @custom:reverts UnknownTanda  if the request was never recorded.
    /// @custom:emits   PayoutOrderAssigned(tandaId, randomSeed).
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        uint256 tandaId = vrfRequestIdToTandaId[requestId];
        address tandaAddress = tandaIdToAddress[tandaId];
        if (tandaAddress == address(0)) revert UnknownTanda(tandaId);

        uint256 seed = randomWords[0];
        ITanda(tandaAddress).assignPayoutOrder(seed);

        emit PayoutOrderAssigned(tandaId, seed);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Owner — VRF configuration
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Update Chainlink VRF v2.5 parameters.
    /// @dev    Owner-only. Affects all subsequent randomness requests.
    ///         In-flight requests already issued under the old config
    ///         continue to resolve normally.
    /// @custom:emits VRFConfigUpdated(...).
    function updateVRFConfig(
        uint256 _subscriptionId,
        bytes32 _gasLane,
        uint32 _callbackGasLimit,
        uint16 _requestConfirmations,
        uint32 _numWords,
        bool _nativePayment
    ) external onlyOwner {
        subscriptionId = _subscriptionId;
        gasLane = _gasLane;
        callbackGasLimit = _callbackGasLimit;
        requestConfirmations = _requestConfirmations;
        numWords = _numWords;
        nativePayment = _nativePayment;

        emit VRFConfigUpdated(
            _subscriptionId, _gasLane, _callbackGasLimit, _requestConfirmations, _numWords, _nativePayment
        );
    }

    /// @notice Read the current VRF configuration.
    function getVRFConfig()
        external
        view
        returns (
            uint256 _subscriptionId,
            bytes32 _gasLane,
            uint32 _callbackGasLimit,
            uint16 _requestConfirmations,
            uint32 _numWords,
            bool _nativePayment
        )
    {
        return (subscriptionId, gasLane, callbackGasLimit, requestConfirmations, numWords, nativePayment);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Views — Tanda registry
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Whether `candidate` was deployed by this Manager as a tanda.
    /// @dev    Used by NFT contracts' `onlyTanda` modifier:
    ///             `if (!manager.isTanda(msg.sender)) revert CallerNotTanda();`
    function isTanda(address candidate) external view returns (bool) {
        return addressToTandaId[candidate] != 0;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Owner — pause / unpause
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Pause user-facing entry points (`createTanda`,
    ///         `requestRandomnessForTanda`). VRF callbacks
    ///         (`fulfillRandomWords`) are intentionally NOT paused so
    ///         pending randomness still resolves.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume normal operations.
    function unpause() external onlyOwner {
        _unpause();
    }
}
