// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {MitandaTestBase} from "./helpers/MitandaTestBase.sol";
import {Tanda} from "../src/Tanda.sol";
import {ITanda} from "../src/interfaces/ITanda.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {
    ZeroAddress,
    ZeroAmount,
    TokenNotAllowlisted,
    TokenAlreadyAllowlisted,
    RoyaltyTooHigh,
    UnknownCollection,
    PayoutIntervalOutOfRange,
    ParticipantCountOutOfRange,
    GracePeriodOutOfRange,
    CallerNotTanda,
    CallerNotManager,
    EmptyBaseURI
} from "../src/MitandaErrors.sol";

/// @title  AccessControlTest
/// @notice Comprehensive access-control coverage for the whole system:
///         Manager owner-only / pause / input validation; NFT onlyTanda
///         and owner-only; Tanda onlyManager + initializer guard.
/// @dev    Manager uses Chainlink's `ConfirmedOwner` (string revert
///         "Only callable by owner"); NFTs use OZ v5 `Ownable`
///         (`OwnableUnauthorizedAccount(account)` custom error). The
///         assertions reflect each contract's actual revert format.
contract AccessControlTest is MitandaTestBase {
    string internal constant CHAINLINK_OWNER_REVERT = "Only callable by owner";
    uint256 internal constant USDC = 10 ** 6;
    uint256 internal constant CONTRIBUTION = 100 * USDC;

    // ────────────────────────────────────────────────────────────────
    // Manager owner-only — Chainlink ConfirmedOwner string revert
    // ────────────────────────────────────────────────────────────────

    function test_manager_setTreasury_revertsNonOwner() public {
        vm.expectRevert(bytes(CHAINLINK_OWNER_REVERT));
        vm.prank(alice);
        manager.setTreasury(address(0xCAFE));
    }

    function test_manager_allowlistToken_revertsNonOwner() public {
        vm.expectRevert(bytes(CHAINLINK_OWNER_REVERT));
        vm.prank(alice);
        manager.allowlistToken(address(0x1234));
    }

    function test_manager_delistToken_revertsNonOwner() public {
        vm.expectRevert(bytes(CHAINLINK_OWNER_REVERT));
        vm.prank(alice);
        manager.delistToken(address(usdc));
    }

    function test_manager_registerCollection_revertsNonOwner() public {
        vm.expectRevert(bytes(CHAINLINK_OWNER_REVERT));
        vm.prank(alice);
        manager.registerCollection("X", "ipfs://x", address(0xCAFE), 500);
    }

    function test_manager_setActiveCollection_revertsNonOwner() public {
        vm.expectRevert(bytes(CHAINLINK_OWNER_REVERT));
        vm.prank(alice);
        manager.setActiveCollection(1);
    }

    function test_manager_clearActiveCollection_revertsNonOwner() public {
        vm.expectRevert(bytes(CHAINLINK_OWNER_REVERT));
        vm.prank(alice);
        manager.clearActiveCollection();
    }

    function test_manager_forceUpdateCollectionBaseURI_revertsNonOwner() public {
        vm.expectRevert(bytes(CHAINLINK_OWNER_REVERT));
        vm.prank(alice);
        manager.forceUpdateCollectionBaseURI(1, "ipfs://new");
    }

    function test_manager_updateVRFConfig_revertsNonOwner() public {
        vm.expectRevert(bytes(CHAINLINK_OWNER_REVERT));
        vm.prank(alice);
        manager.updateVRFConfig(subId, GAS_LANE, 100_000, 3, 1, true);
    }

    function test_manager_pause_revertsNonOwner() public {
        vm.expectRevert(bytes(CHAINLINK_OWNER_REVERT));
        vm.prank(alice);
        manager.pause();
    }

    function test_manager_unpause_revertsNonOwner() public {
        // Pause first as owner so unpause is the actual under-test call.
        manager.pause();
        vm.expectRevert(bytes(CHAINLINK_OWNER_REVERT));
        vm.prank(alice);
        manager.unpause();
    }

    // ────────────────────────────────────────────────────────────────
    // Manager input validation
    // ────────────────────────────────────────────────────────────────

    function test_manager_setTreasury_zeroReverts() public {
        vm.expectRevert(ZeroAddress.selector);
        manager.setTreasury(address(0));
    }

    function test_manager_allowlistToken_zeroReverts() public {
        vm.expectRevert(ZeroAddress.selector);
        manager.allowlistToken(address(0));
    }

    function test_manager_allowlistToken_alreadyListedReverts() public {
        // usdc was allowlisted in setUp.
        vm.expectRevert(abi.encodeWithSelector(TokenAlreadyAllowlisted.selector, address(usdc)));
        manager.allowlistToken(address(usdc));
    }

    function test_manager_delistToken_notListedReverts() public {
        address fakeToken = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(TokenNotAllowlisted.selector, fakeToken));
        manager.delistToken(fakeToken);
    }

    function test_manager_registerCollection_zeroReceiverReverts() public {
        vm.expectRevert(ZeroAddress.selector);
        manager.registerCollection("X", "ipfs://x", address(0), 500);
    }

    function test_manager_registerCollection_royaltyTooHighReverts() public {
        // Max is 1_000 bps; 1_001 should trip.
        vm.expectRevert(abi.encodeWithSelector(RoyaltyTooHigh.selector, uint96(1_001), uint96(1_000)));
        manager.registerCollection("X", "ipfs://x", address(0xCAFE), 1_001);
    }

    function test_manager_setActiveCollection_unknownReverts() public {
        uint256 fakeId = 999;
        vm.expectRevert(abi.encodeWithSelector(UnknownCollection.selector, fakeId));
        manager.setActiveCollection(fakeId);
    }

    function test_manager_forceUpdateCollectionBaseURI_unknownReverts() public {
        uint256 fakeId = 999;
        vm.expectRevert(abi.encodeWithSelector(UnknownCollection.selector, fakeId));
        manager.forceUpdateCollectionBaseURI(fakeId, "ipfs://new");
    }

    // ────────────────────────────────────────────────────────────────
    // createTanda input validation
    // ────────────────────────────────────────────────────────────────

    function _createBadTanda(address token, uint256 contribution, uint256 interval, uint16 partCount, uint256 grace)
        internal
    {
        vm.prank(alice);
        manager.createTanda(token, contribution, interval, partCount, grace, 0, ITanda.TandaPrivacy.PUBLIC);
    }

    function test_createTanda_notAllowlistedTokenReverts() public {
        address fakeToken = address(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(TokenNotAllowlisted.selector, fakeToken));
        _createBadTanda(fakeToken, CONTRIBUTION, 1 days, 3, 1 days);
    }

    function test_createTanda_zeroContributionReverts() public {
        vm.expectRevert(ZeroAmount.selector);
        _createBadTanda(address(usdc), 0, 1 days, 3, 1 days);
    }

    function test_createTanda_payoutIntervalTooLowReverts() public {
        uint256 tooLow = 1 days - 1;
        vm.expectRevert(
            abi.encodeWithSelector(PayoutIntervalOutOfRange.selector, tooLow, uint256(1 days), uint256(30 days))
        );
        _createBadTanda(address(usdc), CONTRIBUTION, tooLow, 3, 1 days);
    }

    function test_createTanda_payoutIntervalTooHighReverts() public {
        uint256 tooHigh = 30 days + 1;
        vm.expectRevert(
            abi.encodeWithSelector(PayoutIntervalOutOfRange.selector, tooHigh, uint256(1 days), uint256(30 days))
        );
        _createBadTanda(address(usdc), CONTRIBUTION, tooHigh, 3, 1 days);
    }

    function test_createTanda_participantCountTooLowReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ParticipantCountOutOfRange.selector, uint16(1), uint16(2), uint16(50)));
        _createBadTanda(address(usdc), CONTRIBUTION, 1 days, 1, 1 days);
    }

    function test_createTanda_participantCountTooHighReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ParticipantCountOutOfRange.selector, uint16(51), uint16(2), uint16(50)));
        _createBadTanda(address(usdc), CONTRIBUTION, 1 days, 51, 1 days);
    }

    function test_createTanda_gracePeriodTooLowReverts() public {
        uint256 tooLow = 1 days - 1;
        vm.expectRevert(
            abi.encodeWithSelector(GracePeriodOutOfRange.selector, tooLow, uint256(1 days), uint256(7 days))
        );
        _createBadTanda(address(usdc), CONTRIBUTION, 1 days, 3, tooLow);
    }

    function test_createTanda_gracePeriodTooHighReverts() public {
        uint256 tooHigh = 7 days + 1;
        vm.expectRevert(
            abi.encodeWithSelector(GracePeriodOutOfRange.selector, tooHigh, uint256(1 days), uint256(7 days))
        );
        _createBadTanda(address(usdc), CONTRIBUTION, 1 days, 3, tooHigh);
    }

    function test_createTanda_whenPausedReverts() public {
        manager.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _createBadTanda(address(usdc), CONTRIBUTION, 1 days, 3, 1 days);
    }

    // ────────────────────────────────────────────────────────────────
    // Pause behavior
    // ────────────────────────────────────────────────────────────────

    function test_pauseThenUnpause_restoresCreateTanda() public {
        manager.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _createBadTanda(address(usdc), CONTRIBUTION, 1 days, 3, 1 days);

        manager.unpause();
        // Now succeeds.
        _enableCreate(alice, CONTRIBUTION);
        vm.prank(alice);
        uint256 tandaId =
            manager.createTanda(address(usdc), CONTRIBUTION, 1 days, 3, 1 days, 0, ITanda.TandaPrivacy.PUBLIC);
        assertGt(tandaId, 0, "tanda created after unpause");
    }

    function test_pause_doesNotBlockExistingActiveTanda() public {
        // Set up an active tanda first.
        (address tandaAddr,) = _createDefaultTanda(alice);
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = carol;
        _fillAndStart(tandaAddr, users, uint256(keccak256("seed_pause")));
        Tanda t = Tanda(tandaAddr);
        assertEq(uint8(t.state()), uint8(Tanda.TandaState.ACTIVE), "tanda active");

        // Pause the Manager.
        manager.pause();

        // Existing tanda's triggerPayout still works — it only reads
        // Manager via view calls (treasury(), isTanda()), no pause-guarded paths.
        _warpToNextCycle(tandaAddr);
        t.triggerPayout();
        assertEq(t.currentCycle(), 2, "cycle advanced while paused");
    }

    // ────────────────────────────────────────────────────────────────
    // NFT onlyTanda guards
    // ────────────────────────────────────────────────────────────────

    function test_passNFT_mint_revertsNonTanda() public {
        vm.expectRevert(CallerNotTanda.selector);
        vm.prank(alice);
        passNFT.mint(bob, 1);
    }

    function test_passNFT_markDefaulted_revertsNonTanda() public {
        vm.expectRevert(CallerNotTanda.selector);
        vm.prank(alice);
        passNFT.markDefaulted(bob, 1);
    }

    function test_receiptNFT_mintReceipt_revertsNonTanda() public {
        vm.expectRevert(CallerNotTanda.selector);
        vm.prank(alice);
        receiptNFT.mintReceipt(bob, 1, 1, 1);
    }

    function test_completionNFT_batchMint_revertsNonTanda() public {
        address[] memory recipients = new address[](1);
        recipients[0] = bob;
        vm.expectRevert(CallerNotTanda.selector);
        vm.prank(alice);
        completionNFT.batchMint(recipients, 1);
    }

    // ────────────────────────────────────────────────────────────────
    // NFT owner-only guards (OZ Ownable: OwnableUnauthorizedAccount)
    // ────────────────────────────────────────────────────────────────

    function test_passNFT_setBaseURI_revertsNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        passNFT.setBaseURI("ipfs://hack");
    }

    function test_receiptNFT_setDefaultFallbackBaseURI_revertsNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        receiptNFT.setDefaultFallbackBaseURI("ipfs://hack");
    }

    function test_completionNFT_setBaseURI_revertsNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        completionNFT.setBaseURI("ipfs://hack");
    }

    // Empty URI guards
    function test_passNFT_setBaseURI_emptyReverts() public {
        vm.expectRevert(EmptyBaseURI.selector);
        passNFT.setBaseURI("");
    }

    function test_completionNFT_setBaseURI_emptyReverts() public {
        vm.expectRevert(EmptyBaseURI.selector);
        completionNFT.setBaseURI("");
    }

    function test_receiptNFT_setDefaultFallbackBaseURI_emptyReverts() public {
        vm.expectRevert(EmptyBaseURI.selector);
        receiptNFT.setDefaultFallbackBaseURI("");
    }

    // ────────────────────────────────────────────────────────────────
    // Tanda onlyManager + initializer guards
    // ────────────────────────────────────────────────────────────────

    function test_tanda_assignPayoutOrder_revertsNonManager() public {
        (address tandaAddr,) = _createDefaultTanda(alice);
        Tanda t = Tanda(tandaAddr);

        // Need ACTIVE state for the modifier to even pass to onlyManager check.
        // Fill + start so state is ACTIVE.
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = carol;
        // Don't use _fillAndStart since assignPayoutOrder was already called by VRF.
        // Need a state where it would be reachable. Let's just call it as a non-manager
        // and confirm the onlyManager modifier fires FIRST (before state check).
        // Looking at the function: `onlyManager onlyInState(TandaState.ACTIVE)` — onlyManager
        // is the LEFT modifier so it runs first.
        vm.expectRevert(CallerNotManager.selector);
        vm.prank(alice);
        t.assignPayoutOrder(uint256(keccak256("seed")));
    }

    function test_tanda_initialize_doubleCallReverts() public {
        // Get a clone — created via createTanda already initialized once.
        (address tandaAddr,) = _createDefaultTanda(alice);

        // Try to call initialize again on the clone.
        ITanda.InitParams memory params = ITanda.InitParams({
            tandaId: 999,
            token: address(usdc),
            contributionAmount: 100,
            payoutInterval: 1 days,
            participantCount: 3,
            gracePeriod: 1 days,
            manager: address(manager),
            creator: alice,
            sponsoredCollectionId: 1,
            scheduledStart: 0,
            privacy: ITanda.TandaPrivacy.PUBLIC,
            passNFT: address(passNFT),
            receiptNFT: address(receiptNFT),
            completionNFT: address(completionNFT)
        });

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        ITanda(tandaAddr).initialize(params);
    }

    function test_tanda_implementation_initializeReverts() public {
        // The implementation contract has _disableInitializers() in its constructor
        // → initialize on the implementation directly should revert.
        ITanda.InitParams memory params = ITanda.InitParams({
            tandaId: 1,
            token: address(usdc),
            contributionAmount: 100,
            payoutInterval: 1 days,
            participantCount: 3,
            gracePeriod: 1 days,
            manager: address(manager),
            creator: alice,
            sponsoredCollectionId: 1,
            scheduledStart: 0,
            privacy: ITanda.TandaPrivacy.PUBLIC,
            passNFT: address(passNFT),
            receiptNFT: address(receiptNFT),
            completionNFT: address(completionNFT)
        });

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        ITanda(address(tandaImpl)).initialize(params);
    }
}
