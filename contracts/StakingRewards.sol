// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "hardhat/console.sol"; // used in testing purposes

/**
 * @title Staking Rewards Smart contract
 * @author Al-Qa'qa'
 * @notice This contract works for staking tokens and earn rewards for staking
 */
contract StakingRewards is Ownable {
  event Stake(address staker, uint256 amount);
  event Withdraw(address staker, uint256 amount);
  event RewardsClaimed(address staker, uint256 reward);

  //////////////
  /// errors ///
  //////////////

  error StakingRewards__StakingDurationNotFinished(uint256 finishAt);
  error StakingRewards__ZeroRewardRate();
  error StakingRewards__ZeroStakingAmount();
  error StakingRewards__ZeroWithdrawAmount();
  error StakingRewards__RewardsGreaterThanBalance(
    uint256 rewards,
    uint256 balance
  );
  error StakingRewards__ZeroRewards();

  /////////////////
  /// variables ///
  /////////////////

  IERC20 private immutable _i_stakingToken;
  IERC20 private immutable _i_rewardToken;

  uint256 private _duration; // stake duration
  uint256 private _finishAt; // the time at which the staking will end
  uint256 private _updatedAt; // the last time a staking is updates
  uint256 private _rewardRate; // staking rewardRate (how many tokens gived in second)
  uint256 private _rewardPerToken; // staking reward tokens per each stake token
  uint256 private _totalSupply; // the total supply of stake tokens in the contract

  // `_rewardPerToken` at the time a user made an update (stake or withdraw)
  mapping(address => uint256) public userRewardPerTokenPaid;
  // stakers rewardTokens balance (this is the value of the previous rewards of the staker, that is calculated when he made another stake)
  mapping(address => uint256) public rewards;
  // stakers stake tokens balance
  mapping(address => uint256) public balanceOf;

  modifier updateReward(address _account) {
    _rewardPerToken = calcRewardPerToken();
    _updatedAt = lastTimeRewardApplicable();
    rewards[_account] = getUserEarnings(_account);
    userRewardPerTokenPaid[_account] = _rewardPerToken;
    _;
  }

  /**
   * @notice deploying `stakingRewards` contract
   *
   * @param _stakingToken ERC20 token address that is used for staking
   * @param _rewardToken ERC20 token address that is used as rewards for stakers
   */
  constructor(address _stakingToken, address _rewardToken) {
    _i_stakingToken = IERC20(_stakingToken);
    _i_rewardToken = IERC20(_rewardToken);
  }

  /**
   * @notice update the time duration for staking tokens
   *
   * @param duration_ staking time duration
   */
  function setRewardsDuration(uint256 duration_) external onlyOwner {
    if (_finishAt >= block.timestamp) {
      revert StakingRewards__StakingDurationNotFinished(_finishAt);
    }
    _duration = duration_;
  }

  /**
   * @notice add some reward tokens to the stakers
   * @dev reward token amount is increasing and not updated
   *      if you call the function it increases the amount you passed with the old existing amount
   * @dev we passed `address(0)` to the `updateReward` modifier as the deployer can't be a staker
   *
   * @param _amount token amount used as reward for stakers
   */
  function notifyRewardAmount(uint256 _amount) external onlyOwner {
    _rewardPerToken = calcRewardPerToken();

    // If the staking is not started yet, we will set rewardRate
    if (block.timestamp > _finishAt) {
      _rewardRate = _amount / _duration;
    } else {
      // If the staking starts then we will add the amount to the old amount
      uint256 remainingRewards = _rewardRate * (_finishAt - block.timestamp);
      _rewardRate = (remainingRewards + _amount) / _duration;
    }

    if (_rewardRate == 0) revert StakingRewards__ZeroRewardRate();

    // Check that the contract has enought tokens to give to the stakers
    if (_rewardRate * _duration > _i_rewardToken.balanceOf(address(this))) {
      revert StakingRewards__RewardsGreaterThanBalance(
        _rewardRate * _duration,
        _i_rewardToken.balanceOf(address(this))
      );
    }

    _finishAt = block.timestamp + _duration;
    _updatedAt = block.timestamp;
  }

  /**
   * @notice stake some tokens in order to get some reward tokens
   *
   * @param _amount tokens to be staked
   */
  function stake(uint256 _amount) external updateReward(msg.sender) {
    if (_amount == 0) {
      revert StakingRewards__ZeroStakingAmount();
    }
    _i_stakingToken.transferFrom(msg.sender, address(this), _amount);
    balanceOf[msg.sender] += _amount;
    _totalSupply += _amount;

    emit Stake(msg.sender, _amount);
  }

  /**
   * @notice allow user to withdraw his stakeTokens if needed
   *
   * @param _amount amount of stakeTokens to withdraw
   */
  function withdraw(uint256 _amount) external updateReward(msg.sender) {
    if (_amount == 0) {
      revert StakingRewards__ZeroWithdrawAmount();
    }
    // If the user withdrawed amount > his balance, the function will throw error to underflow.
    // You can add an if statment to check for uesr balance
    balanceOf[msg.sender] -= _amount;
    _totalSupply -= _amount;

    _i_stakingToken.transfer(msg.sender, _amount);

    emit Withdraw(msg.sender, _amount);
  }

  /**
   * @notice withdraw the rewardTokens that is earned by the stake
   */
  function claimRewards() external updateReward(msg.sender) {
    uint256 reward = rewards[msg.sender];
    if (reward == 0) {
      revert StakingRewards__ZeroRewards();
    }

    rewards[msg.sender] = 0;
    _i_rewardToken.transfer(msg.sender, reward);

    emit RewardsClaimed(msg.sender, reward);
  }

  //////////////////////
  /// view functions ///
  //////////////////////

  /// @notice the time in which at which this staking is oin
  function lastTimeRewardApplicable() public view returns (uint256) {
    return _min(block.timestamp, getFinishAt());
  }

  /**
   * Calculating the rewardperToken in a certin time
   *
   * - R(j)   => the rewardPerToken in a given interval (from the last time an update occuars to the current time)
   * - R(j0)  => The rewardPerToken from the previous calculations
   * - R      => rewardRate
   * - T      => totalSupply
   * - j      => current time (block.timestamp)
   * - j0     => the last time we calculated the rewardperToken
   *
   * R(j) = R(j0) + R/T * (j - j0)
   */
  function calcRewardPerToken() public view returns (uint256) {
    if (getTotalSupply() == 0) {
      return _rewardPerToken;
    }
    return
      _rewardPerToken +
      (getRewardRate() * (lastTimeRewardApplicable() - getUpdatedAt()) * 1e18) /
      getTotalSupply();
  }

  /**
   * @notice calculate the amount earned by the staker
   *
   * @param _account staker address
   */
  function getUserEarnings(address _account) public view returns (uint256) {
    return
      (balanceOf[_account] *
        (calcRewardPerToken() - userRewardPerTokenPaid[_account])) /
      1e18 +
      rewards[_account];
  }

  function getStakingToken() public view returns (address) {
    return address(_i_stakingToken);
  }

  function getRewardToken() public view returns (address) {
    return address(_i_rewardToken);
  }

  function getDuration() public view returns (uint256) {
    return _duration;
  }

  function getRewardRate() public view returns (uint256) {
    return _rewardRate;
  }

  function getFinishAt() public view returns (uint256) {
    return _finishAt;
  }

  function getUpdatedAt() public view returns (uint256) {
    return _updatedAt;
  }

  function getTotalSupply() public view returns (uint256) {
    return _totalSupply;
  }

  function getRewardPerToken() public view returns (uint256) {
    return _rewardPerToken;
  }

  //////////////////////
  /// pure functions ///
  //////////////////////

  function _min(uint x, uint y) private pure returns (uint) {
    return x <= y ? x : y;
  }
}
