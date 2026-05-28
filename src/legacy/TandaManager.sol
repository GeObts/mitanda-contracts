// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Tanda.sol";

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

struct GeneralInfo {
    uint256 tandaId;
    uint256 contributionAmount;
    uint256 payoutInterval;
    uint16 participantCount;
    uint256 gracePeriod;
    address creator;
    address usdcTokenAddress;
    address managerAddress;
    address tandaAddress;
}

struct CurrentStatus {
    Tanda.TandaState state;
    uint256 currentCycle;
    uint256 totalParticipants;
    uint256 totalFunds;
    uint256 nextPayoutTimestamp;
    uint256 startTimestamp;
    bool payoutOrderAssigned;
    bool isActive;
    bool isOpen;
    bool isCompleted;
    uint256 participantListLength;
}

contract TandaManager is VRFConsumerBaseV2Plus {
    uint256 private subscriptionId;
    bytes32 private gasLane;
    uint32 private callbackGasLimit;
    uint16 private requestConfirmations = 3;
    uint32 private numWords = 1;
    bool private nativePayment = true;

    address public immutable usdcAddress;
    uint256 public nextTandaId;

    mapping(uint256 => address) public tandaIdToAddress;
    mapping(uint256 => uint256) public vrfRequestIdToTandaId;
    mapping(uint256 => bool) public activeTandas;

    event TandaCreated(
        uint256 indexed tandaId,
        address indexed tandaAddress,
        uint256 contributionAmount,
        uint256 payoutInterval,
        uint16 participantCount,
        uint256 gracePeriod,
        address creator
    );
    event RandomnessRequested(
        uint256 indexed tandaId,
        uint256 indexed requestId
    );
    event PayoutOrderAssigned(uint256 indexed tandaId);
    event VRFConfigUpdated(
        uint256 newSubscriptionId,
        bytes32 newGasLane,
        uint32 newCallbackGasLimit,
        uint16 newRequestConfirmations,
        uint32 newNumWords,
        bool newNativePayment
    );

    constructor(
        address _vrfCoordinator,
        uint256 _subscriptionId,
        bytes32 _gasLane,
        uint32 _callbackGasLimit,
        address _usdcAddress
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        require(_vrfCoordinator != address(0), "Invalid VRF coordinator");
        require(_usdcAddress != address(0), "Invalid USDC address");

        subscriptionId = _subscriptionId;
        gasLane = _gasLane;
        callbackGasLimit = _callbackGasLimit;
        usdcAddress = _usdcAddress;
    }

    /**
     * @notice Update VRF configuration parameters
     * @param _subscriptionId New subscription ID
     * @param _gasLane New gas lane key hash
     * @param _callbackGasLimit New callback gas limit
     * @param _requestConfirmations New number of request confirmations
     * @param _numWords New number of random words to request
     * @param _nativePayment Whether to pay for VRF in native token or LINK
     */
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
            _subscriptionId,
            _gasLane,
            _callbackGasLimit,
            _requestConfirmations,
            _numWords,
            _nativePayment
        );
    }

    /**
     * @notice Create a new Tanda
     * @param _contributionAmount USDC amount each participant must contribute
     * @param _payoutInterval Time between payouts in seconds
     * @param _participantCount Number of participants needed
     * @param _gracePeriod Grace period for late payments in seconds
     * @return tandaId ID of the newly created Tanda
     */
    function createTanda(
        uint256 _contributionAmount,
        uint256 _payoutInterval,
        uint16 _participantCount,
        uint256 _gracePeriod
    ) external returns (uint256) {
        require(
            _contributionAmount >= 10 * 10 ** 6,
            "Minimum contribution 10 USDC"
        );
        require(_payoutInterval >= 1 days, "Minimum interval 1 day");
        require(_payoutInterval <= 30 days, "Maximum interval 30 days");
        require(_participantCount >= 2, "Minimum 2 participants");
        require(_participantCount <= 50, "Maximum 50 participants");
        require(_gracePeriod >= 1 days, "Minimum grace period 1 day");
        require(_gracePeriod <= 7 days, "Maximum grace period 7 days");

        uint256 tandaId = nextTandaId++;
        Tanda tanda = new Tanda(
            tandaId,
            _contributionAmount,
            _payoutInterval,
            _participantCount,
            _gracePeriod,
            address(this),
            msg.sender
        );

        tandaIdToAddress[tandaId] = address(tanda);
        activeTandas[tandaId] = true;

        emit TandaCreated(
            tandaId,
            address(tanda),
            _contributionAmount,
            _payoutInterval,
            _participantCount,
            _gracePeriod,
            msg.sender
        );
        return tandaId;
    }

    /**
     * @notice Request randomness for payout order assignment
     * @dev Only callable by Tanda contracts
     * @param tandaId ID of the Tanda requesting randomness
     */
    function requestRandomnessForTanda(uint256 tandaId) external {
        require(tandaIdToAddress[tandaId] == msg.sender, "Caller is not Tanda");
        require(activeTandas[tandaId], "Tanda is not active");

        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: gasLane,
                subId: subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: numWords,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: nativePayment})
                )
            })
        );

        vrfRequestIdToTandaId[requestId] = tandaId;

        emit RandomnessRequested(tandaId, requestId);
    }

    /**
     * @notice Request randomness for payout order assignment (test function)
     */
    function requestRandomnessForTandaTest(
        uint256 tandaId
    ) public returns (uint256) {
        require(activeTandas[tandaId], "Tanda is not active");

        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: gasLane,
                subId: subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: numWords,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: nativePayment})
                )
            })
        );

        vrfRequestIdToTandaId[requestId] = tandaId;

        return requestId;
    }

    /**
     * @notice Callback function used by VRF Coordinator
     * @param requestId ID of the randomness request
     * @param randomWords Array of random values
     */
    function fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal override {
        uint256 tandaId = vrfRequestIdToTandaId[requestId];
        require(tandaIdToAddress[tandaId] != address(0), "Invalid Tanda ID");

        Tanda tanda = Tanda(tandaIdToAddress[tandaId]);
        tanda.assignPayoutOrder(randomWords[0]);

        emit PayoutOrderAssigned(tandaId);
    }

    // ==================== View Functions ====================

    /**
     * @notice Get USDC token address
     * @return USDC contract address
     */
    function getUsdcAddress() external view returns (address) {
        return usdcAddress;
    }

    /**
     * @notice Check if Tanda is active
     * @param tandaId ID of the Tanda to check
     * @return True if active, false otherwise
     */
    function isTandaActive(uint256 tandaId) external view returns (bool) {
        return activeTandas[tandaId];
    }

    /**
     * @notice Get Tanda contract address by ID
     * @param tandaId ID of the Tanda
     * @return Tanda contract address
     */
    function getTandaAddress(uint256 tandaId) external view returns (address) {
        return tandaIdToAddress[tandaId];
    }

    /**
     * @notice Get all active Tanda IDs
     * @return Array of active Tanda IDs
     */
    function getActiveTandaIds() external view returns (uint256[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < nextTandaId; i++) {
            if (activeTandas[i]) {
                count++;
            }
        }

        uint256[] memory activeIds = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < nextTandaId; i++) {
            if (activeTandas[i]) {
                activeIds[index] = i;
                index++;
            }
        }
        return activeIds;
    }

    /**
     * @notice Get comprehensive Tanda data for frontend display
     * @param tandaId ID of the Tanda
     * @return generalInfo Struct containing general Tanda information
     * @return currentStatus Struct containing current status information
     * @return payoutOrderInfo Array of payout order (if assigned)
     */
    function getTandaData(
        uint256 tandaId
    )
        external
        view
        returns (
            GeneralInfo memory generalInfo,
            CurrentStatus memory currentStatus,
            uint256[] memory payoutOrderInfo
        )
    {
        address tandaAddress = tandaIdToAddress[tandaId];
        require(tandaAddress != address(0), "Invalid Tanda ID");

        Tanda tanda = Tanda(tandaAddress);

        // General information (static)
        generalInfo = GeneralInfo({
            tandaId: tandaId,
            contributionAmount: tanda.contributionAmount(),
            payoutInterval: tanda.payoutInterval(),
            participantCount: tanda.participantCount(),
            gracePeriod: tanda.gracePeriod(),
            creator: tanda.creator(),
            usdcTokenAddress: address(tanda.usdcToken()),
            managerAddress: address(tanda.manager()),
            tandaAddress: tandaAddress
        });

        // Current status (dynamic)
        (
            Tanda.TandaState state,
            uint256 cycle,
            uint256 participantsCount,
            uint256 funds,
            uint256 nextPayout
        ) = tanda.getTandaSummary();

        // Participants information
        Tanda.Participant[] memory participants = tanda.getAllParticipants();

        currentStatus = CurrentStatus({
            state: state,
            currentCycle: cycle,
            totalParticipants: participantsCount,
            totalFunds: funds,
            nextPayoutTimestamp: nextPayout,
            startTimestamp: tanda.startTimestamp(),
            payoutOrderAssigned: tanda.payoutOrderAssigned(),
            isActive: tanda.state() == Tanda.TandaState.ACTIVE,
            isOpen: tanda.state() == Tanda.TandaState.OPEN,
            isCompleted: tanda.state() == Tanda.TandaState.COMPLETED,
            participantListLength: participants.length
        });

        // Payout order information (if assigned)
        payoutOrderInfo = tanda.payoutOrderAssigned()
            ? tanda.getPayoutOrder()
            : new uint256[](0);
    }

    /**
     * @notice Get current VRF configuration
     * @return Current subscription ID
     * @return Current gas lane
     * @return Current callback gas limit
     * @return Current request confirmations
     * @return Current number of words
     * @return Current native payment setting
     */
    function getVRFConfig()
        external
        view
        returns (uint256, bytes32, uint32, uint16, uint32, bool)
    {
        return (
            subscriptionId,
            gasLane,
            callbackGasLimit,
            requestConfirmations,
            numWords,
            nativePayment
        );
    }
}
