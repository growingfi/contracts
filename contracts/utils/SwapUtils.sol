// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IGrow.sol";

interface IPancakeFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IPCSRouterLike {
    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata, address to, uint256 deadline) external;
}

contract SwapUtils {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 constant _DECIMAL = 1e18;
    address public constant WRAPPED_NATIVE_TOKEN = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    // --------------------------------------------------------------
    // Misc
    // --------------------------------------------------------------

    IPancakeFactory private constant factory = IPancakeFactory(0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73);

    function tokenPriceInBNB(address _token, uint256 amount) view external returns(uint256) {
        address pair = factory.getPair(_token, address(WRAPPED_NATIVE_TOKEN));

        return IERC20(WRAPPED_NATIVE_TOKEN).balanceOf(pair)
            .mul(amount).mul(_DECIMAL)
            .div(IERC20(_token).balanceOf(pair)).div(_DECIMAL);
    }

    // --------------------------------------------------------------
    // Token swap
    // --------------------------------------------------------------

    address public constant PCS_LIKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    function swap(address tokenA, address tokenB, uint256 amount) external returns (uint256) {
        if (amount <= 0) {
            return 0;
        }

        IERC20(tokenA).safeTransferFrom(msg.sender, address(this), amount);
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
        uint256 exchangeAmount = IERC20(tokenB).balanceOf(address(this)).sub(balanceBefore);
        IERC20(tokenB).safeApprove(msg.sender, 0);
        IERC20(tokenB).safeApprove(msg.sender, exchangeAmount);

        return exchangeAmount;
    }
}
