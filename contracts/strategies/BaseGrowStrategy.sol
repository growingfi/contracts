// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IGrow.sol";

abstract contract BaseGrowStrategy is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 constant _DECIMAL = 1e18;

    /// @dev total shares of this strategy
    uint256 public totalShares;

    /// @dev user share
    mapping (address => uint256) internal userShares;

    /// @dev user principal
    mapping (address => uint256) internal userPrincipal;

    IGrowRewarder public growRewarder;

    // --------------------------------------------------------------
    // Misc
    // --------------------------------------------------------------

    function approveToken(address token, address to, uint256 amount) internal {
        if (IERC20(token).allowance(address(this), to) < amount) {
            IERC20(token).safeApprove(to, 0);
            IERC20(token).safeApprove(to, uint256(~0));
        }
    }

    // --------------------------------------------------------------
    // User Read interface (shares and principal)
    // --------------------------------------------------------------

    function sharesOf(address account) public view returns (uint256) {
        return userShares[account];
    }

    function principalOf(address account) public view returns (uint256) {
        return userPrincipal[account];
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

    function _profitRewardAddReward(address userAddress, address profitToken, uint256 profitTokenAmount) internal onlyHasRewarder {
        growRewarder.profitRewardAddReward(address(this), profitToken, userAddress, profitTokenAmount);
    }

    function _addUserShare(address userAddress, uint256 shares) internal onlyHasRewarder {
        growRewarder.addUserShare(address(this), userAddress, shares);
    }

    function _removeUserShare(address userAddress, uint256 shares) internal onlyHasRewarder {
        growRewarder.removeUserShare(address(this), userAddress, shares);
    }

    function _getGrowRewards(address userAddress) internal onlyHasRewarder {
        growRewarder.getRewards(address(this), userAddress);
    }

    // --------------------------------------------------------------
    // !! Emergency !!
    // --------------------------------------------------------------

    bool public IS_EMERGENCY_MODE = false;

    modifier nonEmergency() {
        require(IS_EMERGENCY_MODE == false, "GrowStrategy: emergency mode.");
        _;
    }

    modifier onlyEmergency() {
        require(IS_EMERGENCY_MODE == true, "GrowStrategy: not emergency mode.");
        _;
    }

}