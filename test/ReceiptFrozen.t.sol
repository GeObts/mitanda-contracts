// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {MitandaTestBase} from "./helpers/MitandaTestBase.sol";
import {Tanda} from "../src/Tanda.sol";
import {MitandaReceiptNFT} from "../src/MitandaReceiptNFT.sol";

/// @title  ReceiptFrozenTest
/// @notice Proves the frozen-at-mint guarantee for the Receipt NFT: a
///         receipt's `tokenURI` and `royaltyInfo` are snapshotted at
///         mint time and NEVER change afterward, even when the Manager
///         rotates the active sponsored collection, force-updates a
///         collection's baseURI, or the Receipt NFT's default fallback
///         baseURI is updated.
///
///         Also confirms: go-dark fallback path, ReceiptData getter
///         field-by-field, and that receipts are transferable (the
///         deliberate contrast with Pass and Completion which are
///         soulbound).
///
///         Setup-provided collection #1: baseURI "ipfs://test-collection",
///         royalty receiver `SPONSOR_ROYALTY_RECEIVER` (0xCAFE),
///         royalty bps 500 (5%). Default fallback baseURI
///         "ipfs://default-fallback".
contract ReceiptFrozenTest is MitandaTestBase {
    uint256 internal constant USDC = 10 ** 6;
    uint256 internal constant CONTRIBUTION = 100 * USDC;
    uint256 internal constant CHARGE_PER_CYCLE = 110 * USDC;

    // ── Constants we register for the second collection in scenario 1 ──
    string internal constant COL2_BASE_URI = "ipfs://collection-two";
    address internal constant COL2_RECEIVER = address(0xBEEEEE);
    uint96 internal constant COL2_BPS = 750; // 7.5%

    // ── Setup-base collection #1 (mirrors what's in MitandaTestBase) ──
    string internal constant COL1_BASE_URI = "ipfs://test-collection";

    // ── Default fallback (from base setUp constructor arg) ─────────────
    string internal constant DEFAULT_FALLBACK_URI = "ipfs://default-fallback";

    // ────────────────────────────────────────────────────────────────
    // Helpers
    // ────────────────────────────────────────────────────────────────

    /// @dev Create + fill a default 3-person tanda and run cycle 1.
    ///      Returns the new tanda's address, its first cycle's recipient,
    ///      and the receipt tokenId minted on that payout.
    function _mintFirstReceipt(uint256 seed) internal returns (address tandaAddr, address recipient, uint256 tokenId) {
        (tandaAddr,) = _createDefaultTanda(alice);
        Tanda t = Tanda(tandaAddr);

        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = carol;
        _fillAndStart(tandaAddr, users, seed);

        uint256[] memory order = t.getPayoutOrder();
        address[3] memory pArr = [alice, bob, carol];
        recipient = pArr[order[0]];

        _warpToNextCycle(tandaAddr);
        t.triggerPayout();

        // Each test starts with nextTokenId == 0; the first mint produces tokenId 1.
        tokenId = 1;
    }

    function _makePayment(address tandaAddr, address user, uint256 cycles) internal {
        uint256 charge = cycles * CHARGE_PER_CYCLE;
        _fundAndApprove(user, charge, tandaAddr);
        vm.prank(user);
        Tanda(tandaAddr).makePayment(cycles);
    }

    /// @dev Advance one more cycle on the given tanda (pay + warp + trigger).
    function _runNextCycle(address tandaAddr) internal {
        _makePayment(tandaAddr, alice, 1);
        _makePayment(tandaAddr, bob, 1);
        _makePayment(tandaAddr, carol, 1);
        _warpToNextCycle(tandaAddr);
        Tanda(tandaAddr).triggerPayout();
    }

    function _expectedURI(string memory base, uint256 tokenId) internal pure returns (string memory) {
        return string.concat(base, "/", vm.toString(tokenId), ".json");
    }

    // ────────────────────────────────────────────────────────────────
    // Scenario 1: tokenURI + royaltyInfo frozen across collection rotation
    // ────────────────────────────────────────────────────────────────

    function test_receiptURI_frozenAcrossCollectionRotation() public {
        // Register collection #2 (do NOT activate).
        uint256 col2Id = manager.registerCollection("Collection Two", COL2_BASE_URI, COL2_RECEIVER, COL2_BPS);
        assertEq(col2Id, 2, "collection 2 id");

        // Mint a receipt while collection #1 is the active slot.
        (,, uint256 tokenId) = _mintFirstReceipt(uint256(keccak256("rot_seed")));

        // Pre-rotation: URI + royalty reflect collection #1.
        string memory expectedURI = _expectedURI(COL1_BASE_URI, tokenId);
        assertEq(receiptNFT.tokenURI(tokenId), expectedURI, "URI pre-rotation");

        uint256 salePrice = 10_000;
        (address receiverBefore, uint256 royaltyBefore) = receiptNFT.royaltyInfo(tokenId, salePrice);
        assertEq(receiverBefore, SPONSOR_ROYALTY_RECEIVER, "royalty receiver pre");
        // 10_000 * 500 / 10_000 = 500
        assertEq(royaltyBefore, 500, "royalty amount pre");

        // ROTATE: activate collection #2.
        manager.setActiveCollection(col2Id);
        (uint256 activeId,) = manager.getActiveCollection();
        assertEq(activeId, col2Id, "active is now collection 2");

        // Re-read the SAME receipt — frozen.
        assertEq(receiptNFT.tokenURI(tokenId), expectedURI, "URI frozen after rotation");

        (address receiverAfter, uint256 royaltyAfter) = receiptNFT.royaltyInfo(tokenId, salePrice);
        assertEq(receiverAfter, SPONSOR_ROYALTY_RECEIVER, "royalty receiver frozen after rotation");
        assertEq(royaltyAfter, 500, "royalty amount frozen after rotation");
    }

    // ────────────────────────────────────────────────────────────────
    // Scenario 2: tokenURI unaffected by forceUpdateCollectionBaseURI
    // ────────────────────────────────────────────────────────────────

    function test_receiptURI_unaffectedByForceUpdate() public {
        (address tandaAddr,, uint256 tokenId1) = _mintFirstReceipt(uint256(keccak256("force_seed")));

        // Capture receipt 1's URI under collection #1's original baseURI.
        string memory originalURI = _expectedURI(COL1_BASE_URI, tokenId1);
        assertEq(receiptNFT.tokenURI(tokenId1), originalURI, "receipt 1 URI before force");

        // Force update collection #1's baseURI (emergency only).
        string memory newURI = "ipfs://NEW_EMERGENCY_URI";
        manager.forceUpdateCollectionBaseURI(1, newURI);

        // Sanity: Manager's stored baseURI did change.
        (, string memory newStoredBaseURI,,,,) = manager.collections(1);
        assertEq(newStoredBaseURI, newURI, "manager baseURI did update");

        // Existing receipt is unchanged — frozen at mint time.
        assertEq(receiptNFT.tokenURI(tokenId1), originalURI, "receipt 1 URI frozen after force");

        // Mint a NEW receipt in the same tanda. It should use the new URI
        // because it's a fresh mint that snapshots the now-updated value.
        _runNextCycle(tandaAddr);
        uint256 tokenId2 = 2;
        string memory expectedNewReceiptURI = _expectedURI(newURI, tokenId2);
        assertEq(receiptNFT.tokenURI(tokenId2), expectedNewReceiptURI, "new receipt URI uses force-updated");

        // And receipt 1 is STILL frozen.
        assertEq(receiptNFT.tokenURI(tokenId1), originalURI, "receipt 1 STILL frozen");
    }

    // ────────────────────────────────────────────────────────────────
    // Scenario 3: go-dark fallback
    // ────────────────────────────────────────────────────────────────

    function test_receiptURI_goDarkFallback() public {
        // Clear active collection — go dark.
        manager.clearActiveCollection();
        (uint256 activeId,) = manager.getActiveCollection();
        assertEq(activeId, 0, "active is now 0");

        // Mint a receipt under go-dark.
        (,, uint256 tokenId) = _mintFirstReceipt(uint256(keccak256("godark_seed")));

        // tokenURI uses the default fallback.
        assertEq(receiptNFT.tokenURI(tokenId), _expectedURI(DEFAULT_FALLBACK_URI, tokenId), "URI uses fallback");

        // royaltyInfo returns (address(0), 0) — no royalty on go-dark.
        (address receiver, uint256 royaltyAmount) = receiptNFT.royaltyInfo(tokenId, 10_000);
        assertEq(receiver, address(0), "no royalty receiver on go-dark");
        assertEq(royaltyAmount, 0, "no royalty amount on go-dark");

        // ReceiptData.collectionId == 0.
        MitandaReceiptNFT.ReceiptData memory data = receiptNFT.getReceiptData(tokenId);
        assertEq(data.collectionId, 0, "frozen collectionId 0");
        assertEq(data.frozenBaseURI, DEFAULT_FALLBACK_URI, "frozen baseURI is fallback");
        assertEq(data.frozenRoyaltyReceiver, address(0), "frozen royalty receiver zero");
        assertEq(uint256(data.frozenRoyaltyBps), 0, "frozen royalty bps zero");
    }

    // ────────────────────────────────────────────────────────────────
    // Scenario 4: go-dark fallback frozen across fallback update
    // ────────────────────────────────────────────────────────────────

    function test_receiptURI_goDarkFallback_frozenAcrossFallbackUpdate() public {
        manager.clearActiveCollection();

        // Mint receipt 1 under fallback "A" (= DEFAULT_FALLBACK_URI from setUp).
        (address tandaAddr,, uint256 tokenId1) = _mintFirstReceipt(uint256(keccak256("godark2_seed")));
        string memory receipt1URI = _expectedURI(DEFAULT_FALLBACK_URI, tokenId1);
        assertEq(receiptNFT.tokenURI(tokenId1), receipt1URI, "receipt 1 URI fallback A");

        // Owner-updates the fallback URI.
        string memory fallbackB = "ipfs://FALLBACK_B";
        receiptNFT.setDefaultFallbackBaseURI(fallbackB);
        assertEq(receiptNFT.defaultFallbackBaseURI(), fallbackB, "fallback B is set");

        // Existing receipt is UNCHANGED.
        assertEq(receiptNFT.tokenURI(tokenId1), receipt1URI, "receipt 1 frozen across fallback update");

        // Mint receipt 2 in same tanda — should use fallback B.
        _runNextCycle(tandaAddr);
        uint256 tokenId2 = 2;
        assertEq(receiptNFT.tokenURI(tokenId2), _expectedURI(fallbackB, tokenId2), "receipt 2 uses fallback B");

        // Receipt 1 STILL fallback A.
        assertEq(receiptNFT.tokenURI(tokenId1), receipt1URI, "receipt 1 STILL fallback A");
    }

    // ────────────────────────────────────────────────────────────────
    // Scenario 5: full ReceiptData struct getter
    // ────────────────────────────────────────────────────────────────

    function test_receiptData_publicGetter() public {
        (address tandaAddr,, uint256 tokenId) = _mintFirstReceipt(uint256(keccak256("getter_seed")));

        MitandaReceiptNFT.ReceiptData memory data = receiptNFT.getReceiptData(tokenId);

        // tandaId is whatever Manager assigned — the only tanda this test creates, so id = 1.
        assertEq(data.tandaId, 1, "tandaId");
        assertEq(data.cycle, 1, "cycle (first payout)");
        assertEq(data.collectionId, 1, "collectionId (active in base setUp)");
        assertEq(data.frozenBaseURI, COL1_BASE_URI, "frozen baseURI");
        assertEq(data.frozenRoyaltyReceiver, SPONSOR_ROYALTY_RECEIVER, "frozen royalty receiver");
        assertEq(uint256(data.frozenRoyaltyBps), 500, "frozen royalty bps");
        assertEq(data.tandaAddress, tandaAddr, "tandaAddress matches");
    }

    // ────────────────────────────────────────────────────────────────
    // Scenario 6: receipts are TRANSFERABLE (deliberate contrast with soulbound)
    // ────────────────────────────────────────────────────────────────

    function test_receipt_isTransferable() public {
        (, address recipient, uint256 tokenId) = _mintFirstReceipt(uint256(keccak256("transfer_seed")));

        // Pre-transfer ownership
        assertEq(receiptNFT.ownerOf(tokenId), recipient, "recipient owns receipt");

        // Pick a non-recipient destination
        address dest = recipient == dave ? eve : dave;
        assertTrue(dest != recipient, "dest != recipient");

        // Receipt holder transfers it.
        vm.prank(recipient);
        receiptNFT.transferFrom(recipient, dest, tokenId);

        assertEq(receiptNFT.ownerOf(tokenId), dest, "ownership moved to dest");
        assertEq(receiptNFT.balanceOf(recipient), 0, "recipient balance zero");
        assertEq(receiptNFT.balanceOf(dest), 1, "dest balance one");

        // The transferred receipt's URI + royalty info is still the original snapshot.
        assertEq(receiptNFT.tokenURI(tokenId), _expectedURI(COL1_BASE_URI, tokenId), "URI unchanged by transfer");
        (address receiver, uint256 royalty) = receiptNFT.royaltyInfo(tokenId, 10_000);
        assertEq(receiver, SPONSOR_ROYALTY_RECEIVER, "royalty receiver unchanged");
        assertEq(royalty, 500, "royalty amount unchanged");
    }
}
