// SPDX-License Identifier: MIT
pragma solidity 0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ESCEngine} from "./../../src/ESCEngine.sol";
import {EarnStableCoin} from "./../../src/EarnStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {LibAddressSet} from "./LibAddressSet.sol";

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

contract Handler is CommonBase, StdCheats, StdUtils, Test {
    using LibAddressSet for LibAddressSet.AddressSet;

    LibAddressSet.AddressSet internal _actors;
    address internal currentActor;

    ESCEngine escEngine;
    EarnStableCoin esc;

    address weth;
    address wbtc;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;

    uint256 public timesMintCalled;
    uint256 public timesDepositCalled;
    uint256 public timesRedeemCalled;

    address[] public usersWithCollateralDeposited;

    mapping(bytes32 => uint256) public calls;

    modifier createActor() {
        currentActor = msg.sender;
        _actors.add(msg.sender);
        _;
    }

    modifier useActor(uint256 actorIndexSeed) {
        currentActor = _actors.rand(actorIndexSeed);
        _;
    }

    modifier countCall(bytes32 key) {
        calls[key]++;
        _;
    }

    constructor(ESCEngine _escEngine, EarnStableCoin _esc) {
        escEngine = _escEngine;
        esc = _esc;

        address[] memory collateralAddresses = escEngine.getAllowedTokens();
        weth = collateralAddresses[0];
        wbtc = collateralAddresses[1];
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral)
        public
        createActor
        countCall("depositCollateral")
    {
        address collateral = _getCollateralFromSeed(collateralSeed);

        uint256 amount = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(currentActor);
        ERC20Mock(collateral).mint(currentActor, amount);
        ERC20Mock(collateral).approve(address(escEngine), amount);
        escEngine.depositCollateral(collateral, amount);
        vm.stopPrank();
    }

    function redeemCollateral(uint256 collateralSeed, uint256 actorSeed, uint256 amountCollateral)
        public
        useActor(actorSeed)
        countCall("redeemCollateral")
    {
        address collateral = _getCollateralFromSeed(collateralSeed);

        uint256 maxCollateralToRedeem = escEngine.getMaxCollateralToRedeem(collateral, currentActor);

        uint256 amount = bound(amountCollateral, 0, maxCollateralToRedeem);

        if (amount == 0) return;

        vm.prank(currentActor);
        escEngine.redeemCollateral(collateral, amount);
        timesRedeemCalled++;
    }

    function mintESC(uint256 actorSeed, uint256 amountToMint) public useActor(actorSeed) countCall("mintESC") {
        uint256 maxEscToMint = escEngine.getMaxMintableEscAmount(currentActor);

        uint256 amount = bound(amountToMint, 0, uint256(maxEscToMint));

        if (amount == 0) return;

        vm.prank(currentActor);
        escEngine.mintESC(amount);
        timesMintCalled++;
    }

    // Helper functions
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (address) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }

    function callSummary() external view {
        console.log("\nCall summary:");
        console.log("-------------------");
        console.log("depositCollateral", calls["depositCollateral"]);
        console.log("redeemCollateral", calls["redeemCollateral"]);
        console.log("mintESC", calls["mintESC"]);
        console.log("-------------------");
    }
}
