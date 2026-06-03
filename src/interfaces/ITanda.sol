// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title  ITanda
/// @author Mi Tanda
/// @notice Minimal interface exposing the entry points `TandaManager`
///         needs to call into a `Tanda` clone, plus the shared
///         `TandaPrivacy` enum and `InitParams` struct.
/// @dev    Each `Tanda` is an EIP-1167 clone of a single implementation
///         contract. The implementation's constructor calls
///         `_disableInitializers()`; per-clone state is set via
///         `initialize(...)` immediately after `Clones.clone(...)`.
interface ITanda {
    /// @notice Membership policy for a tanda.
    /// @dev    PUBLIC: anyone may call `join()`.
    ///         PRIVATE_TICKETED: only invitees holding a creator-signed
    ///         EIP-712 invite may call `joinWithInvite(deadline, signature)`.
    enum TandaPrivacy {
        PUBLIC,
        PRIVATE_TICKETED
    }

    /// @notice One-shot initializer parameters. Passed by
    ///         `TandaManager.createTanda` immediately after cloning.
    /// @dev    Grouped into a struct because the parameter set is large;
    ///         keeps the call site readable and lets us add fields
    ///         without changing the public selector layout.
    /// @param tandaId               Monotonic ID assigned by the Manager.
    /// @param token                 ERC-20 used for contributions, payouts,
    ///                              insurance premiums, and fee transfers.
    /// @param contributionAmount    Per-cycle base contribution, in `token`
    ///                              base units. Premium is layered on top
    ///                              automatically (10% of this amount).
    /// @param payoutInterval        Seconds between consecutive payouts.
    /// @param participantCount      Number of seats; also the original
    ///                              count of payout cycles.
    /// @param gracePeriod           Seconds after a cycle's deadline during
    ///                              which a late contributor is still
    ///                              recoverable. Past this window,
    ///                              `markDefaulter` becomes callable.
    /// @param manager               Address of the deploying `TandaManager`.
    /// @param creator               The tanda's organizer / signer of invites.
    /// @param sponsoredCollectionId Snapshot of the Manager's active
    ///                              collection ID at creation time. `0` is
    ///                              permitted (go-dark mode).
    /// @param scheduledStart        Earliest block timestamp at which the
    ///                              tanda may transition to ACTIVE. `0`
    ///                              means "start immediately when full".
    ///                              Positive values must satisfy
    ///                              `>= block.timestamp + 1 days` (validated
    ///                              by Manager).
    /// @param privacy               Membership policy. PUBLIC or
    ///                              PRIVATE_TICKETED.
    struct InitParams {
        uint256 tandaId;
        address token;
        uint256 contributionAmount;
        uint256 payoutInterval;
        uint16 participantCount;
        uint256 gracePeriod;
        address manager;
        address creator;
        uint256 sponsoredCollectionId;
        uint256 scheduledStart;
        TandaPrivacy privacy;
        /// @custom:doc passNFT       Soulbound Pass NFT singleton.
        ///                           Auto-minted on `join` /
        ///                           `joinWithInvite`; flagged on
        ///                           `markDefaulter`.
        address passNFT;
        /// @custom:doc receiptNFT    Transferable Receipt NFT singleton.
        ///                           Minted on each cycle payout with
        ///                           frozen-at-mint sponsored metadata.
        address receiptNFT;
        /// @custom:doc completionNFT Soulbound Completion NFT singleton.
        ///                           Batch-minted at tanda completion
        ///                           to every still-active participant.
        address completionNFT;
    }

    /// @notice One-shot initializer called by `TandaManager.createTanda`
    ///         immediately after cloning. Guarded by OZ v5's `initializer`
    ///         modifier on the implementation, so it can only run once per
    ///         clone.
    function initialize(InitParams calldata params) external;

    /// @notice Delivers a VRF-resolved random seed to the Tanda so it can
    ///         compute its payout order.
    /// @dev    Called from `TandaManager.fulfillRandomWords` after the
    ///         Chainlink VRF v2.5 coordinator delivers randomness for this
    ///         tanda. The Tanda guards this entry point with its
    ///         `onlyManager` modifier.
    /// @param randomSeed Random seed used to derive the payout order.
    function assignPayoutOrder(uint256 randomSeed) external;

    /// @notice Enroll the tanda's creator as the first participant at
    ///         creation (charge-at-create). Called once by
    ///         `TandaManager.createTanda` AFTER it has transferred the
    ///         creator's first contribution + insurance premium into the
    ///         clone — so the Tanda only records state and mints the Pass
    ///         NFT; it does NOT pull funds itself. Guarded by `onlyManager`.
    /// @param creator The tanda's creator (the `createTanda` caller).
    function enrollCreator(address creator) external;
}
