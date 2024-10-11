// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract DSCEngineTest is Test {
    // Contracts
    DeployDSC public deployer;
    DecentralizedStableCoin public dsc;
    DSCEngine public engine;
    HelperConfig public config;

    // HelperConfig
    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;
    address public deployerKey;

    //State Variables
    uint256 public constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;
    uint256 public constant LIQUIDATION_PRECISION = 100;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_BONUS = 10;

    // USER
    address public USER = makeAddr("user");
    uint256 public constant INITIAL_BALANCE = 100 ether;
    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant AMOUNT_OF_DSC_TO_MINT = 10 ether;

    // SetUp
    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_USER_BALANCE);
    }

    /////////////////////////
    // Constructor Tests   //
    /////////////////////////

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesandPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    ///////////////////
    // Price Tests   //
    ///////////////////

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000 = 30,000e18
        uint256 expectedEthAmountInUsd = 30000e18;
        uint256 actualUsdEthAmountInUsd = engine.getUsdValue(weth, ethAmount);
        assertEq(expectedEthAmountInUsd, actualUsdEthAmountInUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100e18; // In Wei
        // $2000 per ETH  --> $100/$2000  --> 0.05
        uint256 expectedWeth = 0.05 ether;

        uint256 actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    ////////////////////////////////
    // Deposit Collateral Tests   //
    ////////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        // ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock testToken = new ERC20Mock("Test Token", "TST", USER, INITIAL_BALANCE);
        vm.startPrank(USER);
        // ERC20Mock(testToken).approve(address(USER), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        engine.depositCollateral(address(testToken), STARTING_USER_BALANCE);
        vm.stopPrank;
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), INITIAL_BALANCE);
        engine.depositCollateral(weth, STARTING_USER_BALANCE);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);

        uint256 expectedDepositedAmount = engine.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(STARTING_USER_BALANCE, expectedDepositedAmount);
    }

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userDscBalance = dsc.balanceOf(USER);
        assertEq(userDscBalance, 0);
    }

    ///////////////////////
    // Mint Dsc Tests   ///
    ///////////////////////

    function testRevertsIfDscMintIsZero() public depositedCollateral {
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.mintDsc(0);
    }

    ////////////////////////////////////
    // View & Pure Functions Tests   ///
    ////////////////////////////////////

    function testGetDsc() public view {
        address dscAddress = engine.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    function testgetCollateralValueInUsdFromAccountInformation() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 expectedCollateralValueInUsd = engine.getUsdValue(weth, STARTING_USER_BALANCE);
        uint256 mintedDsc = 0;
        assertEq(expectedCollateralValueInUsd, collateralValueInUsd);
        assertEq(totalDscMinted, mintedDsc);
    }

    function testGetCollateralTokenPriceFeed() public view {
        address ethPriceFeed = engine.getCollateralTokenPriceFeed(weth);
        address btcPriceFeed = engine.getCollateralTokenPriceFeed(wbtc);
        assertEq(ethPriceFeed, ethUsdPriceFeed);
        assertEq(btcPriceFeed, btcUsdPriceFeed);
    }

    function testgetCollateralToken() public view {
        address[] memory tokenList = engine.getCollateralTokens();
        assertEq(weth, tokenList[0]);
        assertEq(wbtc, tokenList[1]);
    }

    function testtGetAdditionalFeedPrecision() public view {
        uint256 additionalFeedPrecision = engine.getAdditionalFeedPrecision();
        assertEq(additionalFeedPrecision, ADDITIONAL_FEED_PRECISION);
    }

    function testGetPrecision() public view {
        uint256 precision = engine.getPrecision();
        assertEq(precision, PRECISION);
    }

    function testGetLiquidationThreshold() public view {
        uint256 liquidationThreshold = engine.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetLiquidationPrecision() public view {
        uint256 LiquidationPrecision = engine.getLiquidationPrecision();
        assertEq(LiquidationPrecision, LIQUIDATION_PRECISION);
    }

    function testGetMinHealthFactor() public view {
        uint256 minHealthFactor = engine.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationBonus() public view {
        uint256 liquidationBonus = engine.getLiquidationBonus();
        assertEq(liquidationBonus, LIQUIDATION_BONUS);
    }
}
