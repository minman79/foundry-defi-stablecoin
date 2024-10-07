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

    //////////////////////
    // State Variables  //
    //////////////////////
    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;

    DecentralizedStableCoin private immutable i_dsc;
    ////////////////
    // Events     //
    ////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

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
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /////////////////////////
    // External Functions  //
    /////////////////////////

    function depositCollateralAndMintDsc() external {}

    /**
     *
     * @param addressOfCollateral The address of the token to deposit as collateral
     * @param amountOfCollateral  The amount of collateral to deposit
     */
    function depositCollateral(address addressOfCollateral, uint256 amountOfCollateral)
        external
        moreThanZero(amountOfCollateral)
        isAllowedToken(addressOfCollateral)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][addressOfCollateral] += amountOfCollateral;
        emit CollateralDeposited(msg.sender, addressOfCollateral, amountOfCollateral);
    }

    function redeemCollateralForDsc() external {}

    function redeemCollateral() external {}

    function mintDsc() external {}

    function burnDsc() external {}

    function liquidate() external {}

    function getHealthFactor() external view {}
}
