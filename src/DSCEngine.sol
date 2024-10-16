// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions (getter function) (external)

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Minesh Patel
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI, if DAI had no governance, no fees, and was only backed by wETH and wBTC.
 *
 * Our DSC system should always be "over-collateralized". At no point, should the value of all collateral <= the dollar backed value of all the DSC.
 *
 * @notice This contract is the core of the DSC System. It handles all the logic for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    ////////////////
    // Errors     //
    ////////////////

    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesandPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOK();
    error DSCEngine__HealthFactorNotImproved();

    //////////////////////
    // State Variables  //
    //////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // Needs to have double the collateral to DSC
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // This means a 10% bonus

    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;
    ////////////////
    // Events     //
    ////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    ////////////////
    // Modifiers  //
    ////////////////

    modifier moreThanZero(uint256 amount) {
        // checks we are inputting a value above zero
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        // checks if the tokenAddress provided has a priceFeed associated
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ////////////////
    // Functions  //
    ////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesandPriceFeedAddressesMustBeSameLength();
        }
        // For example ETH/USD, BTC/USD, MKR/USD, etc
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /////////////////////////
    // External Functions  //
    /////////////////////////

    /**
     *
     * @param addressOfCollateral The address of the token to deposit as collateral
     * @param amountOfCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of Decentralized StableCoin to mint
     * @notice This function will deposit your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address addressOfCollateral,
        uint256 amountOfCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(addressOfCollateral, amountOfCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice Follows Checks (modifiers) Effects (updates mapping and emits CollateralDeposited) Interactions (CEI)
     * @param addressOfCollateral The address of the token to deposit as collateral
     * @param amountOfCollateral  The amount of collateral to deposit
     */
    function depositCollateral(address addressOfCollateral, uint256 amountOfCollateral)
        public
        moreThanZero(amountOfCollateral)
        isAllowedToken(addressOfCollateral)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][addressOfCollateral] += amountOfCollateral;
        emit CollateralDeposited(msg.sender, addressOfCollateral, amountOfCollateral);

        bool success = IERC20(addressOfCollateral).transferFrom(msg.sender, address(this), amountOfCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @param addressOfCollateral The address of the token to redeem as collateral
     * @param amountOfCollateral The amount of collateral to redeem
     * @param amountDscToBurn The amount of Decentralized StableCoin to burn
     * @notice This function burns DSC and redeems underlying collateral in one transaction
     */
    function redeemCollateralForDsc(address addressOfCollateral, uint256 amountOfCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(addressOfCollateral, amountOfCollateral);
        // redeemCollateral already checks HealthFactor, so no need to check here
    }

    // In order to redeem collateral:
    // 1. Health factor must remain over 1 AFTER collateral is pulled out
    function redeemCollateral(address addressOfCollateral, uint256 amountOfCollateral)
        public
        moreThanZero(amountOfCollateral)
        nonReentrant
    {
        _redeemCollateral(addressOfCollateral, amountOfCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Follows CEI
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     * @notice They must have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        // If they minted too much ($150 DSC dept to $100 ETH collateral)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    // As we are burning the dept, we do not need to check the healthFactor but adding as backup
    function burnDsc(uint256 amountDscToBurn) public moreThanZero(amountDscToBurn) {
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // probably not required as it would not be hit...
    }

    // If we do start nearing underCollateralization, we need someone to liquidate the positions
    // $75 collateral backing $50 DSC is under the threshold
    // Liquidator takes the collateral backing and burns off the $50 DSC dept
    // If someone is almost underCollateralized, wee will pay you to liquidate them!!

    /**
     * @param addressOfCollateral The ERC20 address of the collateral to liquidate from the user
     * @param userUnderCollateralized The user who has broken the health Factor. Their _healthFactor should be below MIN_HEALTH_FACTOR
     * @param deptToCover The amount of DSC you want to burn to improve the users health factor
     * @notice You can partically liquidate a user.
     * @notice You will get a liquidation bonus for taking the user funds
     * @notice This function working assumes the protocol will be roughly 200% overCollateralized in order for this to work
     * @notice A known bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentive the liquidators
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     *
     * Follows CEI: Checks, Effects, Interactions
     */
    function liquidate(address addressOfCollateral, address userUnderCollateralized, uint256 deptToCover)
        external
        moreThanZero(deptToCover)
        nonReentrant
    {
        // need to check the healthFactor of the user
        uint256 startingUserHealthFactor = _healthFactor(userUnderCollateralized);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOK();
        }
        // We want to burn their DSC "dept"
        // and take their collateral
        // Bad User Has --> $140 ETH, $100 DSC
        // deptToCover = $100
        uint256 tokenAmountFromDeptCovered = getTokenAmountFromUsd(addressOfCollateral, deptToCover);
        // And give them a 10% bonus as incentative to pay the dept
        // So we are giving the liquidator $110 of WETH for $100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // We should sweep extra amount into a treasury
        uint256 bonusCollateral = (tokenAmountFromDeptCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDeptCovered + bonusCollateral;
        _redeemCollateral(addressOfCollateral, totalCollateralToRedeem, userUnderCollateralized, msg.sender);
        // We need to burn the DSC
        _burnDsc(deptToCover, userUnderCollateralized, msg.sender);

        // As the internal function does not check the healthFactor, we must perform a check
        uint256 endingUserHealthFactor = _healthFactor(userUnderCollateralized);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    //////////////////////////////////////////
    // Private and Internal View Functions  //
    //////////////////////////////////////////

    /**
     * @dev Low-level Internal function, do not call unless the function calling it is checking for health factors being broken
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        // This condition is hypothtically unreachable as transFrom function will create the revert if issues
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address addressOfCollateral, uint256 amountOfCollateral, address from, address to)
        private
    {
        s_collateralDeposited[from][addressOfCollateral] -= amountOfCollateral;
        emit CollateralRedeemed(from, to, addressOfCollateral, amountOfCollateral);
        // We violate the CEI in this instance as it will be more gas efficient and it will revert the transaction if HealthFactor is broken after the pull
        bool success = IERC20(addressOfCollateral).transfer(to, amountOfCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }
    /**
     * Returns how close to liquidation a user is
     * If a user goes below 1, than they can get liquidated
     */

    function _healthFactor(address user) private view returns (uint256 healthFactor) {
        // We need total DSC minted
        // We need total VALUE of collateral deposited
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        // return (collateralValueInUsd / totalDscMinted); Not correct as this is 1:1 without a threshold
        // $150 ETH / 100 DSC = 1.5
        // $150 * 50 = 7500 / 100 = (75 / 100) < 1

        // $1000 ETH / 100 DSC
        // 1000 * 50 = 50,000 / 100 = 500 /100 = 5 which is > 1
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return ((collateralAdjustedForThreshold * PRECISION) / totalDscMinted); // BUG ==> totalDscMinted can not equal 0
    }

    // 1. Check health factor (do they have enouugh collateral?)
    // 2. Revert if they do not have enough!
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    //////////////////////////////////////////
    // Public and External View Functions   //
    //////////////////////////////////////////

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getTokenAmountFromUsd(address addressOfCollateral, uint256 usdAmountInWei)
        public
        view
        returns (uint256 collateralAmountInWei)
    {
        // price of ETH (token)
        // $/ETH ETH ??
        // If ETH is $2000. $1000 = 0.5 ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[addressOfCollateral]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        //             ($10e18 * 1e18)       / ($2000e8 * 1e10)     = ne18
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through each collateral token and get the amount they have deposited, and map it to the price, to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256 usdValueOfToken) {
        // gets the price using chainlink of a given token address
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 1 ETH = $1000
        // The returned value from chainlink will be 1000 * 1e8
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; // ((1000 * 1e8 * (1e10)) * 1000 * 1e18) which means we are at 1e36, so we need to divide by 1e18 to return back to 1e18
    }

    function getHealthFactor(address user) external view returns (uint256 userHealthFactor) {
        return _healthFactor(user);
    }

    function getDsc() external view returns (address dsc) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address priceFeed) {
        return s_priceFeeds[token];
    }

    function getCollateralTokens() external view returns (address[] memory tokenList) {
        return s_collateralTokens;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256 additionalFeedPrecision) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getPrecision() external pure returns (uint256 precision) {
        return PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256 liquidationTheshold) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationPrecision() external pure returns (uint256 liquidationPrecision) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256 minHealthFactor) {
        return MIN_HEALTH_FACTOR;
    }

    function getLiquidationBonus() external pure returns (uint256 liquidationBonus) {
        return LIQUIDATION_BONUS;
    }
}
