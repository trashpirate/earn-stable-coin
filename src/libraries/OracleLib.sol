// SPDX-License Identifier: MIT
pragma solidity 0.8.20;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
/**
 * @title OracleLib
 * @author Nadina Oates
 * @notice This library is used to check the Chainlnk Oracle for stale data.
 * If the price is stale, the function will revert, and redner the ESCEngine unusable - this is by design.
 * We want the ESCEngine to freeze if prices become stale.
 *
 *
 *  So if Chainlink network explodes and you have a lot of money locked in the protocol...
 */

library OracleLib {
    uint256 private constant TIMEOUT = 3 hours;

    error OracleLib__StalePrice();

    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        uint256 secondsSince = block.timestamp - updatedAt;
        if (secondsSince > TIMEOUT) revert OracleLib__StalePrice();
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
