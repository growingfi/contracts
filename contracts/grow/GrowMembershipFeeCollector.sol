// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IGrowStrategyProfit {
    function harvest() external;
}

contract GrowMembershipFeeCollector is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    function harvest(address strategyAddress) external onlyOwner nonReentrant {
        IGrowStrategyProfit(strategyAddress).harvest();
    }

    function transferToken(address token, uint256 amount) external onlyOwner nonReentrant {
        IERC20(token).safeTransfer(msg.sender, amount);
    }
}
