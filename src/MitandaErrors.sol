// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title  MitandaErrors
/// @author Mi Tanda
/// @notice Single source of truth for every custom error used across the
///         Mi Tanda system. No contract in `src/` may use require-strings;
///         every revert must reference an error declared here.
/// @dev    File-level errors — import directly with
///         `import "./MitandaErrors.sol";` and use `revert ErrorName(args);`
///         from any contract.
///
///         Errors provided by OpenZeppelin v5 (Ownable, Pausable,
///         ReentrancyGuard, ERC721, etc.) are NOT redefined here — those
///         contracts surface their own errors and we let them through.

// ─────────────────────────────────────────────────────────────────────────────
// Shared — used by multiple contracts
// ─────────────────────────────────────────────────────────────────────────────

/// @notice An address argument was the zero address where non-zero is required.
error ZeroAddress();

/// @notice A numeric argument was zero where a positive value is required.
error ZeroAmount();

/// @notice Caller is not a Tanda contract registered in the Manager.
/// @dev    Used by NFT contracts' `onlyTanda` modifier. The modifier looks
///         up `msg.sender` in `TandaManager.tandaIdToAddress` and reverts
///         with this error if no match is found.
error CallerNotTanda();

/// @notice Caller is not the `TandaManager` contract.
/// @dev    Used by `Tanda.onlyManager` (e.g. VRF callback delivery from
///         the Manager).
error CallerNotManager();

/// @notice Caller is not the creator of this tanda.
/// @dev    Used by `Tanda.revokeInvite`.
error NotCreator();

// ─────────────────────────────────────────────────────────────────────────────
// TandaManager — token allowlist
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Token is not on the allowlist; cannot be used for new tandas.
error TokenNotAllowlisted(address token);

/// @notice Token is already on the allowlist; cannot add twice.
error TokenAlreadyAllowlisted(address token);

// ─────────────────────────────────────────────────────────────────────────────
// TandaManager — sponsored collection registry
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Royalty basis points exceeds the configured cap.
/// @param actual Submitted royalty value.
/// @param max    Hard cap (1000 = 10%).
error RoyaltyTooHigh(uint96 actual, uint96 max);

/// @notice Sponsored collection ID does not exist in the registry.
/// @dev    ID 0 is reserved as "unset" and will always trip this error
///         when passed to a function that requires an existing collection
///         (registerCollection assigns from 1 upward; setActiveCollection
///         rejects 0 — use clearActiveCollection() to enter no-sponsor mode).
error UnknownCollection(uint256 collectionId);

// ─────────────────────────────────────────────────────────────────────────────
// TandaManager — tanda factory parameter validation
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Tanda ID does not exist in the Manager registry.
error UnknownTanda(uint256 tandaId);

/// @notice Contribution amount is below the configured minimum.
error ContributionTooLow(uint256 actual, uint256 minimum);

/// @notice Payout interval is outside the allowed `[min, max]` range.
error PayoutIntervalOutOfRange(uint256 actual, uint256 min, uint256 max);

/// @notice Participant count is outside the allowed `[min, max]` range.
error ParticipantCountOutOfRange(uint16 actual, uint16 min, uint16 max);

/// @notice Grace period is outside the allowed `[min, max]` range.
error GracePeriodOutOfRange(uint256 actual, uint256 min, uint256 max);

// ─────────────────────────────────────────────────────────────────────────────
// Tanda — state machine
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Tanda state does not match what the action requires.
/// @param expected Required state code (0=OPEN, 1=ACTIVE, 2=COMPLETED).
/// @param actual   State code at call time.
error WrongTandaState(uint8 expected, uint8 actual);

/// @notice Tanda has already reached its participant cap.
error TandaFull();

/// @notice Caller is already a participant of this tanda.
error AlreadyJoined();

/// @notice Caller is not a participant of this tanda.
/// @dev    Distinct from `DefaultedParticipant` so frontends can show
///         the right message ("you're not in this tanda" vs. "you were
///         marked defaulter and lost your seat").
error NotParticipant();

/// @notice Caller (or `participant` argument) joined the tanda but was
///         marked as a defaulter. Their seat is forfeited; insurance
///         has been moved to the slash pool.
error DefaultedParticipant();

/// @notice `markDefaulter` was called on a participant who is paid up.
error NotDefaulter(address participant);

/// @notice `markDefaulter` was called on a participant already marked.
error AlreadyMarkedDefaulter(address participant);

/// @notice `markDefaulter` was called before the grace period expired.
/// @param currentTime Block timestamp at call time.
/// @param expiresAt   Earliest timestamp at which the default is enforceable.
error GracePeriodNotExpired(uint256 currentTime, uint256 expiresAt);

// ─────────────────────────────────────────────────────────────────────────────
// Tanda — scheduled start
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Scheduled start is positive but earlier than the minimum
///         lead time (`block.timestamp + 1 days`).
/// @param provided Submitted scheduled-start timestamp.
/// @param earliest Earliest accepted timestamp.
error ScheduledStartTooSoon(uint256 provided, uint256 earliest);

/// @notice `start()` was called before the scheduled-start timestamp.
/// @param currentTime    Block timestamp at call time.
/// @param scheduledStart Required earliest start time.
error ScheduledStartNotReached(uint256 currentTime, uint256 scheduledStart);

/// @notice `start()` was called while the tanda still has empty seats.
error TandaNotFull();

// ─────────────────────────────────────────────────────────────────────────────
// Tanda — privacy & invite tickets
// ─────────────────────────────────────────────────────────────────────────────

/// @notice `join()` was called on a `PRIVATE_TICKETED` tanda. Use
///         `joinWithInvite(deadline, signature)` instead.
error NotPublicTanda();

/// @notice `joinWithInvite(...)` was called on a `PUBLIC` tanda. Use
///         `join()` instead.
error NotPrivateTanda();

/// @notice The invite's deadline has passed.
/// @param currentTime Block timestamp at call time.
/// @param deadline    Invite's expiration timestamp.
error InviteExpired(uint256 currentTime, uint256 deadline);

/// @notice The recovered EIP-712 signer is not the tanda creator.
error InviteSignerNotCreator();

/// @notice This invite ticket has already been redeemed.
error TicketAlreadyUsed();

/// @notice This invite ticket was revoked by the creator.
error InviteAlreadyRevoked();

// ─────────────────────────────────────────────────────────────────────────────
// Tanda — payments & payouts
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Requested cycles to pay exceeds remaining unpaid cycles.
error CyclesOutOfRange(uint256 requested, uint256 maxAllowed);

/// @notice The payout time for the current cycle has not yet been reached.
/// @param currentTime Block timestamp at call time.
/// @param readyAt     Earliest block timestamp the payout is permitted.
error PayoutNotReady(uint256 currentTime, uint256 readyAt);

/// @notice Payout order has not yet been assigned by the VRF callback.
error PayoutOrderNotAssigned();

/// @notice Payout order has already been assigned; cannot reassign.
error PayoutOrderAlreadyAssigned();

/// @notice One or more participants is in default for the current cycle.
/// @dev    Detected by automatic timing-based defaulter logic. Payout is
///         blocked until the default is resolved (slash or grace-period
///         catch-up).
error DefaultersOutstanding();

/// @notice The pull-payment balance for the caller is zero.
error NothingToClaim();

/// @notice The contract holds less than the requested amount.
/// @param needed    Required amount.
/// @param available Current contract balance of the relevant token.
error InsufficientContractBalance(uint256 needed, uint256 available);

// ─────────────────────────────────────────────────────────────────────────────
// NFTs — Pass, Completion, Receipt
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Transfer attempted on a soulbound token (EIP-5192 locked).
/// @dev    Used by `MitandaPassNFT` and `MitandaCompletionNFT`. All
///         transfer, safeTransfer, and approval functions revert with
///         this error.
error SoulboundTransferDisabled();

/// @notice A pass NFT has already been minted for this `(participant, tandaId)` pair.
error PassAlreadyMinted(address participant, uint256 tandaId);

/// @notice A completion NFT has already been minted for this
///         `(participant, tandaId)` pair.
error CompletionAlreadyMinted(address participant, uint256 tandaId);

/// @notice Receipt NFT mint referenced a collection ID that doesn't
///         exist in the Manager's registry.
/// @dev    Distinct from `UnknownCollection` (Manager-emitted) so the
///         frontend can tell the NFT contract apart from the Manager.
error ReceiptCollectionNotFound(uint256 collectionId);

/// @notice Default fallback baseURI on the Receipt NFT was empty.
/// @dev    Used by `MitandaReceiptNFT`'s constructor and
///         `setDefaultFallbackBaseURI`. Distinct from `ZeroAddress` —
///         this is about string content, not an address.
error EmptyBaseURI();
