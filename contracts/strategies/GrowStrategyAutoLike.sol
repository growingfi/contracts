// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IGrow.sol";
import "./BaseGrowStrategy.sol";
import "../utils/SwapUtils.sol";

interface IMasterChefLike {
    function userInfo(uint256, address) external view returns (uint256, uint256);
    function deposit(uint256 pid, uint256 _amount) external;
    function withdraw(uint256 pid, uint256 _amount) external;
}

interface IAutoStrategy {
    function wantLockedTotal() external view returns (uint256);
    function sharesTotal() external view returns (uint256);
}

contract GrowStrategyAutoLike is BaseGrowStrategy, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // --------------------------------------------------------------
    // Address
    // --------------------------------------------------------------

    /// @dev MasterChef address, for interactive underlying contract
    address public immutable MASTER_CHEF_LIKE;

    /// @dev Pool ID in MasterChef
    uint256 public immutable MASTER_CHEF_LIKE_POOL_ID;

    /// @dev Underlying reward token, like AUTO, SWAMP, etc.
    address public immutable UNDERLYING_REWARD_TOKEN;

    /// @dev Strategy address, for calucate want token amount in underlying contract
    address public immutable AUTO_STRATX;

    /// @dev Staking token
    address public immutable STAKING_TOKEN; //  = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82

    /// @dev Will be WBNB address in BSC Network
    address public constant WRAPPED_NATIVE_TOKEN = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    /// @dev For reduce amount which is toooooooo small
    uint256 constant DUST = 1000;

    /// @dev Utils for swap token and get price in BNB
    address public SWAP_UTILS;

    /// @dev Threshold for swap reward token to staking token for save gas fee
    uint256 public rewardTokenSwapThreshold = 1e16;

    /// @dev Threshold for reinvest to save gas fee
    uint256 public stakingTokenReinvestThreshold = 1e16;

    constructor(
        address rewarderAddress,
        address _MASTER_CHEF_LIKE,
        uint256 _MASTER_CHEF_LIKE_POOL_ID,
        address _UNDERLYING_REWARD_TOKEN,
        address _AUTO_STRATX,
        address _STAKING_TOKEN,
        address _SWAP_UTILS
    ) public {
        growRewarder = IGrowRewarder(rewarderAddress);
        MASTER_CHEF_LIKE = _MASTER_CHEF_LIKE;
        MASTER_CHEF_LIKE_POOL_ID = _MASTER_CHEF_LIKE_POOL_ID;
        UNDERLYING_REWARD_TOKEN = _UNDERLYING_REWARD_TOKEN;
        AUTO_STRATX = _AUTO_STRATX;
        STAKING_TOKEN = _STAKING_TOKEN;
        SWAP_UTILS = _SWAP_UTILS;
    }

    // --------------------------------------------------------------
    // Config Interface
    // --------------------------------------------------------------

    function updateThresholds(uint256 _rewardTokenSwapThreshold, uint256 _stakingTokenReinvestThreshold) external onlyOwner {
        rewardTokenSwapThreshold = _rewardTokenSwapThreshold;
        stakingTokenReinvestThreshold = _stakingTokenReinvestThreshold;
    }

    function updateSwapUtils(address _swapUtilsAddress) external onlyOwner {
        SWAP_UTILS = _swapUtilsAddress;
    }

    // --------------------------------------------------------------
    // Current strategy info in under contract
    // --------------------------------------------------------------

    function _underlyingWantTokenPreShares() public view returns(uint256) {
        uint256 wantLockedTotal = IAutoStrategy(AUTO_STRATX).wantLockedTotal();
        uint256 sharesTotal = IAutoStrategy(AUTO_STRATX).sharesTotal();

        if (sharesTotal == 0) return 0;
        return _DECIMAL.mul(wantLockedTotal).div(sharesTotal);
    }

    function _underlyingWantTokenAmount() public view returns (uint256) {
        (uint256 amount,) = IMasterChefLike(MASTER_CHEF_LIKE).userInfo(MASTER_CHEF_LIKE_POOL_ID, address(this));
        return amount.mul(_underlyingWantTokenPreShares()).div(_DECIMAL);
    }

    // --------------------------------------------------------------
    // Token swap
    // --------------------------------------------------------------

    function _swap(address tokenA, address tokenB, uint256 amount) private returns (uint256) {
        approveToken(tokenA, SWAP_UTILS, amount);
        return SwapUtils(SWAP_UTILS).swap(tokenA, tokenB, amount);
    }

    // --------------------------------------------------------------
    // User Read Interface (price in staking token)
    // --------------------------------------------------------------

    function totalBalance() public view returns(uint256) {
        return _underlyingWantTokenAmount();
    }

    function balanceOf(address account) public view returns(uint256) {
        if (totalShares == 0) return 0;
        if (sharesOf(account) == 0) return 0;

        return _underlyingWantTokenAmount().mul(sharesOf(account)).div(totalShares);
    }

    function earnedOf(address account) public view returns (uint256) {
        if (balanceOf(account) >= principalOf(account)) {
            return balanceOf(account).sub(principalOf(account));
        } else {
            return 0;
        }
    }

    // --------------------------------------------------------------
    // Private
    // --------------------------------------------------------------

    function _deposit(uint256 wantTokenAmount) private {
        require(wantTokenAmount > DUST, "GrowStrategyAutoLike: amount toooooo small");
        _harvest();

        // save current underlying want token amount for caluclate shares
        uint underlyingWantTokenAmountBeforeEnter = _underlyingWantTokenAmount();

        // receive token and deposit into underlying contract
        IERC20(STAKING_TOKEN).safeTransferFrom(msg.sender, address(this), wantTokenAmount);
        uint256 wantTokenAdded = _depositUnderlying(wantTokenAmount);

        // calculate shares
        uint256 sharesAdded = 0;
        if (totalShares == 0) {
            sharesAdded = wantTokenAdded;
        } else {
            sharesAdded = wantTokenAdded
                .mul(totalShares).mul(_DECIMAL)
                .div(underlyingWantTokenAmountBeforeEnter).div(_DECIMAL);
        }

        // notice shares change for rewarder
        _notifyUserSharesUpdate(msg.sender, userShares[msg.sender].add(sharesAdded), true);

        // add our shares
        totalShares = totalShares.add(sharesAdded);
        userShares[msg.sender] = userShares[msg.sender].add(sharesAdded);

        // add principal in real want token amount
        userPrincipal[msg.sender] = userPrincipal[msg.sender].add(wantTokenAdded);

        // notice rewarder add deposit reward
        _depositRewardAddReward(
            msg.sender,
            SwapUtils(SWAP_UTILS).tokenPriceInBNB(STAKING_TOKEN, wantTokenAdded)
        );

        emit LogDeposit(msg.sender, wantTokenAmount, wantTokenAdded, sharesAdded);
    }

    function _withdraw(uint256 wantTokenAmount) private {
        _harvest();

        // calculate max amount
        wantTokenAmount = Math.min(
            userPrincipal[msg.sender],
            wantTokenAmount
        );

        // reduce principal dust
        if (userPrincipal[msg.sender].sub(wantTokenAmount) < DUST) {
            wantTokenAmount = userPrincipal[msg.sender];
        }

        // calculate shares
        uint256 shareRemoved = Math.min(
            userShares[msg.sender],
            wantTokenAmount
                .mul(totalShares).mul(_DECIMAL)
                .div(_underlyingWantTokenAmount()).div(_DECIMAL)
        );

        // reduce share dust
        if (userShares[msg.sender].sub(shareRemoved) < DUST) {
            shareRemoved = userShares[msg.sender];
        }

        // notice shares change for rewarder
        _notifyUserSharesUpdate(msg.sender, userShares[msg.sender].sub(shareRemoved), true);

        // remove our shares
        totalShares = totalShares.sub(shareRemoved);
        userShares[msg.sender] = userShares[msg.sender].sub(shareRemoved);

        // remove principal
        // most time withdrawnWantTokenAmount = wantTokenAmount except underlying has withdraw fee
        userPrincipal[msg.sender] = userPrincipal[msg.sender].sub(wantTokenAmount);

        // withdraw from under contract
        uint256 withdrawnWantTokenAmount = _withdrawUnderlying(wantTokenAmount);
        IERC20(STAKING_TOKEN).safeTransfer(msg.sender, withdrawnWantTokenAmount);

        emit LogWithdraw(msg.sender, wantTokenAmount, withdrawnWantTokenAmount, shareRemoved);
    }

    function _getRewards() private {
        // get current earned
        uint earnedWantTokenAmount = earnedOf(msg.sender);

        // calculate shares
        uint256 shareRemoved = Math.min(
            earnedWantTokenAmount.mul(totalShares).div(_underlyingWantTokenAmount()),
            userShares[msg.sender]
        );

        // if principal already empty, take all shares
        if (userPrincipal[msg.sender] == 0) {
            shareRemoved = userShares[msg.sender];
        }

        // notice shares change for rewarder
        _notifyUserSharesUpdate(msg.sender, userShares[msg.sender].sub(shareRemoved), false);

        // remove shares
        totalShares = totalShares.sub(shareRemoved);
        userShares[msg.sender] = userShares[msg.sender].sub(shareRemoved);

        // withdraw
        earnedWantTokenAmount = _withdrawUnderlying(earnedWantTokenAmount);

        // take some for profit reward
        earnedWantTokenAmount = earnedWantTokenAmount.sub(_addProfitReward(msg.sender, earnedWantTokenAmount));

        // transfer
        if (earnedWantTokenAmount > 0) {
            IERC20(STAKING_TOKEN).safeTransfer(msg.sender, earnedWantTokenAmount);
        }

        // get GROWs :P
        _getGrowRewards(msg.sender);

        emit LogGetReward(msg.sender, earnedWantTokenAmount, shareRemoved);
    }

    function _harvest() private {
        // if no token staked in underlying contract
        if (_underlyingWantTokenAmount() <= 0) return;

        // harvest underlying
        _withdrawUnderlying(0);

        // get current reward token amount
        uint256 rewardTokenAmount = IERC20(UNDERLYING_REWARD_TOKEN).balanceOf(address(this));

        // if token amount too small, wait for save gas fee
        if (rewardTokenAmount < rewardTokenSwapThreshold) return;

        // swap reward token to staking token
        uint256 stakingTokenAmount = _swap(UNDERLYING_REWARD_TOKEN, STAKING_TOKEN, rewardTokenAmount);

        // get current staking token amount
        stakingTokenAmount = IERC20(STAKING_TOKEN).balanceOf(address(this));

        // if token amount too small, wait for save gas fee
        if (stakingTokenAmount < stakingTokenReinvestThreshold) return;

        // reinvest
        _depositUnderlying(stakingTokenAmount);

        emit LogHarvest(msg.sender, stakingTokenAmount);
    }

    function _addProfitReward(address userAddress, uint256 amount) private returns (uint256) {
        if (address(growRewarder) != address(0) && amount > DUST) {
            // get 30% earned for profit reward
            uint256 earnedForProfitReward = amount.mul(30).div(100);

            // exchange to wBNB
            uint256 wBNBExchanged = _swap(STAKING_TOKEN, WRAPPED_NATIVE_TOKEN, earnedForProfitReward);

            // notify GrowMaster
            approveToken(WRAPPED_NATIVE_TOKEN, address(growRewarder), wBNBExchanged);
            _profitRewardAddReward(userAddress, address(WRAPPED_NATIVE_TOKEN), wBNBExchanged);

            return earnedForProfitReward;
        }

        return 0;
    }

    // --------------------------------------------------------------
    // User Write Interface
    // --------------------------------------------------------------

    function harvest() external nonEmergency nonReentrant {
        _harvest();
    }

    function deposit(uint256 wantTokenAmount) external nonEmergency nonReentrant {
        _deposit(wantTokenAmount);
    }

    function withdraw(uint256 principalAmount) external nonEmergency nonReentrant {
        _withdraw(principalAmount);
    }

    function withdrawAll() external nonEmergency nonReentrant {
        _withdraw(uint256(~0));
        _getRewards();
    }

    function getRewards() external nonEmergency nonReentrant {
        _getRewards();
    }

    // --------------------------------------------------------------
    // Interactive with under contract
    // --------------------------------------------------------------

    function _depositUnderlying(uint256 amount) private returns (uint256) {
        uint256 currentUnderlyingShares = _underlyingWantTokenAmount();
        approveToken(STAKING_TOKEN, MASTER_CHEF_LIKE, amount);
        IMasterChefLike(MASTER_CHEF_LIKE).deposit(MASTER_CHEF_LIKE_POOL_ID, amount);

        return _underlyingWantTokenAmount().sub(currentUnderlyingShares);
    }

    function _withdrawUnderlying(uint256 amount) private returns (uint256) {
        uint256 _before = IERC20(STAKING_TOKEN).balanceOf(address(this));
        IMasterChefLike(MASTER_CHEF_LIKE).withdraw(MASTER_CHEF_LIKE_POOL_ID, amount);

        return IERC20(STAKING_TOKEN).balanceOf(address(this)).sub(_before);
    }

    // --------------------------------------------------------------
    // !! Emergency !!
    // --------------------------------------------------------------

    function emergencyExit() external onlyOwner {
        IMasterChefLike(MASTER_CHEF_LIKE).withdraw(MASTER_CHEF_LIKE_POOL_ID, uint256(-1));
        IS_EMERGENCY_MODE = true;
    }

    function emergencyWithdraw() external onlyEmergency nonReentrant {
        uint256 shares = userShares[msg.sender];

        _notifyUserSharesUpdate(msg.sender, 0, false);
        userShares[msg.sender] = 0;
        userPrincipal[msg.sender] = 0;

        // withdraw from under contract
        uint256 currentBalance = IERC20(STAKING_TOKEN).balanceOf(address(this));
        uint256 amount = currentBalance.mul(shares).div(totalShares);
        totalShares = totalShares.sub(shares);

        IERC20(STAKING_TOKEN).safeTransfer(msg.sender, amount);
    }

    // --------------------------------------------------------------
    // Events
    // --------------------------------------------------------------
    event LogDeposit(address user, uint256 wantTokenAmount, uint wantTokenAdded, uint256 shares);
    event LogWithdraw(address user, uint256 wantTokenAmount, uint withdrawWantTokenAmount, uint256 shares);
    event LogHarvest(address user, uint256 amount);
    event LogGetReward(address user, uint256 amount, uint256 shares);

}
