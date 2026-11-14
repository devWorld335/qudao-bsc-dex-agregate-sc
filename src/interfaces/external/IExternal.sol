// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IWBNB is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @notice Chainlink price feed.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice PancakeSwap v2 pair (flap.sh tax tokens graduate into v2 pairs).
interface IPancakeV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function factory() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

/// @notice flap.sh Portal (BNB Smart Chain launchpad). Only the calls Qudao needs.
interface IFlapPortal {
    struct ExactInputParams {
        address inputToken;
        address outputToken;
        uint256 inputAmount;
        uint256 minOutputAmount;
        bytes permitData;
    }

    struct QuoteExactInputParams {
        address inputToken;
        address outputToken;
        uint256 inputAmount;
    }

    /// @dev Field order matches the verified Portal ABI (getTokenV8Safe).
    struct TokenStateV8 {
        uint8 status; // 1 = trading on the bonding curve, 4 = graduated to a DEX pool
        uint256 reserve;
        uint256 circulatingSupply;
        uint256 price;
        uint8 tokenVersion;
        uint256 r;
        uint256 h;
        uint256 k;
        uint256 dexSupplyThresh;
        address quoteTokenAddress;
        bool nativeToQuoteSwapEnabled;
        bytes32 extensionID;
        uint256 buyTaxRate;
        uint256 sellTaxRate;
        address pool;
        uint256 progress;
        uint8 lpFeeProfile;
        uint8 dexId;
    }

    function swapExactInput(ExactInputParams calldata params) external payable returns (uint256);
    function quoteExactInput(QuoteExactInputParams calldata params) external returns (uint256);
    function getTokenV8Safe(address token) external view returns (TokenStateV8 memory);
}
