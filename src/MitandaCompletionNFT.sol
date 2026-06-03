// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import "./MitandaErrors.sol";

/// @notice Minimum slice of `TandaManager` that this NFT contract reads
///         at runtime. Singleton lives at `manager`, set in the
///         constructor and immutable thereafter.
interface IMitandaManager {
    function isTanda(address candidate) external view returns (bool);
}

/// @title  MitandaCompletionNFT
/// @author Mi Tanda
/// @notice Soulbound proof-of-completion token. Batch-minted by `Tanda`
///         clones inside `_completeTanda` for every still-active
///         participant. Defaulters never receive a completion badge by
///         construction — `Tanda` only includes `isActive == true`
///         addresses in the call. Cannot be transferred (EIP-5192
///         locked); approval calls revert.
/// @dev    Singleton — deployed once per chain, not cloned. Trusted
///         minters are validated via the Manager's `isTanda` view.
///         **Append-only**: once minted, a completion badge cannot be
///         modified or burned. Stackable across tandas — each holder's
///         `balanceOf` IS their `reputationScore`.
contract MitandaCompletionNFT is ERC721, Ownable {
    // ─────────────────────────────────────────────────────────────────────
    // Immutables / storage
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Address of the `TandaManager` whose registry gates the
    ///         `onlyTanda` modifier. Immutable.
    address public immutable manager;

    /// @notice Next token ID to assign. Pre-incremented so IDs start at
    ///         1 (0 is reserved as "no badge" in `participantTandaToTokenId`).
    uint256 public nextTokenId;

    /// @notice `keccak256(abi.encode(participant, tandaId))` → tokenId.
    ///         Zero means no completion badge has been minted for that pair.
    mapping(bytes32 => uint256) public participantTandaToTokenId;

    /// @notice tokenId → participant address.
    mapping(uint256 => address) public completionParticipant;

    /// @notice tokenId → originating tandaId.
    mapping(uint256 => uint256) public completionTandaId;

    /// @notice tokenId → originating `Tanda` clone address.
    mapping(uint256 => address) public completionTandaAddress;

    string private _baseTokenURI;

    // ─────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────

    event CompletionMinted(
        uint256 indexed tokenId, address indexed participant, uint256 indexed tandaId, address tandaAddress
    );

    event BaseURIUpdated(string newBaseURI);

    /// @notice EIP-5192: emitted on mint to signal the token is locked
    ///         for life. No `Unlocked` event is ever emitted.
    event Locked(uint256 tokenId);

    // ─────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────

    /// @param managerAddress  Address of the deployed `TandaManager`.
    /// @param initialOwner    Owner of this NFT contract (controls
    ///                        `setBaseURI`).
    constructor(address managerAddress, address initialOwner)
        ERC721("Mi Tanda Completion", "MTCOMP")
        Ownable(initialOwner)
    {
        if (managerAddress == address(0)) revert ZeroAddress();
        // OZ v5 `Ownable` already rejects zero `initialOwner` via
        // `OwnableInvalidOwner`. The explicit check below is redundant
        // but consistent with the codebase's defense-in-depth style.
        if (initialOwner == address(0)) revert ZeroAddress();
        manager = managerAddress;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────

    modifier onlyTanda() {
        if (!IMitandaManager(manager).isTanda(msg.sender)) revert CallerNotTanda();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Tanda-only: batchMint
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Mint a completion badge to every address in `participants`
    ///         for `tandaId`. Called by `Tanda._completeTanda`.
    /// @dev    Empty `participants` array is a no-op (returns an empty
    ///         tokenIds array). The loop performs the duplicate check
    ///         independently per iteration; a duplicate within the
    ///         batch reverts the entire tx, rolling back all prior
    ///         iterations' writes — there's no half-batch state in
    ///         storage. Uses `_mint` (not `_safeMint`): completion badges
    ///         are soulbound, so the receiver check adds no safety and would
    ///         let a single non-receiver participant block completion for
    ///         everyone. `_mint` keeps completion unblockable.
    /// @param participants Addresses receiving badges. Order matters
    ///                     only for the returned `tokenIds` array.
    /// @param tandaId      ID of the completing tanda.
    /// @return tokenIds    Same-length array of newly-minted token IDs.
    /// @custom:reverts CallerNotTanda           if `msg.sender` isn't a Tanda.
    /// @custom:reverts CompletionAlreadyMinted  if any `(participants[i], tandaId)`
    ///                                          pair already has a badge.
    /// @custom:emits   CompletionMinted, Locked (one of each per mint).
    function batchMint(address[] calldata participants, uint256 tandaId)
        external
        onlyTanda
        returns (uint256[] memory tokenIds)
    {
        uint256 n = participants.length;
        tokenIds = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            address participant = participants[i];
            bytes32 key = keccak256(abi.encode(participant, tandaId));
            if (participantTandaToTokenId[key] != 0) {
                revert CompletionAlreadyMinted(participant, tandaId);
            }

            uint256 tokenId = ++nextTokenId;

            participantTandaToTokenId[key] = tokenId;
            completionParticipant[tokenId] = participant;
            completionTandaId[tokenId] = tandaId;
            completionTandaAddress[tokenId] = msg.sender;

            _mint(participant, tokenId);

            tokenIds[i] = tokenId;

            emit CompletionMinted(tokenId, participant, tandaId, msg.sender);
            emit Locked(tokenId);
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Owner: setBaseURI
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Update the base URI prefix used by `tokenURI`.
    /// @dev    Owner-only. Stored verbatim; no trailing-slash
    ///         normalization. The metadata server is expected to
    ///         compute appropriate per-badge metadata.
    /// @custom:reverts EmptyBaseURI if `bytes(newBaseURI).length == 0`.
    /// @custom:emits   BaseURIUpdated.
    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        if (bytes(newBaseURI).length == 0) revert EmptyBaseURI();
        _baseTokenURI = newBaseURI;
        emit BaseURIUpdated(newBaseURI);
    }

    /// @notice Read the current base URI prefix.
    function baseURI() external view returns (string memory) {
        return _baseTokenURI;
    }

    // ─────────────────────────────────────────────────────────────────────
    // ERC-721 overrides — soulbound enforcement
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Central OZ v5 hook for all balance / ownership state
    ///      transitions. Soulbound: blocks any transfer (where both
    ///      `from` and `to` are non-zero). Mints (`from == 0`) and
    ///      burns (`to == 0`) pass through — though we expose no
    ///      `burn` function, so burns are unreachable.
    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) {
            revert SoulboundTransferDisabled();
        }
        return super._update(to, tokenId, auth);
    }

    /// @dev Approval is meaningless for a soulbound token (no transfer
    ///      path exists). Reverting here keeps wallets and marketplaces
    ///      from showing users a hollow "approve" button.
    function approve(
        address,
        /*to*/
        uint256 /*tokenId*/
    )
        public
        pure
        override
    {
        revert SoulboundTransferDisabled();
    }

    /// @dev Operator approvals are likewise meaningless for soulbound
    ///      tokens.
    function setApprovalForAll(
        address,
        /*operator*/
        bool /*approved*/
    )
        public
        pure
        override
    {
        revert SoulboundTransferDisabled();
    }

    // ─────────────────────────────────────────────────────────────────────
    // ERC-721 metadata
    // ─────────────────────────────────────────────────────────────────────

    /// @notice URI of `tokenId`'s metadata.
    ///         Format: `<baseURI>/<tokenId>.json`.
    /// @custom:reverts ERC721NonexistentToken if `tokenId` doesn't exist.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return string.concat(_baseTokenURI, "/", Strings.toString(tokenId), ".json");
    }

    // ─────────────────────────────────────────────────────────────────────
    // EIP-5192
    // ─────────────────────────────────────────────────────────────────────

    /// @notice EIP-5192: returns true if `tokenId` is locked. Always
    ///         true here — every completion badge is soulbound for life.
    /// @custom:reverts ERC721NonexistentToken if `tokenId` doesn't exist.
    function locked(uint256 tokenId) external view returns (bool) {
        _requireOwned(tokenId);
        return true;
    }

    /// @notice Adds EIP-5192 (`0xb45a3c0e`) to the supported interface set.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == 0xb45a3c0e // EIP-5192
            || super.supportsInterface(interfaceId);
    }

    // ─────────────────────────────────────────────────────────────────────
    // View helpers
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Returns the tokenId for `(participant, tandaId)`, or 0
    ///         if no badge has been minted for that pair.
    function getCompletionId(address participant, uint256 tandaId) external view returns (uint256) {
        return participantTandaToTokenId[keccak256(abi.encode(participant, tandaId))];
    }

    /// @notice True if a completion badge has been minted for the pair.
    function hasCompletion(address participant, uint256 tandaId) external view returns (bool) {
        return participantTandaToTokenId[keccak256(abi.encode(participant, tandaId))] != 0;
    }

    /// @notice Bundled view for a badge's full state.
    /// @custom:reverts ERC721NonexistentToken if `tokenId` doesn't exist.
    function getCompletionInfo(uint256 tokenId)
        external
        view
        returns (address participant, uint256 tandaId, address tandaAddress)
    {
        _requireOwned(tokenId);
        participant = completionParticipant[tokenId];
        tandaId = completionTandaId[tokenId];
        tandaAddress = completionTandaAddress[tokenId];
    }

    /// @notice Reputation primitive: total count of completion badges
    ///         held by `holder`. Each badge represents one successful
    ///         tanda completion. Stackable across tandas.
    /// @dev    Simple alias for `balanceOf(holder)`. Kept as a distinct
    ///         function so the API surface is stable if a future
    ///         version adopts a weighted formula (by tanda size,
    ///         recency, etc.). Reverts with OZ's `ERC721InvalidOwner`
    ///         if `holder == address(0)` — matches `balanceOf`.
    function reputationScore(address holder) external view returns (uint256) {
        return balanceOf(holder);
    }
}
