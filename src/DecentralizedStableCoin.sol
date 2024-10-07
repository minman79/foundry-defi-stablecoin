// SPDX-License_identifier: MIT

pragma solidity ^0.8.18;

// ERC20Burnable is an ERC20 contract so we can import ERC20 at the sametime
import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/*
 * @title DecentralizedStableCoin
 * @author Minesh Patel
 * Collateral: Exogenous (wETH & wBTC)
 * Minting: Algorithmic
 * Relative Stability: Pegged to USD
 * 
 * This is the contract meant to be governed by DSCEngine. This contract is just the ERC20 implementation of our stablecoin system.
 */

// We want the ERC20Burnable contracts as we will be burning DSC to maintain the pegged price
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__MustBeMoreThanZero();
    error DecentralizedStableCoin__BurnAmountExceedsBalance();
    error DecentralizedStableCoin__NotZeroAddress();
    // as the ERC20Burnable is an ERC20, we will need to add the ERC20 constructor

    constructor() ERC20("DecentralizedStableCoin", "DSC") {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        // burn amount must be more than zero
        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }
        // balance must be more or equal to amount being requested to burn
        if (balance < _amount) {
            revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        }
        // super keyword says to use the burn function from the parent class which is ERC20Burnable in this case and not this burn function
        super.burn(_amount);
    }

    // when you mint you want to return a boolean to show success if it mints
    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        // we dont want people minting to the zero address
        if (_to == address(0)) {
            revert DecentralizedStableCoin__NotZeroAddress();
        }
        // dont want to be minting zero tokens
        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }
        // no super keyword required here, as there is no mint function, but only a _mint function which we will be calling
        _mint(_to, _amount);
        return true;
    }
}
