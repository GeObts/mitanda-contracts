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

/// @title  MitandaPassNFT
/// @author Mi Tanda
/// @notice Soulbound proof-of-membership token. Auto-minted by `Tanda`
///         clones inside `_joinInternal` when a participant joins.
///         Cannot be transferred (EIP-5192 locked); `approve` and
///         `setApprovalForAll` revert with `SoulboundTransferDisabled`
///         so wallets/marketplaces don't surface meaningless approval
///         flows.
/// @dev    Singleton — deployed once per chain, not cloned. Trusted
///         minters are validated via the Manager's `isTanda` view,
///         which checks the Manager's tanda registry.
///
///         **Defaulted-but-kept policy:** when a participant is marked
///         a defaulter in their tanda, the pass is NOT burned. The
///         pass's `isDefaulted` flag flips instead. This preserves the
///         historical record that the participant joined, and the
///         metadata server can serve appropriate metadata per state
///         (active / completed / defaulted).
contract MitandaPassNFT is ERC721, Ownable {
    // ─────────────────────────────────────────────────────────────────────
    // Immutables / storage
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Address of the `TandaManager` whose registry gates the
    ///         `onlyTanda` modifier. Immutable.
    address public immutable manager;

    /// @notice Next token ID to assign. Pre-incremented so IDs start at
    ///         1 (0 is reserved as "no pass" in `participantTandaToTokenId`).
    uint256 public nextTokenId;

    /// @notice `keccak256(abi.encode(participant, tandaId))` → tokenId.
    ///         Zero means no pass has been minted for that pair.
    mapping(bytes32 => uint256) public participantTandaToTokenId;

    /// @notice tokenId → participant address.
    mapping(uint256 => address) public passParticipant;

    /// @notice tokenId → originating tandaId.
    mapping(uint256 => uint256) public passTandaId;

    /// @notice tokenId → originating `Tanda` clone address.
    mapping(uint256 => address) public passTandaAddress;

    /// @notice tokenId → whether the participant was marked as a
    ///         defaulter in their tanda.
    mapping(uint256 => bool) public isDefaulted;

    string private _baseTokenURI;

    // ─────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────

    event PassMinted(
        uint256 indexed tokenId, address indexed participant, uint256 indexed tandaId, address tandaAddress
    );

    event PassMarkedDefaulted(uint256 indexed tokenId, address indexed participant, uint256 indexed tandaId);

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
    constructor(address managerAddress, address initialOwner) ERC721("Mi Tanda Pass", "MTPASS") Ownable(initialOwner) {
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

    /// @dev Reverts unless `msg.sender` is a registered Tanda in the
    ///      Manager's registry. The Manager validates registration at
    ///      `createTanda` time; the check here is a single SLOAD on a
    ///      mapping in the Manager.
    modifier onlyTanda() {
        if (!IMitandaManager(manager).isTanda(msg.sender)) revert CallerNotTanda();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Tanda-only: mint
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Mint a pass to `participant` for `tandaId`. Only callable
    ///         by `Tanda` clones registered in the Manager.
    /// @dev    One pass per `(participant, tandaId)` pair, enforced by
    ///         the `participantTandaToTokenId` lookup. All reverse
    ///         lookups are populated BEFORE `_safeMint` so the contract
    ///         is never in a half-state (even if the mint callback
    ///         reverts, the whole tx rolls back).
    /// @param participant Address receiving the pass.
    /// @param tandaId     ID of the originating tanda.
    /// @return tokenId    The newly minted token ID (1-indexed).
    /// @custom:reverts CallerNotTanda      if `msg.sender` isn't a Tanda.
    /// @custom:reverts PassAlreadyMinted   if a pass already exists for the pair.
    /// @custom:emits   PassMinted, Locked.
    function mint(address participant, uint256 tandaId) external onlyTanda returns (uint256 tokenId) {
        bytes32 key = keccak256(abi.encode(participant, tandaId));
        if (participantTandaToTokenId[key] != 0) {
            revert PassAlreadyMinted(participant, tandaId);
        }

        tokenId = ++nextTokenId;

        participantTandaToTokenId[key] = tokenId;
        passParticipant[tokenId] = participant;
        passTandaId[tokenId] = tandaId;
        passTandaAddress[tokenId] = msg.sender;

        _safeMint(participant, tokenId);

        emit PassMinted(tokenId, participant, tandaId, msg.sender);
        emit Locked(tokenId);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Tanda-only: markDefaulted
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Flag the pass for `(participant, tandaId)` as defaulted.
    /// @dev    Silently no-ops if no pass exists for the pair — by the
    ///         time `Tanda.markDefaulter` calls this, it has already
    ///         validated the participant. A missing pass would indicate
    ///         either a development mode where NFT minting wasn't wired
    ///         in yet, or a future operational path we want to be
    ///         robust to. Either way, we don't want to revert and undo
    ///         the participant-defaulted state change in `Tanda`.
    /// @custom:reverts CallerNotTanda if `msg.sender` isn't a Tanda.
    /// @custom:emits   PassMarkedDefaulted (only if the pass exists).
    function markDefaulted(address participant, uint256 tandaId) external onlyTanda {
        bytes32 key = keccak256(abi.encode(participant, tandaId));
        uint256 tokenId = participantTandaToTokenId[key];
        if (tokenId == 0) return;
        isDefaulted[tokenId] = true;
        emit PassMarkedDefaulted(tokenId, participant, tandaId);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Owner: setBaseURI
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Update the base URI prefix used by `tokenURI`.
    /// @dev    Owner-only. Stored verbatim; no trailing-slash
    ///         normalization. The metadata server is expected to read
    ///         on-chain state (`isDefaulted`, the originating tanda's
    ///         status) and serve appropriate metadata per token.
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
    ///      transitions (mint, burn, transfer). Soulbound: blocks any
    ///      transfer (where both `from` and `to` are non-zero). Mints
    ///      (`from == 0`) and burns (`to == 0`) pass through — though
    ///      we expose no `burn` function, so burns are unreachable.
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
    ///      tokens. Reverts so marketplaces don't surface a "grant
    ///      operator" flow.
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
    ///         true for this contract — every pass is soulbound for life.
    /// @custom:reverts ERC721NonexistentToken if `tokenId` doesn't exist.
    function locked(uint256 tokenId) external view returns (bool) {
        _requireOwned(tokenId);
        return true;
    }

    /// @notice Adds EIP-5192 (`0xb45a3c0e`) to the supported interface
    ///         set so marketplaces can detect the soulbound flag.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == 0xb45a3c0e // EIP-5192
            || super.supportsInterface(interfaceId);
    }

    // ─────────────────────────────────────────────────────────────────────
    // View helpers
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Returns the tokenId for `(participant, tandaId)`, or 0
    ///         if no pass has been minted for that pair.
    function getPassId(address participant, uint256 tandaId) external view returns (uint256) {
        return participantTandaToTokenId[keccak256(abi.encode(participant, tandaId))];
    }

    /// @notice True if a pass has been minted for `(participant, tandaId)`.
    function hasPass(address participant, uint256 tandaId) external view returns (bool) {
        return participantTandaToTokenId[keccak256(abi.encode(participant, tandaId))] != 0;
    }

    /// @notice Bundled view for a pass's full state — useful for the
    ///         metadata server and frontends.
    /// @custom:reverts ERC721NonexistentToken if `tokenId` doesn't exist.
    function getPassInfo(uint256 tokenId)
        external
        view
        returns (address participant, uint256 tandaId, address tandaAddress, bool defaulted)
    {
        _requireOwned(tokenId);
        participant = passParticipant[tokenId];
        tandaId = passTandaId[tokenId];
        tandaAddress = passTandaAddress[tokenId];
        defaulted = isDefaulted[tokenId];
    }
}
