// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import "./MitandaErrors.sol";

/// @notice Minimum slice of `TandaManager` this NFT contract reads at
///         runtime. Singleton lives at `manager`, set in the constructor.
/// @dev    The `SponsoredCollection` struct here MUST match the one
///         declared in `TandaManager.sol` exactly — same field names,
///         same types, same order. Any divergence corrupts the ABI
///         decode of `getCollection`'s return silently.
///         Verified against TandaManager.sol on 2026-05-27.
interface IMitandaManager {
    struct SponsoredCollection {
        string name;
        string baseURI;
        address royaltyReceiver;
        uint96 royaltyBps;
        uint256 activatedAt;
        bool exists;
    }

    function isTanda(address candidate) external view returns (bool);
    function getCollection(uint256 collectionId) external view returns (SponsoredCollection memory);
}

/// @title  MitandaReceiptNFT
/// @author Mi Tanda
/// @notice Transferable proof-of-payout token. Auto-minted by `Tanda`
///         clones inside `triggerPayout` to the cycle's recipient. Each
///         receipt references the Manager's sponsored collection that
///         was active at the tanda's creation time; the collection's
///         `baseURI`, `royaltyReceiver`, and `royaltyBps` are SNAPSHOTTED
///         into per-token storage at the moment of mint.
/// @dev    **Frozen-at-mint guarantee:** after mint, the contract NEVER
///         reads the Manager to resolve `tokenURI` or `royaltyInfo`.
///         Both come from `receiptData[tokenId]`'s per-token snapshot.
///         Even if the Manager rotates the active collection or calls
///         `forceUpdateCollectionBaseURI`, existing receipts retain
///         their original snapshot. This makes each receipt immutable
///         from the holder's perspective.
///
///         Receipts are TRANSFERABLE (not soulbound). ERC-2981 royalty
///         is set per-token via `_setTokenRoyalty`. Singleton —
///         deployed once per chain, not cloned.
contract MitandaReceiptNFT is ERC721, ERC2981, Ownable {
    // ─────────────────────────────────────────────────────────────────────
    // Immutables / storage
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Address of the `TandaManager` whose registry gates the
    ///         `onlyTanda` modifier and whose `getCollection` view
    ///         supplies sponsored-collection data at mint time.
    ///         Immutable; the Receipt NFT is permanently bound to one
    ///         Manager deployment.
    address public immutable manager;

    /// @notice Next token ID to assign. Pre-incremented so IDs start at 1.
    uint256 public nextTokenId;

    /// @notice Per-token frozen snapshot of mint-time collection data.
    /// @dev    The contract NEVER reads the Manager after mint to
    ///         resolve `tokenURI` or `royaltyInfo` — both are derived
    ///         from this struct alone.
    struct ReceiptData {
        uint256 tandaId;
        uint256 cycle;
        uint256 collectionId; // 0 = used default fallback at mint time
        string frozenBaseURI; // snapshot of collection's baseURI (or default fallback)
        address frozenRoyaltyReceiver;
        uint96 frozenRoyaltyBps;
        address tandaAddress; // originating Tanda clone
    }

    /// @notice tokenId → frozen per-token data. Public for direct
    ///         field-tuple reads; see also `getReceiptData(tokenId)`
    ///         for a clean struct return.
    mapping(uint256 => ReceiptData) public receiptData;

    /// @notice Default fallback baseURI used when a Tanda mints with
    ///         `collectionId == 0` (a "go-dark" no-sponsor period).
    /// @dev    Updated via owner-only `setDefaultFallbackBaseURI`.
    string private _defaultFallbackBaseURI;

    // ─────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────

    event ReceiptMinted(
        uint256 indexed tokenId,
        address indexed recipient,
        uint256 indexed tandaId,
        uint256 cycle,
        uint256 collectionId,
        string frozenBaseURI,
        address frozenRoyaltyReceiver,
        uint96 frozenRoyaltyBps
    );

    event DefaultFallbackBaseURIUpdated(string oldBaseURI, string newBaseURI);

    // ─────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────

    /// @param managerAddress                 Address of the deployed `TandaManager`.
    /// @param initialOwner                   Owner of this NFT contract
    ///                                       (controls `setDefaultFallbackBaseURI`).
    /// @param initialDefaultFallbackBaseURI  Initial fallback URI used
    ///                                       for go-dark mints (must be non-empty).
    constructor(address managerAddress, address initialOwner, string memory initialDefaultFallbackBaseURI)
        ERC721("Mi Tanda Receipt", "MTRECEIPT")
        Ownable(initialOwner)
    {
        if (managerAddress == address(0)) revert ZeroAddress();
        // OZ v5 `Ownable` already rejects zero `initialOwner` via
        // `OwnableInvalidOwner`. The explicit check below is redundant
        // but consistent with the codebase's defense-in-depth style.
        if (initialOwner == address(0)) revert ZeroAddress();
        if (bytes(initialDefaultFallbackBaseURI).length == 0) revert EmptyBaseURI();

        manager = managerAddress;
        _defaultFallbackBaseURI = initialDefaultFallbackBaseURI;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────

    modifier onlyTanda() {
        if (!IMitandaManager(manager).isTanda(msg.sender)) revert CallerNotTanda();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Tanda-only: mintReceipt
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Mint a receipt to `recipient` for the given tanda + cycle.
    ///         Only callable by `Tanda` clones registered in the Manager.
    /// @dev    The Manager is read exactly ONCE per mint (in this
    ///         function) and never again for this token. All later
    ///         metadata + royalty reads come from `receiptData[tokenId]`.
    ///
    ///         **`collectionId == 0` (go-dark) path:** frozen
    ///         `baseURI` becomes the current `_defaultFallbackBaseURI`;
    ///         royalty receiver and bps stay zero (ERC-2981 treats a
    ///         zero receiver as "no royalty"). `_setTokenRoyalty` is
    ///         intentionally NOT called because OZ v5 reverts on a
    ///         zero receiver — leaving the per-token entry unset
    ///         causes `royaltyInfo` to fall back to the default
    ///         (which we never set), giving `(address(0), 0)`.
    ///
    ///         **`collectionId > 0` path:** `getCollection` reverts
    ///         `UnknownCollection` from the Manager if the collection
    ///         doesn't exist, but we defensively double-check
    ///         `c.exists` and revert our own `ReceiptCollectionNotFound`
    ///         in case the Manager's behavior ever changes.
    /// @param recipient    Address receiving the receipt (the cycle's payout recipient).
    /// @param tandaId      ID of the originating tanda.
    /// @param cycle        Cycle being paid out (1-indexed).
    /// @param collectionId Sponsored collection ID at mint time, or 0 for go-dark.
    /// @return tokenId     The newly minted token ID (1-indexed).
    /// @custom:reverts CallerNotTanda            if `msg.sender` isn't a Tanda.
    /// @custom:reverts ReceiptCollectionNotFound if `collectionId > 0` but the
    ///                                            collection doesn't exist.
    /// @custom:emits   ReceiptMinted.
    function mintReceipt(address recipient, uint256 tandaId, uint256 cycle, uint256 collectionId)
        external
        onlyTanda
        returns (uint256 tokenId)
    {
        // Resolve frozen snapshot based on collectionId.
        string memory frozenURI;
        address frozenReceiver;
        uint96 frozenBps;

        if (collectionId == 0) {
            // Go-dark mint — use default fallback. Receiver and bps
            // stay zero; per ERC-2981 a zero receiver means no royalty.
            frozenURI = _defaultFallbackBaseURI;
            // frozenReceiver and frozenBps already 0.
        } else {
            // Live collection — fetch from Manager and snapshot.
            IMitandaManager.SponsoredCollection memory c = IMitandaManager(manager).getCollection(collectionId);
            // Defensive double-check: `getCollection` already reverts
            // `UnknownCollection` if !c.exists, but if the Manager's
            // behavior ever changes, we want a typed receipt-side error.
            if (!c.exists) revert ReceiptCollectionNotFound(collectionId);

            frozenURI = c.baseURI;
            frozenReceiver = c.royaltyReceiver;
            frozenBps = c.royaltyBps;
        }

        tokenId = ++nextTokenId;

        receiptData[tokenId] = ReceiptData({
            tandaId: tandaId,
            cycle: cycle,
            collectionId: collectionId,
            frozenBaseURI: frozenURI,
            frozenRoyaltyReceiver: frozenReceiver,
            frozenRoyaltyBps: frozenBps,
            tandaAddress: msg.sender
        });

        // Per-token royalty via ERC2981. Skip when receiver is zero —
        // OZ v5's `_setTokenRoyalty` reverts on a zero receiver, and a
        // missing per-token entry correctly falls through to the
        // (unset) default royalty, giving `(address(0), 0)` from
        // `royaltyInfo`.
        if (frozenReceiver != address(0)) {
            _setTokenRoyalty(tokenId, frozenReceiver, frozenBps);
        }

        _safeMint(recipient, tokenId);

        emit ReceiptMinted(tokenId, recipient, tandaId, cycle, collectionId, frozenURI, frozenReceiver, frozenBps);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Owner: setDefaultFallbackBaseURI
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Update the default fallback baseURI used by future
    ///         go-dark mints (where Tanda passes `collectionId == 0`).
    /// @dev    Owner-only. **Does NOT mutate already-minted receipts.**
    ///         Existing receipts carry their own `frozenBaseURI` taken
    ///         at mint time and continue to use it. This function only
    ///         affects FUTURE mints during go-dark periods.
    /// @custom:reverts EmptyBaseURI if `bytes(newBaseURI).length == 0`.
    /// @custom:emits   DefaultFallbackBaseURIUpdated.
    function setDefaultFallbackBaseURI(string calldata newBaseURI) external onlyOwner {
        if (bytes(newBaseURI).length == 0) revert EmptyBaseURI();
        string memory oldBaseURI = _defaultFallbackBaseURI;
        _defaultFallbackBaseURI = newBaseURI;
        emit DefaultFallbackBaseURIUpdated(oldBaseURI, newBaseURI);
    }

    /// @notice Read the current default fallback baseURI. Used by
    ///         future go-dark mints; existing receipts read their own
    ///         per-token frozen snapshot instead.
    function defaultFallbackBaseURI() external view returns (string memory) {
        return _defaultFallbackBaseURI;
    }

    // ─────────────────────────────────────────────────────────────────────
    // ERC-721 metadata
    // ─────────────────────────────────────────────────────────────────────

    /// @notice URI of `tokenId`'s metadata. Reads ONLY from per-token
    ///         frozen storage — the Manager is never consulted.
    ///         Format: `<frozenBaseURI>/<tokenId>.json`.
    /// @custom:reverts ERC721NonexistentToken if `tokenId` doesn't exist.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        ReceiptData storage data = receiptData[tokenId];
        return string.concat(data.frozenBaseURI, "/", Strings.toString(tokenId), ".json");
    }

    // ─────────────────────────────────────────────────────────────────────
    // ERC-165 / ERC-2981 interface
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Composite `supportsInterface` over `ERC721` + `ERC2981`.
    ///         Both bases declare `supportsInterface`, so the override
    ///         must list both.
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // ─────────────────────────────────────────────────────────────────────
    // View helpers
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Return the full `ReceiptData` struct for `tokenId`.
    /// @dev    Solidity's auto-generated `receiptData(tokenId)` getter
    ///         returns a flat tuple of all fields. This view returns
    ///         the named struct, which decodes more cleanly in many
    ///         frontends.
    /// @custom:reverts ERC721NonexistentToken if `tokenId` doesn't exist.
    function getReceiptData(uint256 tokenId) external view returns (ReceiptData memory) {
        _requireOwned(tokenId);
        return receiptData[tokenId];
    }
}
