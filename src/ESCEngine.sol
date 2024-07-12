// SPDX-License Identifier: MIT
pragma solidity 0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {EarnStableCoin} from "./EarnStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";
/**
 * @title EarnStableCoin
 * @author Nadina Oates
 *
 * The system is desinged to be as minimal as possible, and have the tokens maintain the gold price
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Gold Pegged
 * - Algorithmically stable
 *
 * The ESC systems should always be "overcollateralized". At no point, should the value of all collateral >= the $ backed value of all ESC
 * @notice This contract is the core of the ESC system. It handles all thelogic for mining and redeeming ESC, as well as depositing & withdrawing collteral
 * @notice This contract is VERY loolsely based on the MakerDAO DSS (DAI) system.
 */

contract ESCEngine is ReentrancyGuard {
    /**
     * Types
     */
    using OracleLib for AggregatorV3Interface;

    /**
     * State variables
     */
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10 percent bonus

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address account => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address account => uint256 amountMinted) private s_minted;

    address[] private s_collateralTokens;

    EarnStableCoin private immutable i_esc;

    /**
     * Events
     */
    event CollateralDeposited(address indexed account, address indexed token, uint256 indexed amount);
    event CollteralRedeemed(address indexed from, address indexed to, address indexed token, uint256 amount);

    /**
     * Errors
     */
    error ESCEngine__MustBeMoreThanZero();
    error ESCEngine__UnequalNumberOfTokenAndPriceFeedAddresses();
    error ESCEngine__TokenNotAllowed();
    error ESCEngine__TransferFailed();
    error ESCEngine__InsufficientHealthFactor(uint256 healthFactor);
    error ESCEngine__MintFailed();
    error ESCEngine__NoLiquidationNeeded();
    error ESCEngine__HealthFactorNotImproved();
    error ESCEngine__HealthFactorNotAvailable();
    error ESCEngine__DebtAmountTooLarge();
    error ESCEngine__RedeemAmountExceedsTokenCollateral(uint256 collateralDeposited, uint256 redeemAmount);

    /**
     * Modifiers
     */
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert ESCEngine__MustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert ESCEngine__TokenNotAllowed();
        }
        _;
    }

    /**
     * Functions
     */

    /**
     * @param tokenAddresses Contract addresses of tokens accepted as collateral
     * @param priceFeedAddresses Chainlink price feed addresses of the accepted tokens
     */
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses) {
        // Usd Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert ESCEngine__UnequalNumberOfTokenAndPriceFeedAddresses();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_esc = new EarnStableCoin();
    }

    /**
     * External Functions
     */

    /**
     * @notice follows CEI
     * @param tokenCollateralAddress The address fo the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountEscToMint Mint amount
     * @notice this funciton will deposit collateral and mint ESC in one transaction
     */
    function depositCollateralAndMintESC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountEscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintESC(amountEscToMint);
    }

    /**
     *  @param tokenCollateralAddress Token address of Collateral
     *  @param amountCollateral Collateral amount to redeem
     *  @param amountESCToBurn ESC amount to be burned for redeeming colletral
     */
    function redeemCollateralForESC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountESCToBurn)
        external
    {
        burnESC(amountESCToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral already checks health factor
    }

    /**
     *  @notice To redeem collateral health factor must be over 1 AFTER collateral withdrawn
     *  @param tokenCollateralAddress Token address of Collateral
     *  @param amountCollateral Collateral amount to redeem
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfInsufficientHealthFactor(msg.sender);
    }

    /**
     * @notice Burns ESC
     * @param amount Amount of ESC to be burned
     */
    function burnESC(uint256 amount) public moreThanZero(amount) {
        _burnESC(msg.sender, msg.sender, amount);
        _revertIfInsufficientHealthFactor(msg.sender); // likely not needed
    }

    /**
     * @notice Liquidates account that breaks health factor - partial liquidation is possible. For this protocol always needs to be overcollateralized.
     * @param collateral The collateral address to liquidate
     * @param account User who ahs broken the health factor. Health factor should be below MIN_HEALTH_FACTOR
     * @param debt Debt to cover and amoutn of ESC to burn
     */
    function liquidate(address collateral, address account, uint256 debt) external moreThanZero(debt) nonReentrant {
        uint256 startingHealthFactor = _healthFactor(account);
        if (startingHealthFactor >= MIN_HEALTH_FACTOR) {
            revert ESCEngine__NoLiquidationNeeded();
        }

        uint256 tokenAmountToCoverDebt = getTokenAmountFromUsd(collateral, debt);
        // should liquidate in case protocol is insolvent, sweep extra amounts into treasury

        // 10 % bonus for liquidator
        uint256 bonusCollateral = tokenAmountToCoverDebt * LIQUIDATION_BONUS / LIQUIDATION_PRECISION;

        uint256 totalCollateralToRedeem = tokenAmountToCoverDebt + bonusCollateral;
        _redeemCollateral(account, msg.sender, collateral, totalCollateralToRedeem);
        _burnESC(account, msg.sender, debt);

        // check health factor (possibly redundant)
        uint256 endingHealthFactor = _healthFactor(account);
        if (endingHealthFactor <= startingHealthFactor) {
            revert ESCEngine__HealthFactorNotImproved();
        }
        _revertIfInsufficientHealthFactor(msg.sender);
    }

    /**
     * Getter Functions
     */

    /**
     * @notice returns the contract address of the ESC token
     */
    function getESCAddress() external view returns (address) {
        return address(i_esc);
    }

    /**
     * @notice Returns health factor for account
     * @param account Account of the account
     */
    function getHealthFactor(address account) external view returns (uint256) {
        return _healthFactor(account);
    }

    /**
     * @notice Returns account information of account
     * @param account Account of the account
     */
    function getAccountInformation(address account)
        external
        view
        returns (uint256 totalMinted, uint256 collateralValueInUsd)
    {
        (totalMinted, collateralValueInUsd) = _getAccountInfo(account);
    }

    /**
     * @notice Returns collateral deposited
     * @param account Account of the account
     */
    function getCollateralBalanceToken(address account, address token)
        external
        view
        returns (uint256 collateralBalance)
    {
        collateralBalance = s_collateralDeposited[account][token];
    }

    /**
     * @notice Returns allowed tokens for collateral
     */
    function getAllowedTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    /**
     * @notice Returns price feed addresses for collateral tokens
     */
    function getPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    /**
     * @notice Returns liquidation bonus in basis points
     */
    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    /**
     * @notice Returns maximum redeemable collateral
     */
    function getMaxCollateralToRedeem(address collateral, address account) external view returns (uint256) {
        // total collateral value for account
        uint256 collateralValueInUsd = getAccountCollateralValue(account);

        // redeemable collateral value without breaking health factor
        uint256 unusedCollateralValueInUsd =
            collateralValueInUsd - s_minted[account] * LIQUIDATION_PRECISION / LIQUIDATION_THRESHOLD;

        // redeemable collateral value for collateral token
        uint256 collateralTokenValueInUsd = getCollateralBalanceUsd(account, collateral);

        // redeemable amount - whichever is smaller
        uint256 redeemableCollateralTokenValue = collateralTokenValueInUsd < unusedCollateralValueInUsd
            ? collateralTokenValueInUsd
            : unusedCollateralValueInUsd;

        // redeemable amount in tokens
        uint256 maxRedeemableCollateral = getTokenAmountFromUsd(collateral, redeemableCollateralTokenValue);
        return maxRedeemableCollateral;
    }

    /**
     * @notice Returns maximum mintable ESC amount
     */
    function getMaxMintableEscAmount(address account) external view returns (uint256 maxMintableEsc) {
        // total collateral value for account
        (uint256 totalMinted, uint256 collateralValueInUsd) = _getAccountInfo(account);

        uint256 borrowPower = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        if (borrowPower > 0) {
            maxMintableEsc = borrowPower - totalMinted;
        } else {
            maxMintableEsc = 0;
        }
    }

    /**
     * Public Functions
     */

    /**
     * @notice Deposits collateral
     * @param tokenCollateralAddress The address fo the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        isAllowedToken(tokenCollateralAddress)
        moreThanZero(amountCollateral)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert ESCEngine__TransferFailed();
        }
        _revertIfInsufficientHealthFactor(msg.sender);
    }

    /**
     * @notice follows CEI
     * @param amount Mint amount
     * @notice must have more collateral value than the minimum threshold
     */
    function mintESC(uint256 amount) public moreThanZero(amount) nonReentrant {
        s_minted[msg.sender] += amount;

        // revert if minted too much
        _revertIfInsufficientHealthFactor(msg.sender);

        bool success = i_esc.mint(msg.sender, amount);
        if (!success) {
            revert ESCEngine__MintFailed();
        }
    }

    /**
     * @notice Gets collateral value of account
     * @param account User account address
     */
    function getAccountCollateralValue(address account) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[account][token];
            totalCollateralValueInUsd += getUsdValueFromTokenAmount(token, amount);
        }
    }

    /**
     * @notice Returns collateral deposited in USD value
     * @param account Account of the account
     */
    function getCollateralBalanceUsd(address account, address token) public view returns (uint256 collateralBalance) {
        collateralBalance = getUsdValueFromTokenAmount(token, s_collateralDeposited[account][token]);
    }

    /**
     * @notice Returns USD value of token from token amount
     * @param token Contract address of token
     * @param amount Token amount
     */
    function getUsdValueFromTokenAmount(address token, uint256 amount) public view returns (uint256 usdAmount) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        // returned value by Chainlink will be 1000 * 1e8
        usdAmount = ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount / PRECISION);
    }

    /**
     * @notice Returns token amount from USD value
     * @param token Contract address of token
     * @param amount Token amount
     */
    function getTokenAmountFromUsd(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        return (amount * PRECISION / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    /**
     * Private Functions
     */
    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 redeemAmount)
        private
    {
        // reverts if underflow
        uint256 collateralDeposited = s_collateralDeposited[from][tokenCollateralAddress];
        if (redeemAmount > collateralDeposited) {
            revert ESCEngine__RedeemAmountExceedsTokenCollateral(collateralDeposited, redeemAmount);
        }
        s_collateralDeposited[from][tokenCollateralAddress] -= redeemAmount;

        emit CollteralRedeemed(from, to, tokenCollateralAddress, redeemAmount);

        bool success = IERC20(tokenCollateralAddress).transfer(to, redeemAmount);
        if (!success) {
            revert ESCEngine__TransferFailed();
        }
    }

    function _burnESC(address onBehalfOf, address owner, uint256 amount) private {
        if (amount > s_minted[onBehalfOf]) {
            revert ESCEngine__DebtAmountTooLarge();
        }

        s_minted[onBehalfOf] -= amount;
        bool success = i_esc.transferFrom(owner, address(this), amount);
        if (!success) {
            revert ESCEngine__TransferFailed();
        }
        i_esc.burn(amount);
    }

    /**
     * @notice Returns total ESC minted and collateral value in USD
     *  @param account Account address of account
     */
    function _getAccountInfo(address account) private view returns (uint256 totalMinted, uint256 collateralInUsd) {
        totalMinted = s_minted[account];
        collateralInUsd = getAccountCollateralValue(account);
    }

    /**
     * @notice Returns how close to liquidition a account is. Liquidiation occurs at <= 1
     */
    function _healthFactor(address account) private view returns (uint256 healthFactor) {
        (uint256 totalEscMinted, uint256 collateralValueInUsd) = _getAccountInfo(account);

        if (totalEscMinted == 0) {
            return type(uint256).max;
        }
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        // Example liquidiation:
        // $150 EARN / 100 ESC = 1.5
        // 150 * 50 = 7500 => 7500 / 100 = 75 => 75 / 100 = 0.75 < 1

        // Example no liquidation:
        // $1000 EARN / 100 ESC = 1.5
        // 1000 * 50 = 50000 => 50000 / 100 = 500 => 500 / 100 = 5 > 1
        healthFactor = (collateralAdjustedForThreshold * PRECISION / totalEscMinted);
    }

    /**
     * @notice Checks if health factor is broken - if yes, it reverts
     * @param account User account address
     */
    function _revertIfInsufficientHealthFactor(address account) internal view {
        uint256 healthFactor = _healthFactor(account);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert ESCEngine__InsufficientHealthFactor(healthFactor);
        }
    }
}
