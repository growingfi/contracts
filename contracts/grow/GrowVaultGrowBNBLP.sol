// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IGrow.sol";

contract GrowVaultGrowBNBLP is ReentrancyGuard, Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 constant _DECIMAL = 1e18;

    /// @dev total balance of this strategy
    uint256 public totalBalance;

    /// @dev user share
    mapping (address => uint256) internal userBalance;

    /// @dev grow rewarder
    IGrowRewarder public growRewarder;

    // --------------------------------------------------------------
    // Address
    // --------------------------------------------------------------

    address public constant LP_TOKEN = 0xef76f95DE76d3cc07e1068F18Af1367375B04aF7;
    address public constant GROW_TOKEN = 0x8CEF274596d334FFa10f8976a920DDC81ba6e29b;
    address public constant WBNB_TOKEN = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    uint256 DUST = 1000;

    constructor(
        address rewarderAddress
    ) public {
        growRewarder = IGrowRewarder(rewarderAddress);
    }

    // --------------------------------------------------------------
    // Misc
    // --------------------------------------------------------------

    function lpPriceInBNB() view public returns(uint256) {
        return IERC20(WBNB_TOKEN)
            .balanceOf(LP_TOKEN).mul(_DECIMAL).mul(2)
            .div(IERC20(LP_TOKEN).totalSupply());
    }

    // --------------------------------------------------------------
    // User Read Interface (amount in staking token)
    // --------------------------------------------------------------

    function totalShares() public view returns(uint256) {
        return totalBalance;
    }

    function sharesOf(address account) public view returns(uint256) {
        return userBalance[account];
    }

    // --------------------------------------------------------------
    // User Write Interface
    // --------------------------------------------------------------

    function deposit(uint256 amount) external nonReentrant {
        IERC20(LP_TOKEN).safeTransferFrom(msg.sender, address(this), amount);

        _notifyUserSharesUpdate(msg.sender, userBalance[msg.sender].add(amount), false);

        // add Balance
        totalBalance = totalBalance.add(amount);
        userBalance[msg.sender] = userBalance[msg.sender].add(amount);

        _depositRewardAddReward(
            msg.sender,
            lpPriceInBNB()
                .mul(amount)
                .div(_DECIMAL)
        );

        emit LogDeposit(msg.sender, amount);
    }

    function _withdraw(uint256 amount) private {
        if (amount > userBalance[msg.sender]) {
            amount = userBalance[msg.sender];
        }

        if (userBalance[msg.sender].sub(amount) < DUST) {
            amount = userBalance[msg.sender];
        }

        require(amount > 0, "GrowVaultGrowBNBLP: amount can not be zero");

        _notifyUserSharesUpdate(msg.sender, userBalance[msg.sender].sub(amount), true);

        totalBalance = totalBalance.sub(amount);
        userBalance[msg.sender] = userBalance[msg.sender].sub(amount);
        IERC20(LP_TOKEN).safeTransfer(msg.sender, amount);

        emit LogWithdraw(msg.sender, amount);
    }

    function withdraw(uint256 principalAmount) external nonReentrant {
        _withdraw(principalAmount);
    }

    function withdrawAll() external nonReentrant {
        _withdraw(uint256(~0));
        _getRewards();
    }

    function _getRewards() private {
        _getGrowRewards(msg.sender);
        emit LogGetReward(msg.sender);
    }

    function getRewards() external nonReentrant {
        _getRewards();
    }

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

    function _notifyUserSharesUpdate(address userAddress, uint256 balance, bool isWithdraw) internal onlyHasRewarder {
        growRewarder.notifyUserSharesUpdate(address(this), userAddress, balance, isWithdraw);
    }

    function _getGrowRewards(address userAddress) internal onlyHasRewarder {
        growRewarder.getRewards(address(this), userAddress);
    }

    // --------------------------------------------------------------
    // Events
    // --------------------------------------------------------------
    event LogDeposit(address user, uint256 amount);
    event LogWithdraw(address user, uint256 amount);
    event LogGetReward(address user);
}
