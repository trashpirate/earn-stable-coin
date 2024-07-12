// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {EarnStableCoin} from "./../../src/EarnStableCoin.sol";
import {ESCEngine} from "./../../src/ESCEngine.sol";
import {DeployESC} from "./../../script/DeployESC.s.sol";
import {HelperConfig} from "./../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract EarnStableCoin__UnitTest is Test {
    // configuration
    DeployESC deployment;
    HelperConfig helperConfig;

    // contracts
    ESCEngine engine;
    EarnStableCoin token;

    // helper config
    address weth;
    address wbtc;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;

    // helpers
    address USER = makeAddr("user");
    address LIQUIDATOR = makeAddr("liquidator");
    uint256 DEPOSIT_AMOUNT = 1 ether;

    // events
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    // modifiers
    modifier skipFork() {
        if (block.chainid != 31337) {
            return;
            _;
        }
    }

    modifier funded(address account) {
        // fund user with eth
        deal(account, 10000 ether);
        ERC20Mock(weth).mint(account, 10000 ether);
        ERC20Mock(wbtc).mint(account, 10000 ether);
        _;
    }

    modifier minted(address account) {
        uint256 amount = 10000 ether;
        address owner = token.owner();

        vm.prank(owner);
        token.mint(account, amount);
        _;
    }

    modifier deposited(address account, address collateral) {
        vm.startPrank(account);
        ERC20Mock(collateral).approve(address(engine), DEPOSIT_AMOUNT);
        engine.depositCollateral(collateral, DEPOSIT_AMOUNT);
        vm.stopPrank();
        _;
    }

    function setUp() external virtual {
        deployment = new DeployESC();
        (engine, helperConfig) = deployment.run();
        token = EarnStableCoin(engine.getESCAddress());

        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc) = helperConfig.activeNetworkConfig();
    }

    /**
     * INITIALIZATION
     */
    function test__unit__ESCEngine__Initialization() public view {
        assertEq(token.name(), "EarnStableCoin");
        assertEq(token.symbol(), "ESC");
        assertEq(token.decimals(), 18);

        assertEq(engine.getAllowedTokens().length, 2);
        assertEq(engine.getAllowedTokens()[0], weth);
        assertEq(engine.getAllowedTokens()[1], wbtc);
    }

    /**
     * Constructor
     */
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function test__unit__ESCEngine__RevertsWhen__ArrayLengthsMismatch() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(ESCEngine.ESCEngine__UnequalNumberOfTokenAndPriceFeedAddresses.selector);
        new ESCEngine(tokenAddresses, priceFeedAddresses);
    }

    /**
     * Price Feed
     */
    function test__unit__ESCEngine__GetUsdValueFromTokenAmount() public view {
        uint256 ethPrice = uint256(helperConfig.ETH_USD_PRICE());

        uint256 ethAmount = 5e17;
        uint256 expectedUsdValue = ethAmount * ethPrice / 1e8; // 52500e18 = 15 * 3500
        uint256 actualUsdValue = engine.getUsdValueFromTokenAmount(weth, ethAmount);

        assertEq(expectedUsdValue, actualUsdValue);
    }

    function test__unit__ESCEngine__GetTokenAmountFromUsd() public view {
        uint256 ethPrice = uint256(helperConfig.ETH_USD_PRICE());

        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = usdAmount * 1e8 / ethPrice;
        uint256 actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);

        assertEq(expectedWeth, actualWeth);
    }

    function test__unit__ESCEngine__GetPriceFeed() public view {
        assertEq(engine.getPriceFeed(weth), ethUsdPriceFeed);
    }

    /**
     * Deposit Collateral
     */
    function test__unit__ESCEngine__DepositCollateral() public funded(USER) {
        uint256 amount = 200 ether;

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), amount);
        engine.depositCollateral(weth, amount);
        vm.stopPrank();

        assertEq(amount, ERC20Mock(weth).balanceOf(address(engine)));
    }

    function test__unit__ESCEngine__GetAccountInfo() public funded(USER) deposited(USER, weth) {
        (uint256 totalMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);

        assertEq(totalMinted, 0);
        assertEq(collateralValueInUsd, engine.getUsdValueFromTokenAmount(weth, DEPOSIT_AMOUNT));
    }

    function test__unit__ESCEngine__EmitEvent__DepositCollateral() public funded(USER) {
        uint256 amount = 200 ether;

        vm.prank(USER);
        ERC20Mock(weth).approve(address(engine), amount);

        vm.expectEmit(true, true, true, true);
        emit CollateralDeposited(USER, weth, amount);

        vm.prank(USER);
        engine.depositCollateral(weth, amount);
    }

    function test__unit__ESCEngine__RevertWhen__DepositCollateralIsZero() public funded(USER) {
        uint256 amount = 200 ether;

        vm.prank(USER);
        ERC20Mock(weth).approve(address(engine), amount);

        vm.expectRevert(ESCEngine.ESCEngine__MustBeMoreThanZero.selector);

        vm.prank(USER);
        engine.depositCollateral(weth, 0);
    }

    function test__unit__ESCEngine__RevertWhen__WrongToken() public funded(USER) {
        uint256 amount = 200 ether;
        address tokenAddress = makeAddr("token");

        vm.prank(USER);
        ERC20Mock(weth).approve(address(engine), amount);

        vm.expectRevert(ESCEngine.ESCEngine__TokenNotAllowed.selector);

        vm.prank(USER);
        engine.depositCollateral(tokenAddress, amount);
    }

    function test__unit__ESCEngine__RevertWhen__TokensUnapproved() public funded(USER) {
        uint256 amount = 200 ether;

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(engine), 0, amount)
        );

        vm.prank(USER);
        engine.depositCollateral(weth, amount);
    }

    function test__unit__ESCEngine__RevertWhen__TransferFails() public funded(USER) {
        uint256 amount = 200 ether;

        vm.prank(USER);
        ERC20Mock(weth).approve(address(engine), amount);

        vm.mockCall(
            weth,
            abi.encodeWithSelector(ERC20Mock(weth).transferFrom.selector, USER, address(engine), amount),
            abi.encode(false)
        );
        vm.expectRevert(ESCEngine.ESCEngine__TransferFailed.selector);

        vm.prank(USER);
        engine.depositCollateral(weth, amount);
    }

    function test__unit__ESCEngine__GetCollateralValue() public funded(USER) deposited(USER, weth) {
        assertEq(3500 ether, engine.getAccountCollateralValue(USER));
    }

    /**
     * Mint ESC
     */
    function test__unit__ESCEngine__MintESC() public funded(USER) deposited(USER, weth) {
        uint256 amount = 100 ether;

        vm.prank(USER);
        engine.mintESC(amount);

        assertEq(amount, token.balanceOf(USER));
    }

    function test__unit__ESCEngine__RevertWhen__InsufficientHealthFactor() public funded(USER) deposited(USER, weth) {
        uint256 amount = 1400 ether;
        vm.prank(USER);
        engine.mintESC(amount);

        // price of ETH: $3500
        // collateral amount: 1 ETH
        // collateral threshold: $1700
        // healthfactor after first deposit: 1750 / 1400 = 1.25
        // healthfactor after second deposit: 1750 /2800 = 0.625 => revert!
        uint256 healthFactor = 0.625 ether;
        vm.expectRevert(abi.encodeWithSelector(ESCEngine.ESCEngine__InsufficientHealthFactor.selector, healthFactor));
        vm.prank(USER);
        engine.mintESC(amount);
    }

    function test__unit__ESCEngine__RevertWhen__MintFails() public funded(USER) deposited(USER, weth) {
        uint256 amount = 200 ether;

        vm.mockCall(address(token), abi.encodeWithSelector(token.mint.selector, USER, amount), abi.encode(false));
        vm.expectRevert(ESCEngine.ESCEngine__MintFailed.selector);

        vm.prank(USER);
        engine.mintESC(amount);
    }

    /**
     * Burn ESC
     */
    function test__unit__ESCEngine__BurnESC() public funded(USER) deposited(USER, weth) {
        uint256 mintAmount = 100 ether;
        uint256 burnAmount = 50 ether;

        vm.startPrank(USER);
        engine.mintESC(mintAmount);
        token.approve(address(engine), burnAmount);
        engine.burnESC(burnAmount);
        vm.stopPrank();

        assertEq(mintAmount - burnAmount, token.balanceOf(USER));
    }

    function test__unit__ESCEngine__RevertsWhen__BurnTransferFails() public funded(USER) deposited(USER, weth) {
        uint256 mintAmount = 100 ether;
        uint256 burnAmount = 50 ether;

        vm.startPrank(USER);
        engine.mintESC(mintAmount);
        token.approve(address(engine), burnAmount);
        vm.stopPrank();

        vm.mockCall(
            address(token),
            abi.encodeWithSelector(token.transferFrom.selector, USER, address(engine), burnAmount),
            abi.encode(false)
        );
        vm.expectRevert(ESCEngine.ESCEngine__TransferFailed.selector);

        vm.prank(USER);
        engine.burnESC(burnAmount);
    }

    /**
     * Redeem Collateral
     */
    function test__unit__ESCEngine__RedeemCollateral() public funded(USER) deposited(USER, weth) {
        uint256 amount = 0.5 ether;
        uint256 startingBalance = IERC20(weth).balanceOf(USER);

        vm.prank(USER);
        engine.redeemCollateral(weth, amount);

        assertEq(amount + startingBalance, IERC20(weth).balanceOf(USER));
    }

    function test__unit__ESCEngine__RevertWhen__RedeemTooMuchCollateral() public funded(USER) deposited(USER, weth) {
        uint256 amount = 1400 ether; // in USD
        vm.prank(USER);
        engine.mintESC(amount);

        // price of ETH: $3500
        // collateral amount: 1 ETH
        // collateral threshold: $1700
        // healthfactor after first deposit: 1750 / 1400 = 1.25
        // healthfactor after redeeming collateral: 875 / 1400 = 0.625 => revert!
        uint256 healthFactor = 0.625 ether;
        vm.expectRevert(abi.encodeWithSelector(ESCEngine.ESCEngine__InsufficientHealthFactor.selector, healthFactor));
        vm.prank(USER);
        engine.redeemCollateral(weth, 0.5 ether);
    }

    function test__unit__ESCEngine__RevertWhen__RedeemTooMuchTokenCollateral()
        public
        funded(USER)
        deposited(USER, wbtc)
    {
        uint256 amount = 1400 ether; // in USD
        vm.prank(USER);
        engine.mintESC(amount);

        uint256 collateralDeposited = engine.getCollateralBalanceToken(USER, weth);
        uint256 redeemAmount = 0.5 ether;
        vm.expectRevert(
            abi.encodeWithSelector(
                ESCEngine.ESCEngine__RedeemAmountExceedsTokenCollateral.selector, collateralDeposited, redeemAmount
            )
        );
        vm.prank(USER);
        engine.redeemCollateral(weth, redeemAmount);
    }

    function test__unit__ESCEngine__RevertsWhen__CollateralTransferFails() public funded(USER) deposited(USER, weth) {
        uint256 amount = 0.5 ether;
        vm.mockCall(weth, abi.encodeWithSelector(ERC20Mock(weth).transfer.selector, USER, amount), abi.encode(false));

        vm.expectRevert(ESCEngine.ESCEngine__TransferFailed.selector);
        vm.prank(USER);
        engine.redeemCollateral(weth, amount);
    }

    /**
     * Redeem collateral for ESC
     */
    function test__unit__ESCEngine__RedeemCollateralForESC() public funded(USER) deposited(USER, weth) {
        uint256 startingEthBalance = IERC20(weth).balanceOf(USER);

        uint256 escAmount = 1750 ether; // in USD
        vm.prank(USER);
        engine.mintESC(escAmount);
        uint256 startingEscBalance = token.balanceOf(USER);

        uint256 redeemAmount = 0.5 ether;
        uint256 burnAmount = escAmount / 2;
        vm.startPrank(USER);
        token.approve(address(engine), burnAmount);
        engine.redeemCollateralForESC(weth, redeemAmount, burnAmount);
        vm.stopPrank();

        assertEq(startingEthBalance + redeemAmount, IERC20(weth).balanceOf(USER));
        assertEq(startingEscBalance - burnAmount, token.balanceOf(USER));
    }

    /**
     * Deposit Collateral And Mint
     */
    function test__unit__ESCEngine__DepositCollateralAndMint() public funded(USER) {
        uint256 amountCollateral = 1 ether; // ETH
        uint256 amountEscToMint = 100 ether; // USD

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateralAndMintESC(weth, amountCollateral, amountEscToMint);
        vm.stopPrank();

        assertEq(amountCollateral, ERC20Mock(weth).balanceOf(address(engine)));
        assertEq(amountEscToMint, token.balanceOf(USER));
    }

    /**
     * Liquidate
     */
    function test__unit__ESCEngine__Liquidate()
        public
        funded(USER)
        deposited(USER, weth)
        funded(LIQUIDATOR)
        deposited(LIQUIDATOR, weth)
    {
        uint256 startingEthBalance = IERC20(weth).balanceOf(LIQUIDATOR);

        uint256 escAmount = 1750 ether; // in USD
        vm.prank(USER);
        engine.mintESC(escAmount);

        // update price feed
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(3400e8);

        // liquidate
        uint256 debtAmount = 1000 ether; // USD
        vm.startPrank(LIQUIDATOR);
        engine.mintESC(debtAmount);
        token.approve(address(engine), debtAmount);
        engine.liquidate(weth, USER, debtAmount);
        vm.stopPrank();

        uint256 collateralAmount = engine.getTokenAmountFromUsd(weth, debtAmount);
        uint256 redeemableCollateral = collateralAmount + collateralAmount * engine.getLiquidationBonus() / 100;

        assertEq(token.balanceOf(LIQUIDATOR), 0);
        assertEq(startingEthBalance + redeemableCollateral, ERC20Mock(weth).balanceOf(LIQUIDATOR));

        assertGt(engine.getHealthFactor(USER), 1e18);
    }

    function test__unit__ESCEngine__RevertsWhen__NoLiquidationNeeded()
        public
        funded(USER)
        deposited(USER, weth)
        funded(LIQUIDATOR)
        deposited(LIQUIDATOR, weth)
    {
        uint256 escAmount = 100 ether; // in USD
        vm.prank(USER);
        engine.mintESC(escAmount);

        // update price feed
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(3400e8);

        // liquidate
        uint256 debtAmount = 1000 ether; // USD
        vm.startPrank(LIQUIDATOR);
        engine.mintESC(debtAmount);
        token.approve(address(engine), debtAmount);
        vm.stopPrank();

        vm.expectRevert(ESCEngine.ESCEngine__NoLiquidationNeeded.selector);
        vm.prank(LIQUIDATOR);
        engine.liquidate(weth, USER, debtAmount);
    }

    function test__unit__ESCEngine__RevertsWhen__DebtAmountTooLarge()
        public
        funded(USER)
        deposited(USER, weth)
        funded(LIQUIDATOR)
        deposited(LIQUIDATOR, weth)
    {
        uint256 escAmount = 1750 ether; // in USD
        vm.prank(USER);
        engine.mintESC(escAmount);

        // update price feed
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(3400e8);

        // liquidate
        uint256 collateralAmount = 2 ether; // ETH
        uint256 debtAmount = 1800 ether; // USD
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(engine), collateralAmount);
        engine.depositCollateral(weth, collateralAmount);
        engine.mintESC(debtAmount);
        token.approve(address(engine), debtAmount);
        vm.stopPrank();

        vm.expectRevert(ESCEngine.ESCEngine__DebtAmountTooLarge.selector);
        vm.prank(LIQUIDATOR);
        engine.liquidate(weth, USER, debtAmount);
    }

    /**
     * Max Redeemable Collateral
     */
    function test__unit__ESCEngine__MaxRedeemableCollateral() public funded(USER) deposited(USER, weth) {
        uint256 escAmount = 1000 ether; // in USD
        vm.prank(USER);
        engine.mintESC(escAmount);

        uint256 maxRedeemableCollateral = engine.getMaxCollateralToRedeem(weth, USER);

        vm.prank(USER);
        engine.redeemCollateral(weth, maxRedeemableCollateral);

        uint256 healthfactor = engine.getHealthFactor(USER);
        assertEq(healthfactor, 1e18);
    }

    /**
     * Getter functions
     */
    function test__unit__ESCEngine__GetCollateralBalanceToken() public funded(USER) deposited(USER, weth) {
        uint256 collateralAmount = engine.getCollateralBalanceToken(USER, weth);

        assertEq(collateralAmount, DEPOSIT_AMOUNT);
    }

    function test__unit__ESCEngine__GetCollateralBalanceUsd() public funded(USER) deposited(USER, weth) {
        uint256 collateralAmount = engine.getCollateralBalanceUsd(USER, weth);

        assertEq(collateralAmount, 3500 ether);
    }

    function test__unit__ESCEngine__GetMaxMintableEsc() public funded(USER) deposited(USER, weth) {
        uint256 escAmount = 1000 ether; // in USD
        vm.prank(USER);
        engine.mintESC(escAmount);

        uint256 maxMintableEsc = engine.getMaxMintableEscAmount(USER);
        console.log(maxMintableEsc);

        vm.prank(USER);
        engine.mintESC(maxMintableEsc);

        uint256 healthfactor = engine.getHealthFactor(USER);
        assertEq(healthfactor, 1e18);
    }
}
