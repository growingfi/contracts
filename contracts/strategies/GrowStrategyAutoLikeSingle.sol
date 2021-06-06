// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IGrow.sol";
import "./GrowStrategyAutoLike.sol";
import "../utils/SwapUtils.sol";

contract GrowStrategyAutoLikeSingle is GrowStrategyAutoLike {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    constructor(
        address _rewarderAddress,
        address _SWAP_UTILS,
        address _MASTER_CHEF_LIKE,
        uint256 _MASTER_CHEF_LIKE_POOL_ID,
        address _UNDERLYING_REWARD_TOKEN,
        address _AUTO_STRATX,
        address _STAKING_TOKEN
    ) public GrowStrategyAutoLike(
        _rewarderAddress,
        _SWAP_UTILS,
        _MASTER_CHEF_LIKE,
        _MASTER_CHEF_LIKE_POOL_ID,
        _UNDERLYING_REWARD_TOKEN,
        _AUTO_STRATX,
        _STAKING_TOKEN
    ) {}

    // --------------------------------------------------------------
    // User Write Interface
    // --------------------------------------------------------------

    function deposit(uint256 wantTokenAmount) external override nonEmergency nonReentrant {
        _harvest();
        _deposit(wantTokenAmount);
    }

    function withdraw(uint256 principalAmount) external override nonEmergency nonReentrant {
        _harvest();
        _withdraw(principalAmount);
    }

    function withdrawAll() external override nonEmergency nonReentrant {
        _harvest();
        _withdraw(uint256(~0));
        _getRewards();
    }

    function getRewards() external override nonEmergency nonReentrant {
        _harvest();
        _getRewards();
    }

}
