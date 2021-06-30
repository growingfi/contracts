// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import '../lib/FixedPoint.sol';
import "@openzeppelin/contracts/access/Ownable.sol";

import "../interfaces/IPancakePair.sol";


// library with helper methods for oracles that are concerned with computing average prices
library UniswapV2OracleLibrary {
    using FixedPoint for *;

    // helper function that returns the current block timestamp within the range of uint32, i.e. [0, 2**32 - 1]
    function currentBlockTimestamp() internal view returns (uint32) {
        return uint32(block.timestamp % 2 ** 32);
    }

    // produces the cumulative price using counterfactuals to save gas and avoid a call to sync.
    function currentCumulativePrices(
        address pair
    ) internal view returns (uint price0Cumulative, uint price1Cumulative, uint32 blockTimestamp) {
        blockTimestamp = currentBlockTimestamp();
        price0Cumulative = IPancakePair(pair).price0CumulativeLast();
        price1Cumulative = IPancakePair(pair).price1CumulativeLast();

        // if time has elapsed since the last update on the pair, mock the accumulated price values
        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) = IPancakePair(pair).getReserves();
        if (blockTimestampLast != blockTimestamp) {
            // subtraction overflow is desired
            uint32 timeElapsed = blockTimestamp - blockTimestampLast;
            // addition overflow is desired
            // counterfactual
            price0Cumulative += uint(FixedPoint.fraction(reserve1, reserve0)._x) * timeElapsed;
            // counterfactual
            price1Cumulative += uint(FixedPoint.fraction(reserve0, reserve1)._x) * timeElapsed;
        }
    }
}


contract MarketOracle is Ownable {
    using FixedPoint for *;

    struct TokenPrice {
      uint    tokenNativePrice0CumulativeLast;
      uint    tokenNativePrice1CumulativeLast;
      uint    tokenValueInNativeAverage;
      uint32  tokenNativeBlockTimestampLast;
    }

    address public immutable WRAPPED_NATIVE_TOKEN;

    mapping(address => TokenPrice) public priceList;
    mapping(address => IPancakePair) public tokenLP;


    address public controller;

    modifier onlyControllerOrOwner {
        require(msg.sender == controller || msg.sender == owner());
        _;
    }

    constructor(
        address _controller,
        address _WRAPPED_NATIVE_TOKEN // 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c
    ) public {
        controller = _controller;
        WRAPPED_NATIVE_TOKEN = _WRAPPED_NATIVE_TOKEN;
    }

    function _setTokenLP(address _token, address _tokenLP) private {
        tokenLP[_token] = IPancakePair(_tokenLP);
        require(tokenLP[_token].token0() == WRAPPED_NATIVE_TOKEN || tokenLP[_token].token1() == WRAPPED_NATIVE_TOKEN, "no_native_token");

        uint tokenNativePrice0CumulativeLast = tokenLP[_token].price0CumulativeLast();
        uint tokenNativePrice1CumulativeLast = tokenLP[_token].price1CumulativeLast();

        (,,uint32 tokenNativeBlockTimestampLast) = tokenLP[_token].getReserves();

        delete priceList[_token]; // reset
        TokenPrice storage tokenPriceInfo = priceList[_token];

        tokenPriceInfo.tokenNativeBlockTimestampLast = tokenNativeBlockTimestampLast;
        tokenPriceInfo.tokenNativePrice0CumulativeLast = tokenNativePrice0CumulativeLast;
        tokenPriceInfo.tokenNativePrice1CumulativeLast = tokenNativePrice1CumulativeLast;
        tokenPriceInfo.tokenValueInNativeAverage = 0;

        _update(_token);
    }

    function setTokenLP(address[] memory tokenLPPairs) external onlyControllerOrOwner {
        require(tokenLPPairs.length % 2 == 0);
       uint length = tokenLPPairs.length;
       for (uint i = 0; i < length; i = i + 2) {
           _setTokenLP(tokenLPPairs[i], tokenLPPairs[i + 1]);
       }
    }

    function getTokenNativeRate(address tokenAddress) public view returns (uint256, uint256, uint32, uint256) {
        (uint price0Cumulative, uint price1Cumulative, uint32 _blockTimestamp) = UniswapV2OracleLibrary.currentCumulativePrices(address(tokenLP[tokenAddress]));
        if (_blockTimestamp == priceList[tokenAddress].tokenNativeBlockTimestampLast) {
            return (
                priceList[tokenAddress].tokenNativePrice0CumulativeLast,
                priceList[tokenAddress].tokenNativePrice1CumulativeLast,
                priceList[tokenAddress].tokenNativeBlockTimestampLast,
                priceList[tokenAddress].tokenValueInNativeAverage
            );
        }

        uint32 timeElapsed = (_blockTimestamp - priceList[tokenAddress].tokenNativeBlockTimestampLast);

        FixedPoint.uq112x112 memory tokenValueInNativeAverage =
            tokenLP[tokenAddress].token1() == WRAPPED_NATIVE_TOKEN
            ? FixedPoint.uq112x112(uint224(1e18 * (price0Cumulative - priceList[tokenAddress].tokenNativePrice0CumulativeLast) / timeElapsed))
            : FixedPoint.uq112x112(uint224(1e18 * (price1Cumulative - priceList[tokenAddress].tokenNativePrice1CumulativeLast) / timeElapsed));

        return (price0Cumulative, price1Cumulative, _blockTimestamp, tokenValueInNativeAverage.mul(1).decode144());
    }

    function _update(address tokenAddress) private {
        (uint tokenNativePrice0CumulativeLast, uint tokenNativePrice1CumulativeLast, uint32 tokenNativeBlockTimestampLast, uint256 tokenValueInNativeAverage) = getTokenNativeRate(tokenAddress);

        TokenPrice storage tokenPriceInfo = priceList[tokenAddress];

        tokenPriceInfo.tokenNativeBlockTimestampLast = tokenNativeBlockTimestampLast;
        tokenPriceInfo.tokenNativePrice0CumulativeLast = tokenNativePrice0CumulativeLast;
        tokenPriceInfo.tokenNativePrice1CumulativeLast = tokenNativePrice1CumulativeLast;
        tokenPriceInfo.tokenValueInNativeAverage = tokenValueInNativeAverage;
    }

    // Update "last" state variables to current values
   function update(address[] memory tokenAddress) external onlyControllerOrOwner {
       uint length = tokenAddress.length;
       for (uint i = 0; i < length; ++i) {
           _update(tokenAddress[i]);
       }
    }

    // Return the average price since last update
    function getData(address tokenAddress) external view returns (uint256) {
        (,,, uint tokenValueInNativeAverage) = getTokenNativeRate(tokenAddress);
        return (tokenValueInNativeAverage);
    }

    function updateController(address _controller) external onlyOwner {
        controller = _controller;
    }
}
