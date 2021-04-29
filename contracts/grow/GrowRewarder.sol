// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IGrow.sol";
import "./GrowToken.sol";

contract GrowRewarder is IGrowRewarder, Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for GrowToken;

    uint256 constant REWARD_DECIMAL = 1e18;

    // Initialized constants variables
    /// @notice Address of GROW Token Contract
    GrowToken public immutable GROW;

    // State variables
    /// @notice Address of each strategy
    address[] public strategyAddresses;

    /// @notice Info of each strategy
    mapping(address => StrategyInfo) public strategies;

    /// @notice Info of each user
    mapping(address => mapping (address => UserInfo)) public strategyUsers;

    /// @dev init with token address
    constructor(GrowToken contractAddress) public {
        GROW = contractAddress;
        growDev = msg.sender;
    }

    // --------------------------------------------------------------
    // Misc
    // --------------------------------------------------------------

    /// @dev grow developer
    address public growDev;

    /// @dev maybe transfer dev address to governance in future
    function updateDevAddress(address _devAddress) external {
        require(msg.sender == growDev, "dev: ?");
        growDev = _devAddress;
    }

    /// @dev mint with additional 10% grow for dev
    function mint(address to, uint256 amount) private {
        GROW.mint(to, amount);
        uint256 amountForDev = amount.div(10); // 10%
        GROW.mint(growDev, amountForDev);

        LogGrowMint(to, amount);
    }

    function safeGrowTransfer(address to, uint256 amount) private {
        if (amount == 0) return;

        uint256 balance = GROW.balanceOf(address(this));
        if (amount <= balance) {
            GROW.safeTransfer(to, amount);
        } else {
            GROW.safeTransfer(to, balance);
        }
    }

    address public membershipController;

    /// @dev maybe transfer dev address to governance in future
    function updateMembershipController(address _membershipController) external onlyOwner {
        membershipController = _membershipController;
    }

    function hasMembership(address userAddress) public view returns (bool) {
        if (address(0) == membershipController) return false;
        return IGrowMembershipController(membershipController).hasMembership(userAddress);
    }

    // --------------------------------------------------------------
    // Strategy Manage
    // --------------------------------------------------------------

    modifier onlyStrategy(address strategyAddress) {
        require(address(strategies[msg.sender].token) != address(0), "GrowMaster: caller is not on the strategy");
        require(address(msg.sender) == strategyAddress, "GrowMaster: caller is not current strategy");
        _;
    }

    function addStrategy(
        address strategyAddress,
        address tokenAddress,
        uint256 blockRewardAllocPoint,
        uint256 depositRewardMultiplier,
        uint256 depositRewardMembershipMultiplier,
        uint256 depositRewardLockedTime,
        uint256 profitRewardMultiplier,
        uint256 profitRewardMembershipMultiplier
    ) external onlyOwner {
        require(address(strategies[strategyAddress].token) == address(0), "GrowMaster: strategy is already set");

        uint256 lastRewardBlock = block.number > blockRewardStartBlock ? block.number : blockRewardStartBlock;
        blockRewardTotalAllocPoint = blockRewardTotalAllocPoint.add(blockRewardAllocPoint);

        StrategyInfo storage strategy = strategies[strategyAddress];
        strategy.token = IERC20(tokenAddress);

        strategy.blockRewardLastRewardBlock = lastRewardBlock;
        strategy.blockRewardAllocPoint = blockRewardAllocPoint;

        strategy.depositRewardMultiplier = depositRewardMultiplier;
        strategy.depositRewardMembershipMultiplier = depositRewardMembershipMultiplier;
        strategy.depositRewardLockedTime = depositRewardLockedTime;

        strategy.profitRewardMultiplier = profitRewardMultiplier;
        strategy.profitRewardMembershipMultiplier = profitRewardMembershipMultiplier;

        strategyAddresses.push(strategyAddress);
    }

    function updateStrategy(
        address strategyAddress,
        uint256 blockRewardAllocPoint,
        uint256 depositRewardMultiplier,
        uint256 depositRewardMembershipMultiplier,
        uint256 depositRewardLockedTime,
        uint256 profitRewardMultiplier,
        uint256 profitRewardMembershipMultiplier
    ) external onlyOwner {
        require(address(strategies[strategyAddress].token) != address(0), "GrowMaster: strategy not exist");

        StrategyInfo storage strategy = strategies[strategyAddress];
        blockRewardTotalAllocPoint = blockRewardTotalAllocPoint.sub(strategy.blockRewardAllocPoint).add(blockRewardAllocPoint);

        strategy.blockRewardAllocPoint = blockRewardAllocPoint;

        strategy.depositRewardMultiplier = depositRewardMultiplier;
        strategy.depositRewardMembershipMultiplier = depositRewardMembershipMultiplier;
        strategy.depositRewardLockedTime = depositRewardLockedTime;

        strategy.profitRewardMultiplier = profitRewardMultiplier;
        strategy.profitRewardMembershipMultiplier = profitRewardMembershipMultiplier;
    }

    function strategiesLength() public view returns(uint256) {
        return strategyAddresses.length;
    }

    // --------------------------------------------------------------
    // Block Reward (MasterChef-Like)
    // --------------------------------------------------------------

    /// @notice reward start block
    uint256 public blockRewardStartBlock = 0;

    /// @notice grow reward pre block
    uint256 public blockRewardGrowPreBlock = 0;

    /// @notice total alloc point of all vaults
    uint256 public blockRewardTotalAllocPoint = 0;

    function blockRewardUpdateGrowPreBlock(uint256 amount) external onlyOwner {
        blockRewardGrowPreBlock = amount;
    }

    function blockRewardGetMultiplier(uint256 from, uint256 to) public pure returns (uint256) {
        return to.sub(from);
    }

    function blockRewardUpdateRewards(address strategyAddress) private {
        StrategyInfo storage strategy = strategies[strategyAddress];

        if (block.number <= strategy.blockRewardLastRewardBlock) {
            return;
        }

        if (strategy.totalSupply == 0 || blockRewardTotalAllocPoint == 0 || blockRewardGrowPreBlock == 0) {
            strategy.blockRewardLastRewardBlock = block.number;
            return;
        }

        uint256 multiplier = blockRewardGetMultiplier(strategy.blockRewardLastRewardBlock, block.number);

        uint256 growReward = multiplier.mul(blockRewardGrowPreBlock).mul(strategy.blockRewardAllocPoint).div(blockRewardTotalAllocPoint);

        if (growReward > 0) {
            mint(address(this), growReward);
        }

        // = accGrowPerShare + (growReward × REWARD_DECIMAL / totalSupply)
        strategy.blockRewardAccGrowPerShare = strategy.blockRewardAccGrowPerShare.add(growReward.mul(REWARD_DECIMAL).div(strategy.totalSupply));

        strategy.blockRewardLastRewardBlock = block.number;
    }

    function getPendingBlockReward(address strategyAddress, address userAddress) public view returns (uint256) {
        StrategyInfo storage strategy = strategies[strategyAddress];
        UserInfo storage user = strategyUsers[strategyAddress][userAddress];
        uint256 currentUserShares = IGrowStrategy(strategyAddress).sharesOf(userAddress);

        if (currentUserShares > 0) {
            uint256 tokenSupply = strategy.totalSupply;
            uint256 multiplier = blockRewardGetMultiplier(strategy.blockRewardLastRewardBlock, block.number);

            uint256 growReward = multiplier
                .mul(blockRewardGrowPreBlock)
                .mul(strategy.blockRewardAllocPoint)
                .div(blockRewardTotalAllocPoint);

            // = accGrowPerShare + (growReward × REWARD_DECIMAL / tokenSupply)
            uint256 accGrowPerShare = strategy.blockRewardAccGrowPerShare.add(growReward.mul(REWARD_DECIMAL).div(tokenSupply));

            uint256 pendingBlockReward = currentUserShares.mul(accGrowPerShare).div(REWARD_DECIMAL).sub(user.blockRewardDebt);

            return pendingBlockReward;
        }

        return 0;
    }

    // --------------------------------------------------------------
    // Deposit Reward (Directly set by strategy with timelock)
    // --------------------------------------------------------------

    function depositRewardAddReward(address strategyAddress, address userAddress, uint256 amountInNativeToken) external override onlyStrategy(strategyAddress) {
        if (amountInNativeToken <= 0) return; // nothing happened

        StrategyInfo storage strategy = strategies[strategyAddress];

        uint256 multiplier = strategy.depositRewardMultiplier;
        if (hasMembership(userAddress)) {
            multiplier = strategy.depositRewardMembershipMultiplier;
        }
        if (multiplier <= 0) return; // nothing happened

        UserInfo storage user = strategyUsers[strategyAddress][userAddress];
        user.depositRewardLocked = user.depositRewardLocked.add(
            amountInNativeToken.mul(multiplier).div(REWARD_DECIMAL)
        );
        user.depositRewardUnlockedAt = block.timestamp + strategy.depositRewardLockedTime;
    }

    function getPendingDepositReward(address strategyAddress, address userAddress) public view returns (uint256 _depositRewardLocked, uint256 _depositRewardUnlockedAt) {
        UserInfo storage user = strategyUsers[strategyAddress][userAddress];

        return (user.depositRewardLocked, user.depositRewardUnlockedAt);
    }

    // --------------------------------------------------------------
    // Profit Reward (Take some profits and reward as GROW)
    // --------------------------------------------------------------

    /// @notice Info of each strategy
    mapping(address => address) public profitStrategies;

    function setProfitStrategy(address profitToken, address strategyAddress) external onlyOwner {
        profitStrategies[profitToken] = strategyAddress;
    }

    function profitRewardAddReward(address strategyAddress, address profitToken, address userAddress, uint256 profitTokenAmount) external override onlyStrategy(strategyAddress) {
        if (profitTokenAmount <= 0) return; // nothing happened
        if (profitToken == address(0)) return; // nothing happened

        IERC20(profitToken).safeTransferFrom(strategyAddress, address(this), profitTokenAmount);

        StrategyInfo storage strategy = strategies[strategyAddress];
        UserInfo storage user = strategyUsers[strategyAddress][userAddress];

        uint256 multiplier = strategy.profitRewardMultiplier;
        if (hasMembership(userAddress)) {
            multiplier = strategy.profitRewardMembershipMultiplier;
        }

        if (multiplier > 0) {
            uint256 growRewardAmount = profitTokenAmount
                .mul(multiplier)
                .div(REWARD_DECIMAL);

            mint(address(this), growRewardAmount);
            user.pendingRewards = user.pendingRewards.add(growRewardAmount);
        }

        address profitStrategy = profitStrategies[profitToken];

        if (profitStrategy != address(0)) {
            IERC20(profitToken).safeApprove(profitStrategy, profitTokenAmount);
            IGrowProfitReceiver(profitStrategy).pump(profitTokenAmount);
        } else {
            // if no profit strategy, dev will receive it
            IERC20(profitToken).safeTransfer(growDev, profitTokenAmount);
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

        // 2. reset pending rewards
        UserInfo storage user = strategyUsers[strategyAddress][userAddress];
        uint256 rewardPending = user.pendingRewards;
        user.pendingRewards = 0;

        // 3. transfer
        safeGrowTransfer(userAddress, rewardPending);

        emit LogGetRewards(strategyAddress, userAddress, rewardPending);
    }

    function getRewards(address strategyAddress, address userAddress) external override onlyStrategy(strategyAddress) {
        _getRewards(strategyAddress, userAddress);
    }

    function updateRewardDebt(address strategyAddress, address userAddress, uint256 sharesUpdateTo) private {
        StrategyInfo storage strategy = strategies[strategyAddress];
        UserInfo storage user = strategyUsers[strategyAddress][userAddress];

        user.blockRewardDebt = sharesUpdateTo.mul(strategy.blockRewardAccGrowPerShare).div(REWARD_DECIMAL);
    }

    function settlementRewards(address strategyAddress, address userAddress) private {
        StrategyInfo storage strategy = strategies[strategyAddress];
        UserInfo storage user = strategyUsers[strategyAddress][userAddress];
        uint256 currentUserShares = IGrowStrategy(strategyAddress).sharesOf(userAddress);

        // 1. update reward data
        updateRewards(strategyAddress);

        // 2. collect all rewards
        uint256 rewardGrows = 0;

        // reward by shares (Block reward & Profit reward)
        if (currentUserShares > 0) {
            // Block reward
            uint256 pendingBlockReward = currentUserShares
                .mul(strategy.blockRewardAccGrowPerShare)
                .div(REWARD_DECIMAL)
                .sub(user.blockRewardDebt);
            user.blockRewardDebt = currentUserShares
                .mul(strategy.blockRewardAccGrowPerShare)
                .div(REWARD_DECIMAL);
            rewardGrows = rewardGrows.add(pendingBlockReward);
        }

        // deposit reward
        if (user.depositRewardLocked > 0 && user.depositRewardUnlockedAt < block.timestamp) {
            mint(address(this), user.depositRewardLocked);
            rewardGrows = rewardGrows.add(user.depositRewardLocked);
            user.depositRewardLocked = 0;
        }

        // 3. save pending rewards
        if (rewardGrows > 0) {
            user.pendingRewards = user.pendingRewards.add(rewardGrows);
        }

        emit LogSettlementRewards(strategyAddress, userAddress, rewardGrows);
    }

    // --------------------------------------------------------------
    // Share manage
    // --------------------------------------------------------------

    function notifyUserSharesUpdate(address strategyAddress, address userAddress, uint256 sharesUpdateTo, bool isWithdraw) external override onlyStrategy(strategyAddress) {
        UserInfo storage user = strategyUsers[strategyAddress][userAddress];

        // 1. check if need revert deposit reward
        if (isWithdraw && user.depositRewardLocked > 0 && user.depositRewardUnlockedAt > block.timestamp) {
            user.depositRewardLocked = 0;
        }

        // 1. settlement current rewards
        settlementRewards(strategyAddress, userAddress);

        // 2. reset reward debt base on current shares
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
    // For futrue update
    // --------------------------------------------------------------
    function transferGrowOwnership(address _newOwnerAddress) external onlyOwner {
        GROW.transferOwnership(_newOwnerAddress);
    }

    // --------------------------------------------------------------
    // Events
    // --------------------------------------------------------------
    event LogGrowMint(address to, uint256 amount);
    event LogSharesUpdate(address strategyAddress, address user, uint256 shares);
    event LogSettlementRewards(address strategyAddress, address user, uint256 amount);
    event LogGetRewards(address strategyAddress, address user, uint256 amount);

}
