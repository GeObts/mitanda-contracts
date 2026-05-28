// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ITandaManager {
    function requestRandomnessForTanda(uint256 tandaId) external;
    function getUsdcAddress() external view returns (address);
    function isTandaActive(uint256 tandaId) external view returns (bool);
}

contract Tanda is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum TandaState {
        OPEN,
        ACTIVE,
        COMPLETED
    }

    struct Participant {
        address payable addr;
        bool hasPaid;
        uint256 paidUntilCycle;
        bool isActive;
        uint256 payoutOrder;
        uint256 joinTimestamp;
    }

    uint256 public constant PENALTY_RATE = 15; // 15% penalty for late payments
    uint256 public immutable tandaId;
    uint256 public immutable contributionAmount;
    uint256 public immutable payoutInterval; // in seconds
    uint256 public immutable gracePeriod; // in seconds
    uint16 public immutable participantCount;
    ITandaManager public immutable manager;
    IERC20 public immutable usdcToken;
    address public immutable creator;

    TandaState public state;
    uint256 public startTimestamp;
    uint256 public currentCycle;
    uint256 public totalFunds;
    Participant[] public participants;
    mapping(address => uint256) public addressToParticipantIndex;

    bool public payoutOrderAssigned;
    uint256[] public payoutOrder;

    event ParticipantJoined(address indexed participant, uint256 timestamp);
    event PaymentMade(
        address indexed participant,
        uint256 cyclesPaid,
        uint256 amount,
        uint256 timestamp
    );
    event PayoutSent(
        address indexed recipient,
        uint256 amount,
        uint256 cycle,
        uint256 timestamp
    );
    event GracePeriodEntered(
        address indexed participant,
        uint256 cycle,
        uint256 timestamp
    );
    event ParticipantRemoved(
        address indexed participant,
        uint256 cycle,
        uint256 timestamp
    );
    event TandaStarted(uint256 startTimestamp, uint256 initialCycle);
    event PayoutOrderAssigned(uint256[] order, uint256 timestamp);
    event TandaCompleted(uint256 completionTimestamp);
    event TandaRestarted(uint256 restartTimestamp);

    modifier onlyManager() {
        require(msg.sender == address(manager), "Caller is not manager");
        _;
    }

    modifier onlyCreator() {
        require(msg.sender == address(creator), "Caller is not creator");
        _;
    }

    modifier onlyParticipant() {
        require(isParticipant(msg.sender), "Caller is not participant");
        _;
    }

    modifier onlyActiveTanda() {
        require(state == TandaState.ACTIVE, "Tanda is not active");
        _;
    }

    modifier onlyOpenTanda() {
        require(state == TandaState.OPEN, "Tanda is not open");
        _;
    }

    modifier onlyCompletedTanda() {
        require(state == TandaState.COMPLETED, "Tanda is not completed");
        _;
    }

    constructor(
        uint256 _tandaId,
        uint256 _contributionAmount,
        uint256 _payoutInterval,
        uint16 _participantCount,
        uint256 _gracePeriod,
        address _manager,
        address _creator
    ) {
        require(_contributionAmount > 0, "Contribution amount must be > 0");
        require(_payoutInterval > 0, "Payout interval must be > 0");
        require(_participantCount >= 2, "Minimum 2 participants required");
        require(_gracePeriod > 0, "Grace period must be > 0");
        require(_manager != address(0), "Invalid manager address");
        require(_creator != address(0), "Invalid creator address");

        tandaId = _tandaId;
        contributionAmount = _contributionAmount;
        payoutInterval = _payoutInterval;
        participantCount = _participantCount;
        gracePeriod = _gracePeriod;
        manager = ITandaManager(_manager);
        usdcToken = IERC20(manager.getUsdcAddress());
        state = TandaState.OPEN;
        creator = _creator;
    }

    /**
     * @notice Join the Tanda by contributing USDC
     * @dev Transfers USDC from participant to contract
     */
    function join() external onlyOpenTanda {
        require(participants.length < participantCount, "Tanda is full");
        require(!isParticipant(msg.sender), "Already joined this tanda");

        // Transfer USDC from participant to contract
        usdcToken.safeTransferFrom(
            msg.sender,
            address(this),
            contributionAmount
        );

        participants.push(
            Participant({
                addr: payable(msg.sender),
                hasPaid: true,
                paidUntilCycle: 1,
                isActive: true,
                payoutOrder: 0,
                joinTimestamp: block.timestamp
            })
        );
        addressToParticipantIndex[msg.sender] = participants.length;
        totalFunds += contributionAmount;

        emit ParticipantJoined(msg.sender, block.timestamp);

        if (participants.length == participantCount) {
            _startTanda();
        }
    }

    /**
     * @notice Make payment for future cycles
     * @param cyclesToPay Number of cycles to pay for
     */
    function makePayment(
        uint256 cyclesToPay
    ) external onlyParticipant onlyActiveTanda {
        require(cyclesToPay > 0, "Must pay for at least 1 cycle");

        uint256 participantIndex = addressToParticipantIndex[msg.sender] - 1;
        Participant storage participant = participants[participantIndex];

        require(participant.isActive, "Participant is inactive");

        uint256 maxCyclesCanPay = participantCount - participant.paidUntilCycle;
        require(
            cyclesToPay <= maxCyclesCanPay,
            "Cannot pay beyond total cycles"
        );

        uint256 totalPayment = contributionAmount * cyclesToPay;
        usdcToken.safeTransferFrom(msg.sender, address(this), totalPayment);

        participant.paidUntilCycle += cyclesToPay;
        participant.hasPaid = true;
        totalFunds += totalPayment;

        emit PaymentMade(
            msg.sender,
            cyclesToPay,
            totalPayment,
            block.timestamp
        );
    }

    /**
     * @notice Trigger payout for current cycle
     * @dev Can be called by anyone when conditions are met
     */
    function triggerPayout() external nonReentrant onlyActiveTanda {
        // Check if the current recipient is calling
        address payable recipient = participants[payoutOrder[currentCycle - 1]].addr;

        // Check if payout time has arrived
        uint256 nextPayoutTime = startTimestamp +
            (currentCycle * payoutInterval);
        require(block.timestamp >= nextPayoutTime, "Payout time not reached");

        // Check all participants are paid up
        require(_allParticipantsPaid(), "Not all participants have paid");
        require(payoutOrderAssigned, "Payout order not assigned");

        uint256 payoutAmount = contributionAmount * participantCount;
        require(
            usdcToken.balanceOf(address(this)) >= payoutAmount,
            "Insufficient contract balance"
        );

        // Update state before transfer
        currentCycle++;
        totalFunds -= payoutAmount;

        usdcToken.safeTransfer(recipient, payoutAmount);

        emit PayoutSent(
            recipient,
            payoutAmount,
            currentCycle - 1,
            block.timestamp
        );

        // Complete tanda if all cycles are done
        if (currentCycle > participantCount) {
            state = TandaState.COMPLETED;
            emit TandaCompleted(block.timestamp);
        }
    }

    // ==================== Manager Functions ====================

    function enterGracePeriod(
        address participant
    ) external onlyCreator onlyActiveTanda {
        uint256 participantIndex = addressToParticipantIndex[participant] - 1;
        require(participantIndex < participants.length, "Invalid participant");

        Participant storage p = participants[participantIndex];
        require(p.isActive, "Participant is inactive");
        require(p.paidUntilCycle < currentCycle,
            "Participant not in default"
        );

        emit GracePeriodEntered(participant, currentCycle, block.timestamp);
    }

    function removeDefaultedParticipant(
        address participant
    ) external onlyCreator onlyActiveTanda {
        uint256 participantIndex = addressToParticipantIndex[participant] - 1;
        require(participantIndex < participants.length, "Invalid participant");

        Participant storage p = participants[participantIndex];
        require(p.isActive, "Participant is inactive");
        require(p.paidUntilCycle < currentCycle,
            "Participant not in default"
        );

        // p.isActive = false;s
        emit ParticipantRemoved(participant, currentCycle, block.timestamp);
    }

    function assignPayoutOrder(uint256 randomSeed) external onlyManager {
        require(!payoutOrderAssigned, "Payout order already assigned");
        require(
            participants.length == participantCount,
            "Not all participants joined"
        );

        payoutOrder = new uint256[](participantCount);

        // Initialize with sequential order
        for (uint256 i = 0; i < participantCount; i++) {
            payoutOrder[i] = i;
        }

        // Fisher-Yates shuffle
        for (uint256 i = participantCount - 1; i > 0; i--) {
            uint256 j = uint256(keccak256(abi.encode(randomSeed, i))) % (i + 1);
            (payoutOrder[i], payoutOrder[j]) = (payoutOrder[j], payoutOrder[i]);
        }

        // Update participant payoutOrder values
        for (uint256 i = 0; i < participantCount; i++) {
            participants[payoutOrder[i]].payoutOrder = i;
        }

        payoutOrderAssigned = true;
        emit PayoutOrderAssigned(payoutOrder, block.timestamp);
    }

    /**
     * @notice Restart the tanda after completion
     * @dev Can only be called by manager after tanda is completed
     */
    function restartTanda() external onlyCreator onlyCompletedTanda {
        // Reset state
        state = TandaState.OPEN;
        startTimestamp = 0;
        currentCycle = 0;
        totalFunds = 0;
        payoutOrderAssigned = false;
        delete payoutOrder;

        // Reset participants
        for (uint256 i = 0; i < participants.length; i++) {
            participants[i].hasPaid = false;
            participants[i].paidUntilCycle = 0;
            participants[i].isActive = true;
            participants[i].payoutOrder = 0;
        }

        emit TandaRestarted(block.timestamp);
    }

    // ==================== Internal Functions ====================

    function _startTanda() private {
        state = TandaState.ACTIVE;
        startTimestamp = block.timestamp;
        currentCycle = 1;

        emit TandaStarted(startTimestamp, currentCycle);
        manager.requestRandomnessForTanda(tandaId);
    }

    function _allParticipantsPaid() internal view returns (bool) {
        for (uint256 i = 0; i < participants.length; i++) {
            if (participants[i].isActive && participants[i].paidUntilCycle < currentCycle) {
                return false;
            }
        }
        return true;
    }

    // ==================== View Functions ====================

    /**
     * @notice Check if address is a participant
     * @param _address Address to check
     * @return True if participant, false otherwise
     */
    function isParticipant(address _address) public view returns (bool) {
        return addressToParticipantIndex[_address] != 0;
    }

    /**
     * @notice Get participant details by address
     * @param _address Participant address
     * @return Participant struct
     */
    function getParticipant(
        address _address
    ) external view returns (Participant memory) {
        require(isParticipant(_address), "Address is not participant");
        return participants[addressToParticipantIndex[_address] - 1];
    }

    /**
     * @notice Get all participants
     * @return Array of Participant structs
     */
    function getAllParticipants() external view returns (Participant[] memory) {
        return participants;
    }

    /**
     * @notice Get current cycle details
     * @return cycleNumber Current cycle number
     * @return payoutAddress Address to receive next payout
     * @return payoutAmount Amount to be paid out
     */
    function getCurrentCycleInfo()
        external
        view
        returns (
            uint256 cycleNumber,
            address payoutAddress,
            uint256 payoutAmount
        )
    {
        cycleNumber = currentCycle;
        if (payoutOrderAssigned && participants.length > 0) {
            payoutAddress = participants[payoutOrder[currentCycle - 1]].addr;
            payoutAmount = contributionAmount * participantCount;
        }
    }

    /**
     * @notice Get Tanda summary information
     * @return currentState Current Tanda state
     * @return cycle Current cycle number
     * @return participantsCount Number of participants
     * @return funds Total USDC in contract
     * @return nextPayout Timestamp of next payout
     */
    function getTandaSummary()
        external
        view
        returns (
            TandaState currentState,
            uint256 cycle,
            uint256 participantsCount,
            uint256 funds,
            uint256 nextPayout
        )
    {
        currentState = state;
        cycle = currentCycle;
        participantsCount = participantCount;
        funds = totalFunds;
        nextPayout = state == TandaState.ACTIVE
            ? startTimestamp + (currentCycle * payoutInterval)
            : 0;
    }

    /**
     * @notice Check if participant is in good standing
     * @param _address Participant address
     * @return True if paid up, false otherwise
     */
    function isParticipantInGoodStanding(
        address _address
    ) external view returns (bool) {
        if (!isParticipant(_address)) return false;
        Participant memory p = participants[
            addressToParticipantIndex[_address] - 1
        ];
        return p.isActive && p.hasPaid && p.paidUntilCycle > currentCycle;
    }

    /**
     * @notice Get the payout order array
     * @dev Only returns data if payoutOrderAssigned is true
     * @return Array of participant indices in payout order
     */
    function getPayoutOrder() external view returns (uint256[] memory) {
        require(payoutOrderAssigned, "Payout order not assigned");
        return payoutOrder;
    }
}
