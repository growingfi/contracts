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

contract GrowStrategyAutoLike is BaseGrowStrategy {
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

    constructor(
        address _rewarderAddress,
        address _SWAP_UTILS,
        address _MASTER_CHEF_LIKE,
        uint256 _MASTER_CHEF_LIKE_POOL_ID,
        address _UNDERLYING_REWARD_TOKEN,
        address _AUTO_STRATX,
        address _STAKING_TOKEN
    ) public  BaseGrowStrategy(_rewarderAddress, _SWAP_UTILS) {
        MASTER_CHEF_LIKE = _MASTER_CHEF_LIKE;
        MASTER_CHEF_LIKE_POOL_ID = _MASTER_CHEF_LIKE_POOL_ID;
        UNDERLYING_REWARD_TOKEN = _UNDERLYING_REWARD_TOKEN;
        AUTO_STRATX = _AUTO_STRATX;
        STAKING_TOKEN = _STAKING_TOKEN;
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

    function _underlyingShareAmount() public view returns (uint256) {
        (uint256 amount,) = IMasterChefLike(MASTER_CHEF_LIKE).userInfo(MASTER_CHEF_LIKE_POOL_ID, address(this));
        return amount;
    }

    function _underlyingWantTokenAmount() public view override returns (uint256) {
        return _underlyingShareAmount().mul(_underlyingWantTokenPreShares()).div(_DECIMAL);
    }

    // --------------------------------------------------------------
    // User Write Interface
    // --------------------------------------------------------------

    function deposit(uint256 wantTokenAmount) external nonEmergency nonReentrant {
        _deposit(wantTokenAmount);
    }

    // --------------------------------------------------------------
    // Interactive with under contract
    // --------------------------------------------------------------

    function _depositUnderlying(uint256 amount) internal override returns (uint256) {
        uint256 underlyingSharesAmountBefore = _underlyingShareAmount();

        approveToken(STAKING_TOKEN, MASTER_CHEF_LIKE, amount);
        IMasterChefLike(MASTER_CHEF_LIKE).deposit(MASTER_CHEF_LIKE_POOL_ID, amount);

        return _underlyingShareAmount().sub(underlyingSharesAmountBefore).mul(_underlyingWantTokenPreShares()).div(_DECIMAL);
    }

    function _withdrawUnderlying(uint256 amount) internal override returns (uint256) {
        uint256 _before = IERC20(STAKING_TOKEN).balanceOf(address(this));
        IMasterChefLike(MASTER_CHEF_LIKE).withdraw(MASTER_CHEF_LIKE_POOL_ID, amount);

        return IERC20(STAKING_TOKEN).balanceOf(address(this)).sub(_before);
    }

    function _wantTokenPriceInBNB(uint256 amount) public view override returns (uint256) {
        return SwapUtils(SWAP_UTILS).tokenPriceInBNB(STAKING_TOKEN, amount);
    }

    function _receiveToken(address sender, uint256 amount) internal override {
        IERC20(STAKING_TOKEN).safeTransferFrom(sender, address(this), amount);
    }

    function _sendToken(address receiver, uint256 amount) internal override {
        IERC20(STAKING_TOKEN).safeTransfer(receiver, amount);
    }

    function _harvest() internal override {
        // if no token staked in underlying contract
        if (_underlyingWantTokenAmount() <= 0) return;

        // harvest underlying
        _withdrawUnderlying(0);

        _tryReinvest();
    }

    function _tryReinvest() internal override {
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

        emit LogReinvest(msg.sender, stakingTokenAmount);
    }

    function _swapRewardTokenToWBNB(uint256 amount) internal override returns (uint256) {
        // exchange to wBNB
        return _swap(STAKING_TOKEN, WRAPPED_NATIVE_TOKEN, amount);
    }

    // --------------------------------------------------------------
    // !! Emergency !!
    // --------------------------------------------------------------

    function emergencyExit() external override onlyOwner {
        IMasterChefLike(MASTER_CHEF_LIKE).withdraw(MASTER_CHEF_LIKE_POOL_ID, uint256(-1));
        IS_EMERGENCY_MODE = true;
    }

    function emergencyWithdraw() external override onlyEmergency nonReentrant {
        uint256 shares = userShares[msg.sender];

        _notifyUserSharesUpdate(msg.sender, 0, false);
        userShares[msg.sender] = 0;
        userPrincipal[msg.sender] = 0;

        // withdraw from under contract
        uint256 currentBalance = IERC20(STAKING_TOKEN).balanceOf(address(this));
        uint256 amount = currentBalance.mul(shares).div(totalShares);
        totalShares = totalShares.sub(shares);

        _getGrowRewards(msg.sender);
        IERC20(STAKING_TOKEN).safeTransfer(msg.sender, amount);
    }

}
