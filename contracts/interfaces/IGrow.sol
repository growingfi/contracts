// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IGrowRewarder {

    struct UserInfo {
        // token amount the user has provided.
        uint256 shares;

        // block reward
        uint256 blockRewardDebt;

        // deposit reward
        uint256 depositRewardLocked;
        uint256 depositRewardUnlockedAt;

        // pending
        uint256 pendingRewards;
    }

    struct StrategyInfo {
        IERC20 token;
        uint256 totalSupply;

        // block reward
        uint256 blockRewardAllocPoint;
        uint256 blockRewardLastRewardBlock;
        uint256 blockRewardAccGrowPerShare;

        // deposit reward
        uint256 depositRewardMultiplier;
        uint256 depositRewardMembershipMultiplier;
        uint256 depositRewardLockedTime;

        // profit reward
        uint256 profitRewardMultiplier;
        uint256 profitRewardMembershipMultiplier;
    }

    function depositRewardAddReward(address strategyAddress, address userAddress, uint256 amountInNativeToken) external;
    function profitRewardAddReward(address strategyAddress, address profitToken, address userAddress, uint256 profitTokenAmount) external;
    function addUserShare(address strategyAddress, address userAddress, uint256 shares) external;
    function removeUserShare(address strategyAddress, address userAddress, uint256 shares) external;
    function getRewards(address strategyAddress, address userAddress) external;
}

interface IGrowProfitReceiver {
    function pump(uint256 amount) external;
}

interface IGrowMembershipController {
    function hasMembership(address userAddress) external view returns (bool);
}