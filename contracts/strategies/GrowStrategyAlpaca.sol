// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./BaseGrowStrategy.sol";
import "../interfaces/IGrow.sol";

interface IAlpacaFairLaunch {
    function deposit(
        address _for,
        uint256 _pid,
        uint256 _amount
    ) external;

    function withdraw(
        address _for,
        uint256 _pid,
        uint256 _amount
    ) external;

    function withdrawAll(address _for, uint256 _pid) external;

    function emergencyWithdraw(uint256 _pid) external;

    // Harvest ALPACAs earn from the pool.
    function harvest(uint256 _pid) external;

    function pendingAlpaca(uint256 _pid, address _user) external view returns (uint256);

    function userInfo(uint256 _pid, address _user)
        external
        view
        returns (
            uint256 amount,
            uint256 rewardDebt,
            uint256 bonusDebt,
            uint256 fundedBy
        );
}

interface IAlpacaToken {
    function canUnlockAmount(address _account) external view returns (uint256);

    function unlock() external;

    // @dev move ALPACAs with its locked funds to another account
    function transferAll(address _to) external;
}

interface IAlpacaVault {
    // @dev Add more token to the lending pool. Hope to get some good returns.
    function deposit(uint256 amountToken) external payable;

    // @dev Withdraw token from the lending and burning ibToken.
    function withdraw(uint256 share) external;

    function totalToken() external view returns (uint256);

    function totalSupply() external view returns (uint256);
}

interface IBEP20 {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
}

contract GrowStrategyAlpaca is BaseGrowStrategy {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // --------------------------------------------------------------
    // Address
    // --------------------------------------------------------------

    /// @dev MasterChef address, for interactive underlying contract
    address public constant ALPACA_FAIR_LAUNCH = 0xA625AB01B08ce023B2a342Dbb12a16f2C8489A8F;

    /// @dev Pool ID in MasterChef
    uint256 public immutable ALPACA_FAIR_LAUNCH_POOL_ID;

    /// @dev Underlying reward token, ALPACA.
    address public immutable UNDERLYING_REWARD_TOKEN = 0x8F0528cE5eF7B51152A59745bEfDD91D97091d2F;

    /// @dev Strategy address, for calucate want token amount in underlying contract
    address public immutable ALPACA_VAULT;

    /// @dev Staking token
    address public immutable STAKING_TOKEN;

    constructor(
        address _rewarderAddress,
        address _SWAP_UTILS,
        address _STAKING_TOKEN,
        address _ALPACA_VAULT,
        uint256 _ALPACA_FAIR_LAUNCH_POOL_ID
    ) public BaseGrowStrategy(_rewarderAddress, _SWAP_UTILS) {
        STAKING_TOKEN = _STAKING_TOKEN;
        ALPACA_VAULT = _ALPACA_VAULT;
        ALPACA_FAIR_LAUNCH_POOL_ID = _ALPACA_FAIR_LAUNCH_POOL_ID;
    }

    // --------------------------------------------------------------
    // Current strategy info in under contract
    // --------------------------------------------------------------

    function _underlyingShareAmount() public view returns (uint256) {
        (uint256 amount,,,) = IAlpacaFairLaunch(ALPACA_FAIR_LAUNCH).userInfo(ALPACA_FAIR_LAUNCH_POOL_ID, address(this));
        return amount;
    }

    function _underlyingWantTokenPreShares() public view returns (uint256) {
        uint256 totalSupply = IAlpacaVault(ALPACA_VAULT).totalSupply();
        if (totalSupply <= 0) return _DECIMAL;

        return IAlpacaVault(ALPACA_VAULT).totalToken()
            .mul(_DECIMAL)
            .div(totalSupply);
    }

    function _underlyingWantTokenAmount() public override view returns (uint256) {
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

    function _depositUnderlying(uint256 wBNBAmount) internal override returns (uint256) {
        // 1. to vault
        uint256 ibTokenBefore = IERC20(ALPACA_VAULT).balanceOf(address(this));
        approveToken(STAKING_TOKEN, ALPACA_VAULT, wBNBAmount);
        IAlpacaVault(ALPACA_VAULT).deposit(wBNBAmount);
        uint256 ibTokenAmount = IERC20(ALPACA_VAULT).balanceOf(address(this)).sub(ibTokenBefore);

        // 2. to fair launch
        require(ibTokenAmount > 0, "GrowStrategyAlpaca: ibTokenAmount not good");
        approveToken(ALPACA_VAULT, ALPACA_FAIR_LAUNCH, ibTokenAmount);
        IAlpacaFairLaunch(ALPACA_FAIR_LAUNCH).deposit(address(this), ALPACA_FAIR_LAUNCH_POOL_ID, ibTokenAmount);

        return ibTokenAmount.mul(_underlyingWantTokenPreShares()).div(_DECIMAL);
    }

    function _withdrawUnderlying(uint256 wantTokenAmount) internal override returns (uint256) {
        uint256 masterChefShares = wantTokenAmount.mul(_DECIMAL).div(_underlyingWantTokenPreShares());

        // 1. from fair launch
        uint256 ibTokenBefore = IERC20(ALPACA_VAULT).balanceOf(address(this));
        IAlpacaFairLaunch(ALPACA_FAIR_LAUNCH).withdraw(address(this), ALPACA_FAIR_LAUNCH_POOL_ID, masterChefShares);
        uint256 ibTokenAmount = IERC20(ALPACA_VAULT).balanceOf(address(this)).sub(ibTokenBefore);

        // 2. from vault
        uint256 BNBBefore = IERC20(STAKING_TOKEN).balanceOf(address(this));
        IAlpacaVault(ALPACA_VAULT).withdraw(ibTokenAmount);
        uint256 BNBAmount = IERC20(STAKING_TOKEN).balanceOf(address(this)).sub(BNBBefore);

        return BNBAmount;
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

        IAlpacaFairLaunch(ALPACA_FAIR_LAUNCH).harvest(ALPACA_FAIR_LAUNCH_POOL_ID);

        _tryReinvest();
    }

    function _tryReinvest() internal override {
        if (IAlpacaToken(UNDERLYING_REWARD_TOKEN).canUnlockAmount(address(this)) > rewardTokenSwapThreshold) {
            IAlpacaToken(UNDERLYING_REWARD_TOKEN).unlock();
        }

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
        IAlpacaFairLaunch(ALPACA_FAIR_LAUNCH).withdrawAll(address(this), ALPACA_FAIR_LAUNCH_POOL_ID);
        IAlpacaVault(ALPACA_VAULT).withdraw(IERC20(ALPACA_VAULT).balanceOf(address(this)));
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
