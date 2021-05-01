// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IGrow.sol";
import "../utils/SwapUtils.sol";

abstract contract BaseGrowStrategy is Ownable, ReentrancyGuard, IGrowStrategy {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 constant _DECIMAL = 1e18;

    IGrowRewarder public growRewarder;

    /// @dev total shares of this strategy
    uint256 public override totalShares;

    /// @dev user share
    mapping (address => uint256) internal userShares;

    /// @dev user principal
    mapping (address => uint256) internal userPrincipal;

    /// @dev Threshold for swap reward token to staking token for save gas fee
    uint256 public rewardTokenSwapThreshold = 1e16;

    /// @dev Threshold for reinvest to save gas fee
    uint256 public stakingTokenReinvestThreshold = 1e16;

    /// @dev Utils for swap token and get price in BNB
    address public SWAP_UTILS;

    /// @dev For reduce amount which is toooooooo small
    uint256 constant DUST = 1000;

    /// @dev Will be WBNB address in BSC Network
    address public constant WRAPPED_NATIVE_TOKEN = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    constructor(
        address rewarderAddress,
        address _SWAP_UTILS
    ) public {
        growRewarder = IGrowRewarder(rewarderAddress);
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
    // Misc
    // --------------------------------------------------------------

    function approveToken(address token, address to, uint256 amount) internal {
        if (IERC20(token).allowance(address(this), to) < amount) {
            IERC20(token).safeApprove(to, 0);
            IERC20(token).safeApprove(to, uint256(~0));
        }
    }

    function _swap(address tokenA, address tokenB, uint256 amount) internal returns (uint256) {
        approveToken(tokenA, SWAP_UTILS, amount);
        uint256 tokenReceived = SwapUtils(SWAP_UTILS).swap(tokenA, tokenB, amount);
        IERC20(tokenB).transferFrom(SWAP_UTILS, address(this), tokenReceived);
        return tokenReceived;
    }

    // --------------------------------------------------------------
    // User Read interface (shares and principal)
    // --------------------------------------------------------------

    function sharesOf(address account) public override view returns (uint256) {
        return userShares[account];
    }

    function principalOf(address account) public view returns (uint256) {
        return userPrincipal[account];
    }

    // --------------------------------------------------------------
    // User Read Interface
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
    // User Write Interface
    // --------------------------------------------------------------

    function harvest() external nonEmergency nonReentrant {
        _harvest();
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
    // Deposit and withdraw
    // --------------------------------------------------------------

    function _deposit(uint256 wantTokenAmount) internal {
        require(wantTokenAmount > DUST, "GrowStrategy: amount toooooo small");

        _receiveToken(msg.sender, wantTokenAmount);

        // save current underlying want token amount for caluclate shares
        uint underlyingWantTokenAmountBeforeEnter = _underlyingWantTokenAmount();

        // receive token and deposit into underlying contract
        uint256 wantTokenAdded = _depositUnderlying(wantTokenAmount);

        // calculate shares
        uint256 sharesAdded = 0;
        if (totalShares == 0) {
            sharesAdded = wantTokenAdded;
        } else {
            sharesAdded = totalShares
                .mul(wantTokenAdded).mul(_DECIMAL)
                .div(underlyingWantTokenAmountBeforeEnter).div(_DECIMAL);
        }

        // notice shares change for rewarder
        _notifyUserSharesUpdate(msg.sender, userShares[msg.sender].add(sharesAdded), false);

        // add our shares
        totalShares = totalShares.add(sharesAdded);
        userShares[msg.sender] = userShares[msg.sender].add(sharesAdded);

        // add principal in real want token amount
        userPrincipal[msg.sender] = userPrincipal[msg.sender].add(wantTokenAdded);

        // notice rewarder add deposit reward
        _depositRewardAddReward(
            msg.sender,
            _wantTokenPriceInBNB(wantTokenAdded)
        );

        _tryReinvest();

        emit LogDeposit(msg.sender, wantTokenAmount, wantTokenAdded, sharesAdded);
    }

    function _withdraw(uint256 wantTokenAmount) internal {
        require(userShares[msg.sender] > 0, "GrowStrategy: user without shares");

        // calculate max amount
        uint256 wantTokenRemoved = Math.min(
            userPrincipal[msg.sender],
            wantTokenAmount
        );

        // reduce principal dust
        if (userPrincipal[msg.sender].sub(wantTokenRemoved) < DUST) {
            wantTokenRemoved = userPrincipal[msg.sender];
        }

        // calculate shares
        uint256 shareRemoved = Math.min(
            userShares[msg.sender],
            wantTokenRemoved
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
        userPrincipal[msg.sender] = userPrincipal[msg.sender].sub(wantTokenRemoved);

        // withdraw from under contract
        uint256 withdrawnWantTokenAmount = _withdrawUnderlying(wantTokenRemoved);
        _sendToken(msg.sender, withdrawnWantTokenAmount);

        _tryReinvest();

        emit LogWithdraw(msg.sender, wantTokenAmount, withdrawnWantTokenAmount, shareRemoved);
    }

    function _getRewards() internal {
        // get current earned
        uint earnedWantTokenAmount = earnedOf(msg.sender);

        if (earnedWantTokenAmount > 0) {
            // calculate shares
            uint256 shareRemoved = Math.min(
                userShares[msg.sender],
                earnedWantTokenAmount
                    .mul(totalShares).mul(_DECIMAL)
                    .div(_underlyingWantTokenAmount()).div(_DECIMAL)
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
                _sendToken(msg.sender, earnedWantTokenAmount);
            }

            _tryReinvest();

            emit LogGetReward(msg.sender, earnedWantTokenAmount, shareRemoved);
        } else {
            _harvest();
        }

        // get GROWs :P
        _getGrowRewards(msg.sender);
    }

    function _addProfitReward(address userAddress, uint256 amount) internal returns (uint256) {
        if (address(growRewarder) != address(0) && amount > DUST) {
            // get 30% earned for profit reward
            uint256 earnedForProfitReward = amount.mul(30).div(100);

            // exchange to wBNB
            uint256 wBNBExchanged = _swapRewardTokenToWBNB(earnedForProfitReward);

            if (wBNBExchanged > 0) {
                // notify GrowMaster
                approveToken(WRAPPED_NATIVE_TOKEN, address(growRewarder), wBNBExchanged);
                _profitRewardAddReward(userAddress, address(WRAPPED_NATIVE_TOKEN), wBNBExchanged);

                return earnedForProfitReward;
            }
        }

        return 0;
    }

    // --------------------------------------------------------------
    // Interactive with under contract
    // --------------------------------------------------------------

    function _wantTokenPriceInBNB(uint256 amount) public view virtual returns (uint256);
    function _underlyingWantTokenAmount() public virtual view returns (uint256);
    function _receiveToken(address sender, uint256 amount) internal virtual;
    function _sendToken(address receiver, uint256 amount) internal virtual;
    function _tryReinvest() internal virtual;
    function _depositUnderlying(uint256 wantTokenAmount) internal virtual returns (uint256);
    function _withdrawUnderlying(uint256 wantTokenAmount) internal virtual returns (uint256);
    function _swapRewardTokenToWBNB(uint256 amount) internal virtual returns (uint256);
    function _harvest() internal virtual;

    // --------------------------------------------------------------
    // Call rewarder
    // --------------------------------------------------------------

    modifier onlyHasRewarder {
        if (address(growRewarder) != address(0)) {
            _;
        }
    }

    function _setRewarder(address rewarderAddress) external onlyOwner {
        growRewarder = IGrowRewarder(rewarderAddress);
    }

    function _depositRewardAddReward(address userAddress, uint256 amountInNativeToken) internal onlyHasRewarder {
        growRewarder.depositRewardAddReward(address(this), userAddress, amountInNativeToken);
    }

    function _profitRewardAddReward(address userAddress, address profitToken, uint256 profitTokenAmount) internal onlyHasRewarder {
        growRewarder.profitRewardAddReward(address(this), profitToken, userAddress, profitTokenAmount);
    }

    function _notifyUserSharesUpdate(address userAddress, uint256 shares, bool isWithdraw) internal onlyHasRewarder {
        growRewarder.notifyUserSharesUpdate(address(this), userAddress, shares, isWithdraw);
    }

    function _getGrowRewards(address userAddress) internal onlyHasRewarder {
        growRewarder.getRewards(address(this), userAddress);
    }

    // --------------------------------------------------------------
    // !! Emergency !!
    // --------------------------------------------------------------

    bool public override IS_EMERGENCY_MODE = false;

    modifier nonEmergency() {
        require(IS_EMERGENCY_MODE == false, "GrowStrategy: emergency mode.");
        _;
    }

    modifier onlyEmergency() {
        require(IS_EMERGENCY_MODE == true, "GrowStrategy: not emergency mode.");
        _;
    }

    function emergencyExit() external virtual;
    function emergencyWithdraw() external virtual;

    // --------------------------------------------------------------
    // Events
    // --------------------------------------------------------------
    event LogDeposit(address user, uint256 wantTokenAmount, uint wantTokenAdded, uint256 shares);
    event LogWithdraw(address user, uint256 wantTokenAmount, uint withdrawWantTokenAmount, uint256 shares);
    event LogReinvest(address user, uint256 amount);
    event LogGetReward(address user, uint256 amount, uint256 shares);

}
