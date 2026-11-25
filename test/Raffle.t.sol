// SPDX-License-Identifier: Apache License 2.0
pragma solidity 0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {Raffle} from "../src/Raffle.sol";
import {RaffleScript} from "../script/Raffle.s.sol";
import {HelperConfig} from "../script/HelperConfig.s.sol";
import {Vm} from "forge-std/Vm.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {CodeConstants} from "../script/HelperConfig.s.sol";
import {LinkToken} from "./mocks/LinkToken.sol";

/// @dev A player that cannot receive ETH (its receive() always reverts).
contract RejectingReceiver {
    receive() external payable {
        revert("no ETH accepted");
    }
}

contract RaffleTest is Test, CodeConstants {
    Raffle public raffle;
    HelperConfig public helperConfig;

    uint256 entranceFee;
    uint256 interval;
    address vrfCoordinator;
    bytes32 gasLane;
    uint256 subscriptionId;
    uint32 callbackGasLimit;

    address public PLAYER = makeAddr("player");
    uint256 public constant STARTING_PLAYER_BALANCE = 10 ether;

    event RaffleEntered(address indexed player);
    event WinnerPicked(address indexed winner);

    function setUp() public {
        RaffleScript raffleScript = new RaffleScript();
        (raffle, helperConfig) = raffleScript.deployContract();

        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        entranceFee = config.entranceFee;
        interval = config.interval;
        vrfCoordinator = config.vrfCoordinator;
        gasLane = config.gasLane;
        callbackGasLimit = config.callbackGasLimit;
        subscriptionId = config.subscriptionId;

        vm.deal(PLAYER, STARTING_PLAYER_BALANCE);
    }

    function testRaffleInitializesInOpenState() public view {
        assert(raffle.getRaffleState() == Raffle.RaffleState.OPEN);
    }

    /*//////////////////////////////////////////////////////////////
                              ENTER RAFFLE
    //////////////////////////////////////////////////////////////*/
    function testRaffleRevertWhenYouDontPayEnough() public {
        vm.prank(PLAYER);

        vm.expectRevert(Raffle.Raffle__SendMoreToEnterRaffle.selector);
        raffle.enterRaffle();
    }

    function testRaffleRecordsPlayersWhenTheyEnter() public {
        vm.prank(PLAYER);

        raffle.enterRaffle{value: entranceFee}();

        address playerRecorded = raffle.getPlayer(0);
        assert(playerRecorded == PLAYER);
    }

    function testEnteringRaffleEmitsEvent() public {
        vm.prank(PLAYER);

        vm.expectEmit(true, false, false, false, address(raffle));
        emit RaffleEntered(PLAYER);

        raffle.enterRaffle{value: entranceFee}();
    }

    function testDontAllowPLayersToEnterWhileRaffleIsCalculating() public {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        raffle.performUpkeep("");

        vm.expectRevert(Raffle.Raffle__RaffleNotOpen.selector);
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
    }

    /*//////////////////////////////////////////////////////////////
                              CHECKUPKEEP
    //////////////////////////////////////////////////////////////*/
    function testCheckUpkeepReturnsFalseIfItHasNoBalance() public {
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        (bool upkeepNeeded, ) = raffle.checkUpkeep("");

        assert(!upkeepNeeded);
    }

    function testCheckUpkeepReturnsFalseIfRaffleIsntOpen() public {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        raffle.performUpkeep("");

        (bool upkeepNeeded, ) = raffle.checkUpkeep("");

        assert(!upkeepNeeded);
    }

    function testCheckUpkeepReturnsFalseIfEnoughTimeHasPassed() public {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();

        (bool upkeepNeeded, ) = raffle.checkUpkeep("");

        assert(!upkeepNeeded);
    }

    function testCheckUpkeepReturnsTrueWhenParametersAreGood() public {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        (bool upkeepNeeded, ) = raffle.checkUpkeep("");

        assert(upkeepNeeded);
    }

    /*//////////////////////////////////////////////////////////////
                             PERFORMUPKEEP
    //////////////////////////////////////////////////////////////*/
    function testPerformUpkeepCanOnlyRunIfCheckUpkeepIsTrue() public {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        raffle.performUpkeep("");
    }

    function testPerformUpkeepRevertsIfCheckUpkeepIsFalse() public {
        uint256 currentBalance = 0;
        uint256 numPlayers = 0;
        Raffle.RaffleState raffleState = raffle.getRaffleState();

        vm.expectRevert(
            abi.encodeWithSelector(
                Raffle.Raffle__UpkeepNotNeeded.selector,
                currentBalance,
                numPlayers,
                raffleState
            )
        );
        raffle.performUpkeep("");
    }

    function testPerformUpkeepUpdatedRaffleStateAndEmitsRequestId() public {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];

        Raffle.RaffleState raffleState = raffle.getRaffleState();
        assert(uint256(requestId) > 0);
        assert(uint256(raffleState) == 1);
    }

    /*//////////////////////////////////////////////////////////////
                           FULFILLRANDOMWORDS
    //////////////////////////////////////////////////////////////*/
    modifier raffleEntered() {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        _;
    }

    modifier skipFork() {
        if (block.chainid != LOCAL_CHAIN_ID) {
            return;
        }
        _;
    }

    function testFulFillRandomWordsCanOnlyBeCalledAfterPerformUpkeep(
        uint256 randomRequestId
    ) public raffleEntered skipFork {
        vm.expectRevert(VRFCoordinatorV2_5Mock.InvalidRequest.selector);
        VRFCoordinatorV2_5Mock(vrfCoordinator).fulfillRandomWords(
            randomRequestId,
            address(raffle)
        );
    }

    function testFulfillRandomWordsPicksAWinnerResetsAndCreditsPrize()
        public
        raffleEntered
        skipFork
    {
        uint256 additionalEntrants = 3;
        uint256 startingIndex = 1;
        address expectedWinner = address(1);

        for (
            uint256 i = startingIndex;
            i < startingIndex + additionalEntrants;
            i++
        ) {
            address newPlayer = address(uint160(i));
            hoax(newPlayer, 1 ether);
            raffle.enterRaffle{value: entranceFee}();
        }

        uint256 startingTimeStamp = raffle.getLastTimeStamp();
        uint256 winnerStartingBalance = expectedWinner.balance;

        _performUpkeepAndFulfill();

        address recentWinner = raffle.getRecentWinner();
        Raffle.RaffleState raffleState = raffle.getRaffleState();
        uint256 endingTimeStamp = raffle.getLastTimeStamp();
        uint256 prize = entranceFee * (additionalEntrants + 1);

        assert(recentWinner == expectedWinner);
        assert(uint256(raffleState) == 0);
        assert(endingTimeStamp > startingTimeStamp);
        assertEq(raffle.getRound(), 1);
        assertEq(raffle.getNumberOfPlayers(), 0);
        assertEq(raffle.getPot(), 0);
        // Prize is credited, not pushed.
        assertEq(raffle.getPendingWithdrawal(recentWinner), prize);
        assertEq(recentWinner.balance, winnerStartingBalance);

        vm.prank(recentWinner);
        raffle.withdraw();

        assertEq(recentWinner.balance, winnerStartingBalance + prize);
        assertEq(raffle.getPendingWithdrawal(recentWinner), 0);
        assertEq(address(raffle).balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                WITHDRAW
    //////////////////////////////////////////////////////////////*/
    function testWithdrawRevertsWhenNothingToWithdraw() public {
        vm.prank(PLAYER);
        vm.expectRevert(Raffle.Raffle__NothingToWithdraw.selector);
        raffle.withdraw();
    }

    function testWinnerCannotWithdrawTwice() public raffleEntered skipFork {
        _performUpkeepAndFulfill();
        assertEq(raffle.getRecentWinner(), PLAYER);

        vm.startPrank(PLAYER);
        raffle.withdraw();
        vm.expectRevert(Raffle.Raffle__NothingToWithdraw.selector);
        raffle.withdraw();
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                       REGRESSIONS: STUCK RAFFLE
    //////////////////////////////////////////////////////////////*/
    /// @dev The old callback cleared the players array (one SSTORE per entry)
    /// and ran out of the 500k callback gas at roughly 90 entries, leaving the
    /// raffle stuck in CALCULATING. The mock forwards exactly callbackGasLimit.
    function testFulfillSucceedsWithManyPlayersWithinCallbackGasLimit()
        public
        skipFork
    {
        uint256 numPlayers = 250;
        for (uint256 i = 0; i < numPlayers; i++) {
            hoax(address(uint160(1000 + i)), 1 ether);
            raffle.enterRaffle{value: entranceFee}();
        }
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        bool success = _performUpkeepAndFulfill();

        assertTrue(success, "VRF callback ran out of gas or reverted");
        assertEq(uint256(raffle.getRaffleState()), 0);
        assertEq(raffle.getRound(), 1);
        assertEq(
            raffle.getPendingWithdrawal(raffle.getRecentWinner()),
            entranceFee * numPlayers
        );
    }

    /// @dev The old callback pushed the prize and reverted if the transfer
    /// failed, so a winner whose receive() reverts bricked the raffle.
    function testWinnerThatRejectsEthDoesNotBrickRaffle() public skipFork {
        RejectingReceiver rejecter = new RejectingReceiver();
        hoax(address(rejecter), 1 ether);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        // Round 0: the rejecting contract is the only player, so it wins.
        bool success = _performUpkeepAndFulfill();

        assertTrue(success, "VRF callback reverted");
        assertEq(raffle.getRecentWinner(), address(rejecter));
        assertEq(uint256(raffle.getRaffleState()), 0);
        assertEq(raffle.getPendingWithdrawal(address(rejecter)), entranceFee);

        // Its own withdrawal fails, but only for itself.
        vm.prank(address(rejecter));
        vm.expectRevert(Raffle.Raffle__TransferFailed.selector);
        raffle.withdraw();

        // Round 1 runs normally and its winner can withdraw.
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        uint256 playerBalanceBefore = PLAYER.balance;

        success = _performUpkeepAndFulfill();

        assertTrue(success, "VRF callback reverted");
        assertEq(raffle.getRecentWinner(), PLAYER);
        assertEq(raffle.getRound(), 2);

        vm.prank(PLAYER);
        raffle.withdraw();

        assertEq(PLAYER.balance, playerBalanceBefore + entranceFee);
        // The rejecting winner's prize is still held for it, not lost or reassigned.
        assertEq(raffle.getPendingWithdrawal(address(rejecter)), entranceFee);
        assertEq(address(raffle).balance, entranceFee);
    }

    /// @dev Runs performUpkeep, fulfills the request on the mock coordinator,
    /// and returns the `success` flag the coordinator reports for the callback.
    function _performUpkeepAndFulfill() internal returns (bool success) {
        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        uint256 requestId = uint256(entries[1].topics[1]);

        vm.recordLogs();
        VRFCoordinatorV2_5Mock(vrfCoordinator).fulfillRandomWords(
            requestId,
            address(raffle)
        );
        entries = vm.getRecordedLogs();

        bytes32 fulfilledSig = keccak256(
            "RandomWordsFulfilled(uint256,uint256,uint256,uint96,bool,bool,bool)"
        );
        for (uint256 i = 0; i < entries.length; i++) {
            if (
                entries[i].emitter == vrfCoordinator &&
                entries[i].topics[0] == fulfilledSig
            ) {
                (, , , success, ) = abi.decode(
                    entries[i].data,
                    (uint256, uint96, bool, bool, bool)
                );
                return success;
            }
        }
        revert("RandomWordsFulfilled not emitted");
    }
}
