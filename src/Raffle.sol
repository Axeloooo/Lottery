// SPDX-License-Identifier: Apache License 2.0
pragma solidity 0.8.19;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/**
 * @title A simple Raffle contract
 * @author Axel Omar Sanchez Peralta (axelshz@gmail.com)
 * @notice This contract is for creating a sample raffle
 * @dev Implements Chainlink VRFv2.5
 */
contract Raffle is VRFConsumerBaseV2Plus {
    /**
     * @dev Errors
     */
    error Raffle__SendMoreToEnterRaffle();
    error Raffle__TransferFailed();
    error Raffle__RaffleNotOpen();
    error Raffle__NothingToWithdraw();
    error Raffle__UpkeepNotNeeded(
        uint256 pot,
        uint256 playersLength,
        uint256 raffleState
    );

    /**
     * @dev Type Declarations
     */
    enum RaffleState {
        OPEN,
        CALCULATING
    }

    /**
     * @dev State Variables
     */
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private constant NUM_WORDS = 1;
    uint256 private immutable i_entranceFee;
    uint256 private immutable i_interval;
    bytes32 private immutable i_keyHash;
    uint256 private immutable i_subscriptionId;
    uint32 private immutable i_callbackGasLimit;
    /// @dev Players are stored per round so a new round never has to clear
    /// the previous array. Clearing it inside fulfillRandomWords cost one
    /// SSTORE per entry and could exceed the VRF callback gas limit.
    mapping(uint256 round => address payable[] players) private s_players;
    uint256 private s_round;
    /// @dev Entrance fees collected in the current round. Kept separately from
    /// address(this).balance because unclaimed winnings also sit in the contract.
    uint256 private s_pot;
    /// @dev Pull payments: winners withdraw their prize, so a winner that
    /// cannot receive ETH can't make the VRF callback revert.
    mapping(address winner => uint256 amount) private s_pendingWithdrawals;
    uint256 private s_lastTimeStamp;
    address private s_recentWinner;
    RaffleState private s_raffleState;

    /**
     * @dev Events
     */
    event RaffleEntered(address indexed player);
    event WinnerPicked(address indexed winner);
    event RequestedRaffleWinner(uint256 indexed requestId);
    event WinningsWithdrawn(address indexed winner, uint256 amount);

    constructor(
        uint256 entranceFee,
        uint256 interval,
        address vrfCoordinator,
        bytes32 gasLane,
        uint256 subscriptionId,
        uint32 callbackGasLimit
    ) VRFConsumerBaseV2Plus(vrfCoordinator) {
        i_entranceFee = entranceFee;
        i_interval = interval;
        s_lastTimeStamp = block.timestamp;
        i_keyHash = gasLane;
        i_subscriptionId = subscriptionId;
        i_callbackGasLimit = callbackGasLimit;
        s_raffleState = RaffleState.OPEN;
    }

    function enterRaffle() external payable {
        if (msg.value < i_entranceFee) {
            revert Raffle__SendMoreToEnterRaffle();
        }
        if (s_raffleState != RaffleState.OPEN) {
            revert Raffle__RaffleNotOpen();
        }
        s_players[s_round].push(payable(msg.sender));
        s_pot += msg.value;
        emit RaffleEntered(msg.sender);
    }

    /**
     * @dev This is the function that the Chainlink nodes will call to see
     * if the lottery is ready to have a winner picked.
     * The following should be true in order for upkeepNeeded to be true:
     * 1. The time interval has passed between raffle runs
     * 2. The lottery is open
     * 3. The current round has collected entrance fees
     * 4. Implicitly, your subscription has LINK
     * @param - ignored
     * @return upkeepNeeded - true if it's time to restart the lottery
     * @return - ignored
     */
    function checkUpkeep(
        bytes memory /* checkData */
    ) public view returns (bool upkeepNeeded, bytes memory /* performData */) {
        bool timeHasPassed = (block.timestamp - s_lastTimeStamp) >= i_interval;
        bool isOpen = s_raffleState == RaffleState.OPEN;
        bool hasBalance = s_pot > 0;
        bool hasPlayers = s_players[s_round].length > 0;
        upkeepNeeded = timeHasPassed && isOpen && hasBalance && hasPlayers;
        return (upkeepNeeded, "");
    }

    function performUpkeep(bytes calldata /* performData */) external {
        (bool upkeepNeeded, ) = checkUpkeep("");
        if (!upkeepNeeded) {
            revert Raffle__UpkeepNotNeeded(
                s_pot,
                s_players[s_round].length,
                uint256(s_raffleState)
            );
        }

        s_raffleState = RaffleState.CALCULATING;

        VRFV2PlusClient.RandomWordsRequest memory request = VRFV2PlusClient
            .RandomWordsRequest({
                keyHash: i_keyHash,
                subId: i_subscriptionId,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit: i_callbackGasLimit,
                numWords: NUM_WORDS,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                )
            });

        uint256 requestId = s_vrfCoordinator.requestRandomWords(request);
        emit RequestedRaffleWinner(requestId);
    }

    function fulfillRandomWords(
        uint256 /*requestId*/,
        uint256[] calldata randomWords
    ) internal override {
        // Constant gas regardless of the number of players, and no external
        // call: this callback must not revert, because VRF v2.5 does not retry.
        address payable[] storage players = s_players[s_round];
        uint256 indexOfWinner = randomWords[0] % players.length;
        address payable recentWinner = players[indexOfWinner];
        uint256 prize = s_pot;

        s_recentWinner = recentWinner;
        s_pendingWithdrawals[recentWinner] += prize;
        s_pot = 0;
        s_round++;
        s_raffleState = RaffleState.OPEN;
        s_lastTimeStamp = block.timestamp;

        emit WinnerPicked(recentWinner);
    }

    /**
     * @notice Sends the caller every prize they have won and not yet withdrawn.
     */
    function withdraw() external {
        uint256 amount = s_pendingWithdrawals[msg.sender];
        if (amount == 0) {
            revert Raffle__NothingToWithdraw();
        }
        s_pendingWithdrawals[msg.sender] = 0;
        emit WinningsWithdrawn(msg.sender, amount);

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        if (!success) {
            revert Raffle__TransferFailed();
        }
    }

    /**
     * @dev Getter Functions
     */
    function getEntranceFee() external view returns (uint256) {
        return i_entranceFee;
    }

    function getRaffleState() external view returns (RaffleState) {
        return s_raffleState;
    }

    function getPlayer(uint256 indexOfPlayer) external view returns (address) {
        return s_players[s_round][indexOfPlayer];
    }

    function getNumberOfPlayers() external view returns (uint256) {
        return s_players[s_round].length;
    }

    function getRound() external view returns (uint256) {
        return s_round;
    }

    function getPot() external view returns (uint256) {
        return s_pot;
    }

    function getPendingWithdrawal(
        address winner
    ) external view returns (uint256) {
        return s_pendingWithdrawals[winner];
    }

    function getLastTimeStamp() external view returns (uint256) {
        return s_lastTimeStamp;
    }

    function getRecentWinner() external view returns (address) {
        return s_recentWinner;
    }
}
