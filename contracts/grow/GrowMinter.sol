// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IGrow.sol";
import "./GrowRewarder.sol";
import "./GrowToken.sol";

contract GrowMinter is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for GrowToken;

    struct UserInfo {
        // block reward
        uint256 blockRewardDebt;

        // deposit reward
        uint256 lockedRewards;
        uint256 lockedRewardsUnlockedAt;

        // pending
        uint256 pendingRewards;
    }

    struct StrategyInfo {
        uint256 id;
        bool isActive;
        uint256 lockedRewardLockedTime;

        // block reward
        uint256 blockRewardAllocPoint;
        uint256 blockRewardLastRewardBlock;
        uint256 blockRewardAccGrowPerShare;

        // deposit reward
        uint256 depositRewardMultiplier;
        uint256 depositRewardMembershipMultiplier;

        // profit reward
        uint256 profitRewardMultiplier;
        uint256 profitRewardMembershipMultiplier;
    }

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

        // LogGrowMint(to, amount);
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
    // Rewarder
    // --------------------------------------------------------------

    /// @dev grow developer
    address public growRewarder;

    /// @dev maybe transfer dev address to governance in future
    function updateRewarderAddress(address _growRewarder) external onlyOwner {
        growRewarder = _growRewarder;
    }

    modifier onlyRewarder() {
        require(msg.sender == growRewarder, "GrowMaster: caller is not on the strategy");
        _;
    }

    function mintForReward(uint256 amount) external onlyRewarder {
        mint(address(this), amount);
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

    // --------------------------------------------------------------
    // Strategy Manage
    // --------------------------------------------------------------

    function addStrategy(
        address strategyAddress,
        bool isActive,
        uint256 lockedRewardLockedTime,
        uint256 blockRewardAllocPoint,
        uint256 depositRewardMultiplier,
        uint256 depositRewardMembershipMultiplier,
        uint256 profitRewardMultiplier,
        uint256 profitRewardMembershipMultiplier
    ) external onlyOwner {
        require(strategies[strategyAddress].id == 0, "GrowMaster: strategy is already set");

        uint256 lastRewardBlock = block.number > blockRewardStartBlock ? block.number : blockRewardStartBlock;
        blockRewardTotalAllocPoint = blockRewardTotalAllocPoint.add(blockRewardAllocPoint);

        StrategyInfo storage strategy = strategies[strategyAddress];

        strategy.isActive = isActive;
        strategy.lockedRewardLockedTime = lockedRewardLockedTime;

        strategy.blockRewardLastRewardBlock = lastRewardBlock;
        strategy.blockRewardAllocPoint = blockRewardAllocPoint;

        strategy.depositRewardMultiplier = depositRewardMultiplier;
        strategy.depositRewardMembershipMultiplier = depositRewardMembershipMultiplier;

        strategy.profitRewardMultiplier = profitRewardMultiplier;
        strategy.profitRewardMembershipMultiplier = profitRewardMembershipMultiplier;

        strategyAddresses.push(strategyAddress);

        strategy.id = strategyAddresses.length;
    }

    function updateStrategy(
        address strategyAddress,
        bool isActive,
        uint256 lockedRewardLockedTime,
        uint256 blockRewardAllocPoint,
        uint256 depositRewardMultiplier,
        uint256 depositRewardMembershipMultiplier,
        uint256 profitRewardMultiplier,
        uint256 profitRewardMembershipMultiplier
    ) external onlyOwner {
        require(strategies[strategyAddress].id != 0, "GrowMaster: strategy is already set");

        StrategyInfo storage strategy = strategies[strategyAddress];

        strategy.isActive = isActive;
        strategy.lockedRewardLockedTime = lockedRewardLockedTime;

        blockRewardTotalAllocPoint = blockRewardTotalAllocPoint.sub(strategy.blockRewardAllocPoint).add(blockRewardAllocPoint);

        strategy.blockRewardAllocPoint = blockRewardAllocPoint;

        strategy.depositRewardMultiplier = depositRewardMultiplier;
        strategy.depositRewardMembershipMultiplier = depositRewardMembershipMultiplier;

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

    function blockRewardUpdateStartBlock(uint256 blockNumber) external onlyOwner {
        blockRewardStartBlock = blockNumber;
    }

    // --------------------------------------------------------------
    // Profit Reward (Take some profits and reward as GROW)
    // --------------------------------------------------------------

    /// @notice Info of each strategy
    mapping(address => address) public profitStrategies;

    function setProfitStrategy(address profitToken, address strategyAddress) external onlyOwner {
        profitStrategies[profitToken] = strategyAddress;
    }

    // --------------------------------------------------------------
    // For futrue update
    // --------------------------------------------------------------
    function transferGrowOwnership(address _newOwnerAddress) external onlyOwner {
        GROW.transferOwnership(_newOwnerAddress);
    }

    // --------------------------------------------------------------
    // Strategy Read Interface
    // --------------------------------------------------------------

    function isStrategyActive(address strategyAddress) external view returns (bool) {
        return strategies[strategyAddress].isActive;
    }

    function getBlockRewardConfig(address strategyAddress) external view returns (
        uint256 allocPoint,
        uint256 lastRewardBlock,
        uint256 accGrowPerShare
    ) {
        allocPoint = strategies[strategyAddress].blockRewardAllocPoint;
        lastRewardBlock = strategies[strategyAddress].blockRewardLastRewardBlock;
        accGrowPerShare = strategies[strategyAddress].blockRewardAccGrowPerShare;
    }

    function getDepositRewardConfig(address strategyAddress) external view returns (
        uint256 multiplier,
        uint256 membershipMultiplier,
        uint256 lockedTime
    ) {
        multiplier = strategies[strategyAddress].depositRewardMultiplier;
        membershipMultiplier = strategies[strategyAddress].depositRewardMembershipMultiplier;
        lockedTime = strategies[strategyAddress].lockedRewardLockedTime;
    }

    function getProfitRewardConfig(address strategyAddress) external view returns (
        uint256 multiplier,
        uint256 membershipMultiplier
    ) {
        multiplier = strategies[strategyAddress].profitRewardMultiplier;
        membershipMultiplier = strategies[strategyAddress].profitRewardMembershipMultiplier;
    }

    // --------------------------------------------------------------
    // Strategy Write Interface
    // --------------------------------------------------------------

    function updateBlockRewardLastRewardBlock(address strategyAddress) external onlyRewarder {
        strategies[strategyAddress].blockRewardLastRewardBlock = block.number;
    }

    function updateBlockRewardAccGrowPerShare(address strategyAddress, uint256 accGrowPerShare) external onlyRewarder {
        strategies[strategyAddress].blockRewardAccGrowPerShare = accGrowPerShare;
    }

    // --------------------------------------------------------------
    // Strategy User Read Interface
    // --------------------------------------------------------------

    function getBlockRewardUserInfo(address strategyAddress, address userAddress) public view returns (uint256 blockRewardDebt) {
        blockRewardDebt = strategyUsers[strategyAddress][userAddress].blockRewardDebt;
    }

    function getLockedRewards(address strategyAddress, address userAddress) public view returns (uint256 lockedRewards, uint256 lockedRewardsUnlockedAt) {
        lockedRewards = strategyUsers[strategyAddress][userAddress].lockedRewards;
        lockedRewardsUnlockedAt = strategyUsers[strategyAddress][userAddress].lockedRewardsUnlockedAt;
    }

    function getPendingRewards(address strategyAddress, address userAddress) public view returns (uint256 pendingRewards) {
        pendingRewards = strategyUsers[strategyAddress][userAddress].pendingRewards;
    }

    // --------------------------------------------------------------
    // Strategy User Write Interface
    // --------------------------------------------------------------

    function updateBlockRewardUserRewardDebt(address strategyAddress, address userAddress, uint256 blockRewardDebt) external onlyRewarder {
        UserInfo storage user = strategyUsers[strategyAddress][userAddress];
        user.blockRewardDebt = blockRewardDebt;
    }

    function addLockedRewards(address strategyAddress, address userAddress, uint256 amount) external onlyRewarder {
        UserInfo storage user = strategyUsers[strategyAddress][userAddress];
        user.lockedRewards = user.lockedRewards.add(amount);
        user.lockedRewardsUnlockedAt = block.timestamp + strategies[strategyAddress].lockedRewardLockedTime;
    }

    function checkNeedResetLockedRewards(address strategyAddress, address userAddress) external onlyRewarder {
        UserInfo storage user = strategyUsers[strategyAddress][userAddress];
        if (user.lockedRewards > 0 && user.lockedRewardsUnlockedAt > block.timestamp) {
            user.lockedRewards = 0;
            user.lockedRewardsUnlockedAt = 0;
        }
    }

    function unlockLockedRewards(address strategyAddress, address userAddress, bool unlockInEmegency ) external onlyRewarder {
        UserInfo storage user = strategyUsers[strategyAddress][userAddress];
        if (user.lockedRewards > 0 && (user.lockedRewardsUnlockedAt < block.timestamp || unlockInEmegency)) {
            uint256 amount = user.lockedRewards;
            user.pendingRewards = user.pendingRewards.add(user.lockedRewards);
            user.lockedRewards = 0;
            user.lockedRewardsUnlockedAt = 0;
            mint(address(this), amount);
        }
    }

    function addPendingRewards(address strategyAddress, address userAddress, uint256 amount) external onlyRewarder {
        UserInfo storage user = strategyUsers[strategyAddress][userAddress];
        user.pendingRewards = user.pendingRewards.add(amount);
    }

    function transferPendingGrow(address strategyAddress, address userAddress) external onlyRewarder {
        // 1. reset pending rewards
        UserInfo storage user = strategyUsers[strategyAddress][userAddress];
        uint256 rewardPending = user.pendingRewards;
        user.pendingRewards = 0;

        // 2. transfer
        safeGrowTransfer(userAddress, rewardPending);
    }

}
