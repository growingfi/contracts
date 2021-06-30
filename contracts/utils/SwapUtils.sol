// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IPancakeFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IPCSRouterLike {
    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata, address to, uint256 deadline) external;
}

interface IPancakePair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function totalSupply() external view returns (uint);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IAggregatorV3Interface {
    function latestRoundData()
    external
    view
    returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

interface IMarketOracle {
    function getData(address tokenAddress) external view returns (uint256);
}


contract SwapUtils is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 constant _DECIMAL = 1e18;
    address public immutable WRAPPED_NATIVE_TOKEN;
    address public MARKET_ORACLE;

    mapping(address => address) private tokenFeeds;
    mapping(address => bool) private marketOracleTokenList;

    constructor (
        address _FACTORY, // pancake: 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73, ape: 0x0841BD0B734E4F5853f0dD8d7Ea041c241fb0Da6
        address _ROUTER, // pancake: 0x10ED43C718714eb63d5aA57B78B54704E256024E, ape: 0xC0788A3aD43d79aa53B09c2EaCc313A787d1d607
        address _WRAPPED_NATIVE_TOKEN // 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c
    ) public {
        FACTORY = _FACTORY;
        PCS_LIKE_ROUTER = _ROUTER;
        WRAPPED_NATIVE_TOKEN = _WRAPPED_NATIVE_TOKEN;
    }

    // --------------------------------------------------------------
    // Misc
    // --------------------------------------------------------------

    address public immutable FACTORY;
    uint256 public safeSwapThreshold = 20;

    // ****
    // https://docs.chain.link/docs/binance-smart-chain-addresses/
    // Pair	        Dec	Proxy
    // BUSD / BNB	18	0x87Ea38c9F24264Ec1Fff41B04ec94a97Caf99941
    // BTC / BNB	18	0x116EeB23384451C78ed366D4f67D5AD44eE771A0
    // ETH / BNB	18	0x63D407F32Aa72E63C7209ce1c2F5dA40b3AaE726
    // CAKE / BNB	18	0xcB23da9EA243f53194CBc2380A6d4d9bC046161f
    // USDT / BNB	18	0xD5c40f5144848Bd4EF08a9605d860e727b991513
    // NOTICE: ONLY 18 DEC Pair ALLOW TO SET
    // ****
    function setTokenFeed(address asset, address feed) public onlyOwner {
        tokenFeeds[asset] = feed;
    }

    function setMarketOracleToken(address asset, bool useMarketOracle) public onlyOwner {
        marketOracleTokenList[asset] = useMarketOracle;
    }

    function updateSafeSwapThreshold(uint256 threshold) external onlyOwner {
        safeSwapThreshold = threshold;
    }

    function setMarketOracle(address _MARKET_ORACLE) external onlyOwner {
        MARKET_ORACLE = _MARKET_ORACLE;
    }

    function _getTokenPriceInBNBFromPancakePair(address _token, uint256 amount) view public returns(uint256) {
        address pair = IPancakeFactory(FACTORY).getPair(_token, address(WRAPPED_NATIVE_TOKEN));
        if (pair == address(0)) return 0;
        if (IPancakePair(pair).totalSupply() == 0) return 0;

        (uint reserve0, uint reserve1, ) = IPancakePair(pair).getReserves();

        if (IPancakePair(pair).token0() == address(WRAPPED_NATIVE_TOKEN)) {
            return amount.mul(_DECIMAL).mul(reserve0).div(reserve1).div(_DECIMAL);
        } else {
            return amount.mul(_DECIMAL).mul(reserve1).div(reserve0).div(_DECIMAL);
        }
    }

    function _oracleValueOf(address asset, uint amount) private view returns (uint256 valueInBNB) {
        (, int price, , ,) = IAggregatorV3Interface(tokenFeeds[asset]).latestRoundData();
        valueInBNB = uint256(price).mul(amount);
    }

    function _marketOracleValueOf(address asset, uint amount) private view returns (uint256 valueInBNB) {
        uint256 price = IMarketOracle(MARKET_ORACLE).getData(asset);
        valueInBNB = price.mul(amount);
    }

    function tokenPriceInBNB(address asset, uint amount) view external returns (uint256) {
        if (asset == address(0) || asset == WRAPPED_NATIVE_TOKEN) {
            return amount;
        } else if (marketOracleTokenList[asset]) {
            uint256 pancakePrice = _getTokenPriceInBNBFromPancakePair(asset, amount);
            return Math.min(_marketOracleValueOf(asset, amount), pancakePrice);
        } else {
            return _getTokenPriceInBNBFromPancakePair(asset, amount);
        }
    }

    function checkNeedSwap(address _token, uint256 amount) view external returns (bool) {
        if (_token == WRAPPED_NATIVE_TOKEN) return false;

        address pair = IPancakeFactory(FACTORY).getPair(_token, address(WRAPPED_NATIVE_TOKEN));
        if (pair == address(0)) return false;
        if (IPancakePair(pair).totalSupply() == 0) return false;

        (uint reserve0, uint reserve1, ) = IPancakePair(pair).getReserves();

        if (IPancakePair(pair).token0() == _token) {
            return reserve0 > amount.mul(safeSwapThreshold);
        } else {
            return reserve1 > amount.mul(safeSwapThreshold);
        }
    }

    // --------------------------------------------------------------
    // Token swap
    // --------------------------------------------------------------

    address public immutable PCS_LIKE_ROUTER;

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
