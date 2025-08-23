// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/** 
 * @title RebaseToken
 * @author ChaddB
 * @notice This is a cross-chain rebase token that incentivizes users to deposit into a vault
 * @notice The interest rate in the smart contract can only decrease 
 * @notice Each user will have their own interest that is the global interest rate at the time of deposit
*/

contract RebaseToken is ERC20, Ownable, AccessControl {

    error RebaseToken__InterestRateCanOnlyDecrease(uint256 interestRate, uint256 newInterestRate);

    uint256 private s_interestRate = (5 * PRECISION_FACTOR) / 1e8;
    uint256 private constant PRECISION_FACTOR = 1e18;
    bytes32 private constant MINT_AND_BURN_ROLE = keccak256("MINT_AND_BURN_ROLE");

    mapping (address => uint256) private s_userInterestRate;
    mapping (address => uint256) private s_userLastUpdatedTimestamp;

    event RebaseToken__InterestRateSet(uint256 newInterestRate);

    constructor() ERC20("Rebase Token", "RBT") Ownable(msg.sender) {}

    function grantMintAndBurnRole(address _account) external onlyOwner {
        _grantRole(MINT_AND_BURN_ROLE, _account);
    }

    /** 
    * @notice Set the interest rate in the contract
    * @param _newInterestRate the new Interest rate to set
    * @dev The interest rate can only decrease
    */
    function setInterestRate(uint256 _newInterestRate) external onlyOwner {
        // Set the interest rate
        if(_newInterestRate >= s_interestRate) {
            revert RebaseToken__InterestRateCanOnlyDecrease(s_interestRate, _newInterestRate);
        }

        s_interestRate = s_interestRate;
        emit RebaseToken__InterestRateSet(_newInterestRate);
    }

    /**
    * @notice Give the principle balance of a user. This is the number of tokens that have currently been minted to the user,
    * not including any interest that has accrued since the last time the user interacted with the protocol
    * @param _user The user to get the principle balance for
    */
    function principleBalanceOf(address _user) external view returns(uint256) {
        return super.balanceOf(_user);
    }

    /**
    * @notice Get the interest rate that is currently set for the contract. Any future depositor will receive this interest rate
    */
    function getInterestRate() external view returns(uint256) {
        return s_interestRate;
    }

    /**
     * @notice mint the user tokens when they deposit into the vaykt
     * @param _to The user to mint the tokens to
     * @param _amount The amount of tokens to mint
     */
    function mint(address _to, uint256 _amount, uint256 _interestRate) external onlyRole(MINT_AND_BURN_ROLE) {
        _mintAccruedInterest(_to);
        s_userInterestRate[_to] = _interestRate;
        _mint(_to, _amount);
    }

    /**
    * @notice Burn the user tokens when they withdraw from the vault
    * @param _from The user to burn the tokens from
    * @param _amount The amount of tokens to burn
    */
    function burn(address _from, uint256 _amount) external onlyRole(MINT_AND_BURN_ROLE) {
        _mintAccruedInterest(_from);
        _burn(_from, _amount);
    }

    /**
    * @notice Minte the accrued interest to the user since the last time they interacted with the protocol(e.g burn, mint, transfer)
    * @param _user The user to mint the accrued interest to
    */
    function _mintAccruedInterest(address _user) internal {
        // Find their current balance of rebase tokens that have been minted to the user
        uint256 previousPrincipleBalance = super.balanceOf(_user);
        // Calculate their current balance including any interest -> balanceOf
        uint256 currentBalance = balanceOf(_user);
        // calculate the number of tokens that need to be minted to the user
        uint256 balanceIncrease = currentBalance - previousPrincipleBalance;
        // call _mint to mint the tokens to the user
        // set the users last updated timestamp
        s_userLastUpdatedTimestamp[_user] = block.timestamp;
        _mint(_user, balanceIncrease);
    }

    /**
    * calculate the balance for the user including the interest that has accumulated since the
     */
    function balanceOf(address _user) public view override returns(uint256) {
        // get the current principle balance of the user (the number of tokens that have actually been minted
        // multiply the principle balance by the interest that has accumulated in the time the balance hasnt been updated
        return super.balanceOf(_user) * _calculateUserAccumulatedInterestSinceLastUpdate(_user) / PRECISION_FACTOR;
    }
    /**
    * @notice Transfer tokens from one user to another
    * @param _recipient The user to trasnfer the tokens to
    * @param _amount The amount of tokens to transfer
    * @return True if the transfer was successful
    */
    function transfer(address _recipient, uint256 _amount) public override returns(bool){
        _mintAccruedInterest(msg.sender);
        _mintAccruedInterest(_recipient);
        if(_amount == type(uint256).max) {
            _amount = balanceOf(msg.sender);
        }
        if (balanceOf(_recipient) == 0){
            s_userInterestRate[_recipient] = s_userInterestRate[msg.sender];
        }
        return super.transfer(_recipient, _amount);
    }

    /**
    * @notice Transfer tokens from one user to another
    * @param _sender The user to trasnfer the tokens from
    * @param _recipient The user to transfer the tokens to
    * @param _amount The amount of tokens to trasnfer
    * @return True if the transfer was successful
    */
    function transferFrom(address _sender, address _recipient, uint256 _amount) public override returns (bool) {
        _mintAccruedInterest(msg.sender);
        _mintAccruedInterest(_recipient);
        if(_amount == type(uint256).max) {
            _amount = balanceOf(msg.sender);
        }
        if (balanceOf(_recipient) == 0){
            s_userInterestRate[_recipient] = s_userInterestRate[msg.sender];
        }
        return super.transferFrom(_sender, _recipient, _amount);
    }

    function getUserInterestRate(address _user) external view returns(uint256) {
        return s_userInterestRate[_user];
    }
    /**
    * @notice Calculate the interest rate that has accumulated since the last update 
    * @param _user The user to calculate the interest accumulated  for
    * @return The interest that has accumulated since the last update
    */
    function _calculateUserAccumulatedInterestSinceLastUpdate(address _user) internal view returns(uint256){
        // we need to calculate the interest that has accumulated since the last update
        // This is going to be linear growth with time
        // 1. Calculate the time since the last update 
        // 2. Calculate the amount of linear growth
        // (principal amount) =  1 + amount * user interest rate * time elapsed
        // deposit : 10 tokens
        // interest rate 0.5 tokens per second 
        // time elapsed is 2 seconds
        // 10 + (10 * 0.5 * 2 )
        uint256 timeElapsed = block.timestamp - s_userLastUpdatedTimestamp[_user];
        uint256 linearInterest = (PRECISION_FACTOR + (s_userInterestRate[_user] * timeElapsed));
        return linearInterest;
    }
}