// SPDX-License Identifier: MIT

// What are the invariants?

// 1. Total supply of DSC should be less than total value of collateral
// 2. Getter view functions should never revert <-- almost always applies

pragma solidity 0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ESCEngine} from "./../../src/ESCEngine.sol";
import {EarnStableCoin} from "./../../src/EarnStableCoin.sol";
import {DeployESC} from "./../../script/DeployESC.s.sol";
import {HelperConfig} from "./../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract InvariantTest is StdInvariant, Test {
    // configuration
    DeployESC deployment;
    HelperConfig helperConfig;

    // contracts
    ESCEngine engine;
    EarnStableCoin esc;

    // helper config
    address weth;
    address wbtc;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;

    // testing
    Handler handler;

    // modifiers
    modifier skipFork() {
        if (block.chainid != 31337) {
            return;
        }
        _;
    }

    function setUp() external virtual {
        deployment = new DeployESC();
        (engine, helperConfig) = deployment.run();
        esc = EarnStableCoin(engine.getESCAddress());

        (,, weth, wbtc) = helperConfig.activeNetworkConfig();

        handler = new Handler(engine, esc);

        excludeSender(address(0));
        excludeSender(address(esc));
        excludeSender(address(engine));
        excludeSender(address(handler));

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = Handler.depositCollateral.selector;
        selectors[1] = Handler.redeemCollateral.selector;
        selectors[2] = Handler.mintESC.selector;
        // selectors[3] = Handler.updateCollateralPrice.selector;
        selectors[3] = Handler.callSummary.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        targetContract(address(handler));
    }

    function invariant__ProtocolMustHaveMoreValueThanTotalSupplyESC() public view skipFork {
        // total ESC
        uint256 totalSupply = esc.totalSupply();

        // total collateral
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(engine));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(engine));

        uint256 wethValue = engine.getUsdValueFromTokenAmount(weth, totalWethDeposited);
        uint256 wbtcValue = engine.getUsdValueFromTokenAmount(wbtc, totalWbtcDeposited);

        console.log("weth value: ", wethValue);
        console.log("wbtc value: ", wbtcValue);
        console.log("total supply: ", totalSupply);

        // test
        assertGe(wethValue + wbtcValue, totalSupply);
    }

    function invariant__CallSummary() public view skipFork {
        handler.callSummary();
    }
}
