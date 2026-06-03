// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test, Vm} from "forge-std/Test.sol";

import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";

import {MockERC20} from "../mocks/MockERC20.sol";

import {TandaManager} from "../../src/TandaManager.sol";
import {Tanda} from "../../src/Tanda.sol";
import {ITanda} from "../../src/interfaces/ITanda.sol";
import {MitandaPassNFT} from "../../src/MitandaPassNFT.sol";
import {MitandaReceiptNFT} from "../../src/MitandaReceiptNFT.sol";
import {MitandaCompletionNFT} from "../../src/MitandaCompletionNFT.sol";

/// @title  MitandaTestBase
/// @notice Shared setUp + helpers for every Mi Tanda test. Deploys the
///         full system (mock VRF + USDC, Tanda implementation, three
///         NFT singletons, Manager) and wires it together so individual
///         tests can focus on behavior.
/// @dev    Circular dependency between Manager and the NFTs is resolved
///         by predicting Manager's CREATE1 address via
///         `vm.computeCreateAddress(deployer, nonce + 3)` before
///         deploying the NFTs. Production deploy script should mirror
///         this — recommended pattern is CREATE2 with a deterministic
///         salt for cross-chain identical Manager addresses.
abstract contract MitandaTestBase is Test {
    // ─── Deployed system ───────────────────────────────────────────────
    TandaManager internal manager;
    Tanda internal tandaImpl;
    MitandaPassNFT internal passNFT;
    MitandaReceiptNFT internal receiptNFT;
    MitandaCompletionNFT internal completionNFT;
    MockERC20 internal usdc;
    VRFCoordinatorV2_5Mock internal vrfCoordinator;

    // ─── Test config ───────────────────────────────────────────────────
    uint256 internal subId;
    bytes32 internal constant GAS_LANE = keccak256("test-gas-lane");
    uint32 internal constant CALLBACK_GAS_LIMIT = 500_000;
    address internal constant TREASURY = address(0xBEEF);
    address internal owner = address(this);

    // ─── Default tanda parameters ──────────────────────────────────────
    uint256 internal constant DEFAULT_CONTRIBUTION = 100 * 10 ** 6; // 100 USDC
    uint256 internal constant DEFAULT_PAYOUT_INTERVAL = 1 days;
    uint16 internal constant DEFAULT_PARTICIPANT_COUNT = 3;
    uint256 internal constant DEFAULT_GRACE_PERIOD = 1 days;

    // ─── Default collection ────────────────────────────────────────────
    address internal constant SPONSOR_ROYALTY_RECEIVER = address(0xCAFE);
    uint96 internal constant SPONSOR_ROYALTY_BPS = 500; // 5%

    // ─── Test users ────────────────────────────────────────────────────
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal eve = makeAddr("eve");

    function setUp() public virtual {
        // 1. VRF coordinator mock — args are placeholder fees for tests.
        vrfCoordinator = new VRFCoordinatorV2_5Mock(
            0.1 ether, // base fee
            1 gwei, // gas price
            4e15 // wei per unit LINK (~0.004 ETH per LINK)
        );

        // 2. Create + fund a VRF subscription. Sub owner = address(this).
        subId = vrfCoordinator.createSubscription();
        vrfCoordinator.fundSubscription(subId, 1000 ether); // LINK balance
        vm.deal(address(this), 100 ether);
        vrfCoordinator.fundSubscriptionWithNative{value: 50 ether}(subId);

        // 3. Mock USDC (6 decimals — matches mainnet USDC).
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // 4. Tanda implementation (constructor disables initializers).
        tandaImpl = new Tanda();

        // 5. Predict Manager's CREATE1 address. The next 4 deploys are
        //    passNFT, receiptNFT, completionNFT, Manager (in order),
        //    so Manager will be at nonce + 3 relative to here.
        uint256 nonceNow = vm.getNonce(address(this));
        address predictedManager = vm.computeCreateAddress(address(this), nonceNow + 3);

        // 6. NFTs reference the predicted Manager address.
        passNFT = new MitandaPassNFT(predictedManager, owner);
        receiptNFT = new MitandaReceiptNFT(predictedManager, owner, "ipfs://default-fallback");
        completionNFT = new MitandaCompletionNFT(predictedManager, owner);

        // 7. Deploy Manager. Its actual address MUST match the prediction
        //    or every NFT call from any tanda will fail forever.
        // _initialOwner = address(this): test contract is both deployer
        // and intended owner, so the constructor skips transferOwnership
        // (Chainlink reverts on self-transfer). Same effective behavior
        // as the pre-_initialOwner version.
        manager = new TandaManager(
            address(tandaImpl),
            address(vrfCoordinator),
            subId,
            GAS_LANE,
            CALLBACK_GAS_LIMIT,
            TREASURY,
            address(passNFT),
            address(receiptNFT),
            address(completionNFT),
            address(this)
        );
        require(address(manager) == predictedManager, "MitandaTestBase: Manager address prediction failed");

        // 8. Register Manager as a VRF consumer on the subscription.
        vrfCoordinator.addConsumer(subId, address(manager));

        // 9. Allowlist the mock USDC for tanda creation.
        manager.allowlistToken(address(usdc));

        // 10. Register and activate a default sponsored collection so
        //     receipts mint with non-fallback art by default.
        uint256 collId = manager.registerCollection(
            "Mi Tanda Test Collection", "ipfs://test-collection", SPONSOR_ROYALTY_RECEIVER, SPONSOR_ROYALTY_BPS
        );
        manager.setActiveCollection(collId);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Mint `amount` USDC to `user` and prank-approve `spender`.
    function _fundAndApprove(address user, uint256 amount, address spender) internal {
        usdc.mint(user, amount);
        vm.prank(user);
        usdc.approve(spender, amount);
    }

    /// @notice Fund a creator and approve the Manager for the charge-at-create
    ///         (contribution + insurance premium). Call before any successful
    ///         `createTanda` — the creator is auto-enrolled as participant #1
    ///         and the Manager pulls their first cycle's funds at creation.
    function _enableCreate(address creator, uint256 contribution) internal {
        uint256 premium = (contribution * manager.INSURANCE_BPS()) / manager.BPS_DENOMINATOR();
        _fundAndApprove(creator, contribution + premium, address(manager));
    }

    /// @notice Create a default PUBLIC tanda from `creator`.
    /// @return tandaAddr Address of the new Tanda clone.
    /// @return tandaId   ID assigned by the Manager.
    function _createDefaultTanda(address creator) internal returns (address tandaAddr, uint256 tandaId) {
        _enableCreate(creator, DEFAULT_CONTRIBUTION);
        vm.prank(creator);
        tandaId = manager.createTanda(
            address(usdc),
            DEFAULT_CONTRIBUTION,
            DEFAULT_PAYOUT_INTERVAL,
            DEFAULT_PARTICIPANT_COUNT,
            DEFAULT_GRACE_PERIOD,
            0, // scheduledStart = 0 → auto-start when full
            ITanda.TandaPrivacy.PUBLIC
        );
        tandaAddr = manager.tandaIdToAddress(tandaId);
    }

    /// @notice Fund, approve, and prank `user` to join a PUBLIC tanda.
    ///         Handles contribution + insurance premium automatically.
    ///         Idempotent: a no-op if `user` is already a participant (e.g. the
    ///         creator, who is auto-enrolled as participant #1 at create-time).
    function _joinTanda(address tandaAddr, address user) internal {
        Tanda t = Tanda(tandaAddr);
        if (t.isParticipant(user)) return;
        uint256 c = t.contributionAmount();
        uint256 premium = (c * t.INSURANCE_BPS()) / t.BPS_DENOMINATOR();
        uint256 charge = c + premium;

        _fundAndApprove(user, charge, tandaAddr);

        vm.prank(user);
        t.join();
    }

    /// @notice Deliver a VRF callback to Manager with a deterministic seed.
    /// @param  requestId The Manager's VRF request ID (capture from the
    ///                   `RandomnessRequested(tandaId, requestId)` log).
    /// @param  seed      The single random word to forward.
    function _fulfillVRF(uint256 requestId, uint256 seed) internal {
        uint256[] memory words = new uint256[](1);
        words[0] = seed;
        vrfCoordinator.fulfillRandomWordsWithOverride(requestId, address(manager), words);
    }

    /// @notice Convenience: capture the most recent `RandomnessRequested`
    ///         emitted by Manager and immediately fulfill it. Requires
    ///         the test to have called `vm.recordLogs()` before the
    ///         action that triggers the VRF request.
    function _captureAndFulfillVRF(uint256 seed) internal returns (uint256 requestId) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("RandomnessRequested(uint256,uint256)");
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory log = logs[i - 1];
            if (log.emitter == address(manager) && log.topics[0] == sig) {
                // event RandomnessRequested(uint256 indexed tandaId, uint256 indexed requestId)
                requestId = uint256(log.topics[2]);
                _fulfillVRF(requestId, seed);
                return requestId;
            }
        }
        revert("MitandaTestBase: no RandomnessRequested log");
    }

    /// @dev Fills a tanda to capacity (joining all `users`), which triggers
    ///      _startTanda → VRF request on the final join, then fulfills the
    ///      VRF request with the given seed. Handles vm.recordLogs()
    ///      internally so individual tests can't forget it. The `users`
    ///      array length must equal the tanda's participantCount.
    ///      Returns the requestId that was fulfilled.
    function _fillAndStart(address tandaAddr, address[] memory users, uint256 seed)
        internal
        returns (uint256 requestId)
    {
        Tanda t = Tanda(tandaAddr);
        // Join non-participants until the tanda fills. The creator is already
        // enrolled (seat #1) and is skipped by _joinTanda. We record logs
        // around whichever join actually fills the tanda (triggering the VRF
        // request), regardless of its position in `users`.
        for (uint256 i = 0; i < users.length; i++) {
            if (t.isParticipant(users[i])) continue;
            bool willFill = t.activeParticipantCount() + 1 == t.participantCount();
            if (willFill) vm.recordLogs();
            _joinTanda(tandaAddr, users[i]);
            if (willFill) {
                requestId = _captureAndFulfillVRF(seed);
                return requestId;
            }
        }
        revert("MitandaTestBase: tanda never filled (users < remaining seats)");
    }

    /// @notice Warp `block.timestamp` to the moment the current cycle's
    ///         payout becomes eligible. Tanda must already be ACTIVE.
    function _warpToNextCycle(address tandaAddr) internal {
        Tanda t = Tanda(tandaAddr);
        uint256 payoutTime = t.startTimestamp() + t.currentCycle() * t.payoutInterval();
        vm.warp(payoutTime);
    }
}
