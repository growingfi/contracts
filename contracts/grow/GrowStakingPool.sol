// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IGrow.sol";

contract GrowStakingPool is IGrowProfitReceiver, IGrowMembershipController, Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 constant _DECIMAL = 1e18;

    /// @notice Address of staking token (GROW)
    IERC20 public immutable stakingToken;
    /// @notice Address of reward token
    IERC20 public immutable rewardToken;

    uint256 public growLockedForMembership = 1e18;
    address public immutable membershipFeeCollector;

    struct UserInfo {
        uint256 balance;
        uint256 lockedBalance;
        uint256 rewardDebt;
    }

    /// @notice User infos
    mapping(address => UserInfo) public users;

    /// @notice Reward distribute like MasterChef mode
    uint256 public accRewardPreShare;

    /// @notice Total supply of staking token
    uint256 public totalSupply;

    constructor(
        address rewarderAddress,
        address stakingTokenAddress,
        address rewardTokenAddress,
        address membershipFeeCollectorAddress
    ) public {
        growRewarder = rewarderAddress;
        stakingToken = IERC20(stakingTokenAddress);
        rewardToken = IERC20(rewardTokenAddress);

        growDev = msg.sender;
        membershipFeeCollector = membershipFeeCollectorAddress;
    }

    // --------------------------------------------------------------
    // Misc
    // --------------------------------------------------------------

    /// @notice Grow Master
    address public immutable growRewarder;

    modifier onlyGrowRewarder {
        require(msg.sender == address(growRewarder), "GrowStakingPool: caller is not on the GrowMaster");
        _;
    }

    /// @dev grow developer
    address public growDev;

    /// @dev maybe transfer dev address to governance in future
    function updateDevAddress(address _devAddress) external {
        require(msg.sender == growDev, "dev: ?");
        growDev = _devAddress;
    }

    function updateGrowLockedForMembership(uint256 amount) external {
        require(msg.sender == growDev, "dev: ?");
        growLockedForMembership = amount;
    }

    // --------------------------------------------------------------
    // Harvest!
    // --------------------------------------------------------------

    function _harvest(address userAddress) private {
        UserInfo storage user = users[userAddress];
        uint256 pendingRewardAmount = user.balance
            .mul(accRewardPreShare).div(_DECIMAL)
            .sub(user.rewardDebt);
        user.rewardDebt = user.balance.mul(accRewardPreShare).div(_DECIMAL);

        if (pendingRewardAmount > 0) {
            rewardToken.safeTransfer(userAddress, pendingRewardAmount);
        }

        emit LogHarvest(userAddress, pendingRewardAmount);
    }

    // --------------------------------------------------------------
    // Read Interface
    // --------------------------------------------------------------

    function pendingReward(address userAddress) external view returns (uint256) {
        UserInfo storage user = users[userAddress];
        return user.balance.mul(accRewardPreShare).div(_DECIMAL).sub(user.rewardDebt);
    }

    function hasMembership(address userAddress) external view override returns (bool) {
        return users[userAddress].lockedBalance > 0;
    }

    // --------------------------------------------------------------
    // Write Interface
    // --------------------------------------------------------------

    function harvest() external nonReentrant {
        _harvest(msg.sender);
    }

    function deposit(uint256 amount) external nonReentrant {
        UserInfo storage user = users[msg.sender];

        _harvest(msg.sender);

        // 1. transfer
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        if (user.lockedBalance == 0 && user.balance.add(amount) >= growLockedForMembership) {
            user.balance = user.balance.add(amount).sub(growLockedForMembership);
            user.lockedBalance = growLockedForMembership;
            users[membershipFeeCollector].balance = users[membershipFeeCollector].balance.add(user.lockedBalance);
        } else {
            user.balance = user.balance.add(amount);
        }

        // 2. write balance
        totalSupply = totalSupply.add(amount);
        user.rewardDebt = user.balance.mul(accRewardPreShare).div(_DECIMAL);

        emit LogDeposit(msg.sender, amount);
    }

    function _withdraw(uint256 amount) private {
        UserInfo storage user = users[msg.sender];
        if (amount > user.balance.add(user.lockedBalance)) {
            amount = user.balance.add(user.lockedBalance);
        }

        _harvest(msg.sender);

        if (user.lockedBalance > 0 && user.balance < amount) {
            user.balance = user.balance.add(user.lockedBalance).sub(amount);
            users[membershipFeeCollector].balance = users[membershipFeeCollector].balance.sub(user.lockedBalance);
            user.lockedBalance = 0;
        } else {
            user.balance = user.balance.sub(amount);
        }

        // 1. write balance
        totalSupply = totalSupply.sub(amount);
        user.rewardDebt = user.balance.mul(accRewardPreShare).div(_DECIMAL);

        // 2. transfer
        stakingToken.safeTransfer(msg.sender, amount);

        emit LogWithdraw(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        _withdraw(amount);
    }

    function withdrawAll() external nonReentrant {
        _withdraw(uint256(~0));
    }

    // --------------------------------------------------------------
    // Grow Rewarder Operations
    // --------------------------------------------------------------

    function pump(uint256 amount) external override onlyGrowRewarder {
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);

        // Nobody share the rewards, take it to dev :P
        if (totalSupply == 0) {
            rewardToken.safeTransfer(growDev, amount);
        } else {
            accRewardPreShare = accRewardPreShare.add(
                amount.mul(_DECIMAL).div(totalSupply)
            );
        }

        emit LogPump(msg.sender, amount);
    }

    // --------------------------------------------------------------
    // Events
    // --------------------------------------------------------------
    event LogPump(address sender, uint256 amount);
    event LogDeposit(address user, uint256 amount);
    event LogWithdraw(address user, uint256 amount);
    event LogHarvest(address user, uint256 amount);

}