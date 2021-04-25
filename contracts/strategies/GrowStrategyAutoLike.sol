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

interface IMasterChefLike {
    function userInfo(uint256, address) external view returns (uint256, uint256);
    function deposit(uint256 pid, uint256 _amount) external;
    function withdraw(uint256 pid, uint256 _amount) external;
}

interface IAutoStrategy {
    function wantLockedTotal() external view returns (uint256);
    function sharesTotal() external view returns (uint256);
}

interface IPancakeFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IBEP20 {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
}

interface IPCSRouterLike {
    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata, address to, uint256 deadline) external;
}

contract GrowStrategyAutoLike is BaseGrowStrategy, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // --------------------------------------------------------------
    // Address
    // --------------------------------------------------------------

    address public immutable MASTER_CHEF_LIKE;
    uint256 public immutable MASTER_CHEF_LIKE_POOL_ID;

    address public immutable UNDERLYING_REWARD_TOKEN;
    address public immutable AUTO_STRATX;

    address public constant STAKING_TOKEN = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address public constant WRAPPED_NATIVE_TOKEN = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    uint256 DUST = 1000;

    constructor(
        address rewarderAddress,
        address _MASTER_CHEF_LIKE,
        uint256 _MASTER_CHEF_LIKE_POOL_ID,
        address _UNDERLYING_REWARD_TOKEN,
        address _AUTO_STRATX
    ) public {
        growRewarder = IGrowRewarder(rewarderAddress);
        MASTER_CHEF_LIKE = _MASTER_CHEF_LIKE;
        MASTER_CHEF_LIKE_POOL_ID = _MASTER_CHEF_LIKE_POOL_ID;
        UNDERLYING_REWARD_TOKEN = _UNDERLYING_REWARD_TOKEN;
        AUTO_STRATX = _AUTO_STRATX;
    }

    // --------------------------------------------------------------
    // Misc
    // --------------------------------------------------------------

    IPancakeFactory private constant factory = IPancakeFactory(0xBCfCcbde45cE874adCB698cC183deBcF17952812);

    function tokenPriceInBNB(address _token) view public returns(uint256) {
        address pair = factory.getPair(_token, address(WRAPPED_NATIVE_TOKEN));
        uint256 decimal = uint256(IBEP20(_token).decimals());

        return IBEP20(WRAPPED_NATIVE_TOKEN)
            .balanceOf(pair).mul(10 ** decimal)
            .div(IBEP20(_token).balanceOf(pair));
    }

    // --------------------------------------------------------------
    // Token swap
    // --------------------------------------------------------------

    address public constant PCS_LIKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E; // BSC

    function _swap(address tokenA, address tokenB, uint256 amount) internal returns (uint256) {
        if (amount <= 0) {
            return 0;
        }

        IERC20(tokenA).safeApprove(PCS_LIKE_ROUTER, 0);
        IERC20(tokenA).safeApprove(PCS_LIKE_ROUTER, amount);

        address[] memory path;
        if (tokenA == WRAPPED_NATIVE_TOKEN || tokenB == WRAPPED_NATIVE_TOKEN) {
            path = new address[](2);
            path[0] = tokenA;
            path[1] = tokenB;
        } else {
            path = new address[](3);
            path[0] = tokenA;
            path[1] = WRAPPED_NATIVE_TOKEN;
            path[2] = tokenB;
        }

        uint256 balanceBefore = IERC20(tokenB).balanceOf(address(this));
        IPCSRouterLike(PCS_LIKE_ROUTER).swapExactTokensForTokens(
            amount,
            uint256(0),
            path,
            address(this),
            block.timestamp.add(1800)
        );
        return IERC20(tokenB).balanceOf(address(this)).sub(balanceBefore);
    }

    // --------------------------------------------------------------
    // current strategy info in under contract
    // --------------------------------------------------------------

    function _underlyingShares() public view returns (uint256) {
        (uint256 amount,) = IMasterChefLike(MASTER_CHEF_LIKE).userInfo(MASTER_CHEF_LIKE_POOL_ID, address(this));
        return amount.mul(_underlyingPricePreShares()).div(_DECIMAL);
    }

    function _underlyingPricePreShares() public view returns(uint256) {
        uint256 wantLockedTotal = IAutoStrategy(AUTO_STRATX).wantLockedTotal();
        uint256 sharesTotal = IAutoStrategy(AUTO_STRATX).sharesTotal();

        if (sharesTotal == 0) return 0;
        return _DECIMAL.mul(wantLockedTotal).div(sharesTotal);
    }

    // --------------------------------------------------------------
    // User Read Interface (price in staking token)
    // --------------------------------------------------------------

    function totalBalance() public view returns(uint256) {
        return _underlyingShares();
    }

    function balanceOf(address account) public view returns(uint256) {
        if (totalShares == 0) return 0;
        return _underlyingShares().mul(sharesOf(account)).div(totalShares);
    }

    function earnedOf(address account) public view returns (uint256) {
        if (balanceOf(account) >= principalOf(account)) {
            return balanceOf(account).sub(principalOf(account));
        } else {
            return 0;
        }
    }

    function pricePreShare() public view returns(uint256) {
        if (totalShares == 0) return 0;
        return _underlyingShares().div(totalShares);
    }

    // --------------------------------------------------------------
    // User Write Interface
    // --------------------------------------------------------------

    function harvest() external nonEmergency nonReentrant {
        _harvest();
    }

    function deposit(uint256 originTokenAmount) external nonEmergency nonReentrant {
        _harvest();

        uint underlyingShares = _underlyingShares();
        IERC20(STAKING_TOKEN).safeTransferFrom(msg.sender, address(this), originTokenAmount);
        uint256 underContractShares = _depositUnderlying(originTokenAmount);

        // calculate shares
        uint256 shares = 0;
        if (totalShares == 0) {
            shares = underContractShares;
        } else {
            shares = underContractShares.mul(totalShares).div(underlyingShares);
        }

        // add shares
        totalShares = totalShares.add(shares);
        userShares[msg.sender] = userShares[msg.sender].add(shares);
        _addUserShare(msg.sender, shares);

        // add principal
        userPrincipal[msg.sender] = userPrincipal[msg.sender].add(originTokenAmount);

        _depositRewardAddReward(
            msg.sender,
            tokenPriceInBNB(STAKING_TOKEN)
                .mul(originTokenAmount)
                .div(10 ** uint256(IBEP20(STAKING_TOKEN).decimals()))
        );

        emit LogDeposit(msg.sender, originTokenAmount, shares);
    }

    function _withdraw(uint256 principalAmount) private {
        if (principalAmount > userPrincipal[msg.sender]) {
            principalAmount = userPrincipal[msg.sender];
        }

        _harvest();

        if (userPrincipal[msg.sender].sub(principalAmount) < DUST) {
            principalAmount = userPrincipal[msg.sender];
        }

        uint256 amount = Math.min(
            principalAmount,
            userPrincipal[msg.sender]
        );

        uint256 shares = Math.min(
            amount.mul(totalShares).div(_underlyingShares()),
            userShares[msg.sender]
        );

        if (userShares[msg.sender].sub(shares) < DUST) {
            shares = userShares[msg.sender];
        }

        totalShares = totalShares.sub(shares);
        userShares[msg.sender] = userShares[msg.sender].sub(shares);
        userPrincipal[msg.sender] = userPrincipal[msg.sender].sub(principalAmount);
        _removeUserShare(msg.sender, shares);

        // withdraw from under contract
        amount = _withdrawUnderlying(shares);

        IERC20(STAKING_TOKEN).safeTransfer(msg.sender, amount);

        emit LogWithdraw(msg.sender, principalAmount, shares);
    }

    function withdraw(uint256 principalAmount) external nonEmergency nonReentrant {
        _withdraw(principalAmount);
    }

    function withdrawAll() external nonEmergency nonReentrant {
        _withdraw(uint256(~0));
        _getRewards();
    }

    function _getRewards() private {
        uint amount = earnedOf(msg.sender);
        uint256 shares = Math.min(
            amount.mul(totalShares).div(_underlyingShares()),
            userShares[msg.sender]
        );

        if (userPrincipal[msg.sender] == 0) {
            shares = userShares[msg.sender];
        }

        totalShares = totalShares.sub(shares);
        userShares[msg.sender] = userShares[msg.sender].sub(shares);

        amount = _withdrawUnderlying(shares);

        amount = amount.sub(_addProfitReward(msg.sender, amount));

        if (amount > 0) {
            IERC20(STAKING_TOKEN).safeTransfer(msg.sender, amount);
        }

        _getGrowRewards(msg.sender);

        emit LogGetReward(msg.sender, amount, shares);
    }

    function getRewards() external nonEmergency nonReentrant {
        _getRewards();
    }

    // --------------------------------------------------------------
    // Private
    // --------------------------------------------------------------

    function _harvest() private {
        if (_underlyingShares() > 0) {
            _withdrawUnderlying(0);

            uint256 rewardTokenAmount = IERC20(UNDERLYING_REWARD_TOKEN).balanceOf(address(this));
            if (rewardTokenAmount < 1e16) return; // 0.01

            uint256 stakingTokenAmount = _swap(UNDERLYING_REWARD_TOKEN, STAKING_TOKEN, rewardTokenAmount);
            stakingTokenAmount = IERC20(STAKING_TOKEN).balanceOf(address(this));
            if (stakingTokenAmount < 1e16) return; // 0.01

            _depositUnderlying(stakingTokenAmount);

            emit LogHarvest(msg.sender, stakingTokenAmount);
        }
    }

    function _addProfitReward(address userAddress, uint256 amount) private returns (uint256) {
        if (address(growRewarder) != address(0) && amount > DUST) {
            // get 30% earned for profit reward
            uint256 earnedForProfitReward = amount.mul(30).div(100);

            // exchange to wht
            uint256 whtExchanged = _swap(STAKING_TOKEN, WRAPPED_NATIVE_TOKEN, earnedForProfitReward);

            // notify GrowMaster
            approveToken(WRAPPED_NATIVE_TOKEN, address(growRewarder), whtExchanged);
            _profitRewardAddReward(userAddress, address(WRAPPED_NATIVE_TOKEN), whtExchanged);

            return earnedForProfitReward;
        }

        return 0;
    }

    // --------------------------------------------------------------
    // Interactive with under contract
    // --------------------------------------------------------------

    function _depositUnderlying(uint256 amount) private returns (uint256) {
        uint256 currentUnderlyingShares = _underlyingShares();
        approveToken(STAKING_TOKEN, MASTER_CHEF_LIKE, amount);
        IMasterChefLike(MASTER_CHEF_LIKE).deposit(MASTER_CHEF_LIKE_POOL_ID, amount);

        return _underlyingShares().sub(currentUnderlyingShares);
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

        userShares[msg.sender] = 0;
        userPrincipal[msg.sender] = 0;
        _removeUserShare(msg.sender, shares);

        // withdraw from under contract
        uint256 currentBalance = IERC20(STAKING_TOKEN).balanceOf(address(this));
        uint256 amount = currentBalance.mul(shares).div(totalShares);
        totalShares = totalShares.sub(shares);

        IERC20(STAKING_TOKEN).safeTransfer(msg.sender, amount);
    }

    // --------------------------------------------------------------
    // Events
    // --------------------------------------------------------------
    event LogDeposit(address user, uint256 amount, uint256 shares);
    event LogWithdraw(address user, uint256 amount, uint256 shares);
    event LogHarvest(address user, uint256 amount);
    event LogGetReward(address user, uint256 amount, uint256 shares);

}