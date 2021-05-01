// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IGrow.sol";
import "./GrowMinter.sol";

contract GrowRewarder is IGrowRewarder, Ownable, ReentrancyGuard {

    uint256 constant REWARD_DECIMAL = 1e18;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    GrowMinter public immutable growMinter;

    constructor(address _growMinter) public {
        growMinter = GrowMinter(_growMinter);
    }

    modifier onlyStrategy(address strategyAddress) {
        require(growMinter.isStrategyActive(msg.sender), "GrowMaster: caller is not on the strategy");
        require(address(msg.sender) == strategyAddress, "GrowMaster: caller is not current strategy");
        _;
    }

    // --------------------------------------------------------------
    // Block Reward (MasterChef-Like)
    // --------------------------------------------------------------

    function blockRewardUpdateRewards(address strategyAddress) private {
        (uint256 allocPoint, uint256 lastRewardBlock, uint256 accGrowPerShare) = growMinter.getBlockRewardConfig(strategyAddress);

        if (block.number <= lastRewardBlock) {
            return;
        }

        uint256 totalShares = IGrowStrategy(strategyAddress).totalShares();

        if (totalShares == 0 || growMinter.blockRewardTotalAllocPoint() == 0 || growMinter.blockRewardGrowPreBlock() == 0) {
            growMinter.updateBlockRewardLastRewardBlock(strategyAddress);
            return;
        }

        uint256 multiplier = block.number.sub(lastRewardBlock);

        uint256 growReward = multiplier
            .mul(growMinter.blockRewardGrowPreBlock())
            .mul(allocPoint)
            .div(growMinter.blockRewardTotalAllocPoint());

        if (growReward > 0) {
            growMinter.mintForReward(growReward);
        }

        // = accGrowPerShare + (growReward × REWARD_DECIMAL / totalSupply)
        growMinter.updateBlockRewardAccGrowPerShare(strategyAddress, accGrowPerShare.add(
            growReward
                .mul(REWARD_DECIMAL)
                .div(totalShares)
        ));

        growMinter.updateBlockRewardLastRewardBlock(strategyAddress);
    }

    // --------------------------------------------------------------
    // Deposit Reward (Directly set by strategy with timelock)
    // --------------------------------------------------------------

    function depositRewardAddReward(address strategyAddress, address userAddress, uint256 amountInNativeToken) external override onlyStrategy(strategyAddress) {
        if (amountInNativeToken <= 0) return; // nothing happened

        (uint256 multiplier, uint256 membershipMultiplier,) = growMinter.getDepositRewardConfig(strategyAddress);

        if (growMinter.hasMembership(userAddress)) {
            multiplier = membershipMultiplier;
        }
        if (multiplier <= 0) return; // nothing happened

        growMinter.addLockedRewards(strategyAddress, userAddress, amountInNativeToken.mul(multiplier).div(REWARD_DECIMAL));
    }

    // --------------------------------------------------------------
    // Profit Reward (Take some profits and reward as GROW)
    // --------------------------------------------------------------

    function profitRewardAddReward(address strategyAddress, address profitToken, address userAddress, uint256 profitTokenAmount) external override onlyStrategy(strategyAddress) {
        if (profitTokenAmount <= 0) return; // nothing happened
        if (profitToken == address(0)) return; // nothing happened

        IERC20(profitToken).safeTransferFrom(strategyAddress, address(this), profitTokenAmount);

        (uint256 multiplier, uint256 membershipMultiplier) = growMinter.getProfitRewardConfig(strategyAddress);
        if (growMinter.hasMembership(userAddress)) {
            multiplier = membershipMultiplier;
        }

        if (multiplier > 0) {
            uint256 growRewardAmount = profitTokenAmount
                .mul(multiplier)
                .div(REWARD_DECIMAL);

            growMinter.addPendingRewards(strategyAddress, userAddress, growRewardAmount);
        }

        address profitStrategy = growMinter.profitStrategies(profitToken);

        if (profitStrategy != address(0)) {
            IERC20(profitToken).safeApprove(profitStrategy, profitTokenAmount);
            IGrowProfitReceiver(profitStrategy).pump(profitTokenAmount);
        } else {
            // if no profit strategy, dev will receive it
            IERC20(profitToken).safeTransfer(growMinter.growDev(), profitTokenAmount);
        }
    }

    // --------------------------------------------------------------
    // Reward Manage
    // --------------------------------------------------------------

    function updateRewards(address strategyAddress) public {
        blockRewardUpdateRewards(strategyAddress);
    }

    function _getRewards(address strategyAddress, address userAddress) private {
        // 1. settlement current rewards
        settlementRewards(strategyAddress, userAddress);

        // 2. transfer
        growMinter.transferPendingGrow(strategyAddress, userAddress);

        // emit LogGetRewards(strategyAddress, userAddress, rewardPending);
    }

    function getRewards(address strategyAddress, address userAddress) external override onlyStrategy(strategyAddress) {
        _getRewards(strategyAddress, userAddress);
    }

    function updateRewardDebt(address strategyAddress, address userAddress, uint256 sharesUpdateTo) private {
        (,,uint256 accGrowPerShare) = growMinter.getBlockRewardConfig(strategyAddress);

        growMinter.updateBlockRewardUserRewardDebt(strategyAddress, userAddress, sharesUpdateTo.mul(accGrowPerShare).div(REWARD_DECIMAL));
    }

    function settlementRewards(address strategyAddress, address userAddress) private {
        uint256 currentUserShares = IGrowStrategy(strategyAddress).sharesOf(userAddress);

        // 1. update reward data
        updateRewards(strategyAddress);

        (,, uint256 accGrowPerShare) = growMinter.getBlockRewardConfig(strategyAddress);
        uint256 blockRewardDebt = growMinter.getBlockRewardUserInfo(strategyAddress, userAddress);

        // 2. collect all rewards
        uint256 rewardGrows = 0;

        // reward by shares (Block reward & Profit reward)
        if (currentUserShares > 0) {
            // Block reward
            uint256 pendingBlockReward = currentUserShares
                .mul(accGrowPerShare)
                .div(REWARD_DECIMAL)
                .sub(blockRewardDebt);

            growMinter.updateBlockRewardUserRewardDebt(
                strategyAddress, userAddress,
                currentUserShares
                    .mul(accGrowPerShare)
                    .div(REWARD_DECIMAL)
            );

            growMinter.addPendingRewards(strategyAddress, userAddress, pendingBlockReward);
        }

        // deposit reward
        growMinter.unlockLockedRewards(strategyAddress, userAddress, false);

        emit LogSettlementRewards(strategyAddress, userAddress, rewardGrows);
    }

    // --------------------------------------------------------------
    // Share manage
    // --------------------------------------------------------------

    function notifyUserSharesUpdate(address strategyAddress, address userAddress, uint256 sharesUpdateTo, bool isWithdraw) external override onlyStrategy(strategyAddress) {
        // 0. if strategyAddress is EMERGENCY_MODE
        if (IGrowStrategy(strategyAddress).IS_EMERGENCY_MODE()) {
            growMinter.unlockLockedRewards(strategyAddress, userAddress, true);
        }

        // 1. check if need revert deposit reward
        if (isWithdraw) {
            growMinter.checkNeedResetLockedRewards(strategyAddress, userAddress);
        }

        // 2. settlement current rewards
        settlementRewards(strategyAddress, userAddress);

        // 3. reset reward debt base on current shares
        updateRewardDebt(strategyAddress, userAddress, sharesUpdateTo);

        emit LogSharesUpdate(strategyAddress, userAddress, sharesUpdateTo);
    }

    // --------------------------------------------------------------
    // User Write Interface
    // --------------------------------------------------------------

    function getSelfRewards(address strategyAddress) external nonReentrant {
        _getRewards(strategyAddress, msg.sender);
    }

    // --------------------------------------------------------------
    // Events
    // --------------------------------------------------------------
    event LogGrowMint(address to, uint256 amount);
    event LogSharesUpdate(address strategyAddress, address user, uint256 shares);
    event LogSettlementRewards(address strategyAddress, address user, uint256 amount);
    event LogGetRewards(address strategyAddress, address user, uint256 amount);

}
