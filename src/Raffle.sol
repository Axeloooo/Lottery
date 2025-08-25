// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

/**
 * @title A simple Raffle contract
 * @author Axel Omar Sanchez Peralta (axelshz@gmail.com)
 * @notice This contract is for creating a sample raffle
 * @dev Implements Chainlink VRFv2.5
 */
contract Raffle {
    /** Errors */
    error Raffle__SendMoreToEnterRaffle();

    /** Immutable variables */
    uint256 private immutable i_entranceFee;

    constructor(uint256 entranceFee) {
        i_entranceFee = entranceFee;
    }

    function enterRaffle() public payable {
        if (msg.value >= i_entranceFee) {
            revert Raffle__SendMoreToEnterRaffle();
        }
    }

    function pickWinner() public {}

    /** Getter Functions */
    function getEntranceFee() external view returns (uint256) {
        return i_entranceFee;
    }
}
