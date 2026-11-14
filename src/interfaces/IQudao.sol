// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @notice Types shared by the Qudao contracts.
library QudaoTypes {
    /// @dev Where a range goes once the price leaves it. The keeper computes the new range off-chain;
    ///      the vault only accepts ranges that obey the strategy's on-chain bounds.
    enum Strategy {
        Static, // same distances from the price as when opened
        NarrowOnRise, // ±15% width step depending on direction
        WidenWhenVolatile, // ≈2 daily moves each side
        FollowAverage // centred on the 24h average price
    }

    struct Settings {
        Strategy strategy;
        bool waitForMarket; // Stock Tokens: keeper skips moves while the stock market is closed
        bool autoCompound;
        uint16 reinvestBps; // share of earned fees put back into the position (1000..10000)
        uint16 slippageBps; // max swap price tolerance vs the checked price
    }

    /// @dev A swap planned off-chain (PancakeSwap Smart Router calldata) and checked on-chain.
    struct SwapStep {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        address router;
        bytes data;
    }

    struct OpenParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0; // includes msg.value when the token is WBNB
        uint256 amount1;
        uint256 amount0Min;
        uint256 amount1Min;
        uint160 createPoolSqrtPriceX96; // 0 = the pool must already exist
        Settings settings;
        bytes8 referralCode;
        uint256 deadline;
    }

    struct Config {
        uint16 protocolFeeBps;
        uint16 minReinvestBps;
        uint16 maxDeviationBps;
        uint16 minSlippageBps;
        uint16 maxSlippageBps;
        uint16 minReinvestShareBps;
        uint24 minWidthTicks;
        uint32 minRebalanceInterval;
        uint32 keeperGrace;
        uint32 keeperGasOverhead;
        uint64 maxKeeperGasPrice;
        uint128 maxKeeperRefund;
    }
}

interface IQudaoFactory {
    function config() external view returns (QudaoTypes.Config memory);
    function paused() external view returns (bool);
    function isKeeper(address account) external view returns (bool);
    function keeperStale() external view returns (bool);
    function isVault(address account) external view returns (bool);
    function isStable(address token) external view returns (bool);
    function feeBpsFor(address user) external view returns (uint256);
    function recordKeeperAction() external;

    function permit2() external view returns (address);
    function positionManager() external view returns (address);
    function masterChef() external view returns (address);
    function cake() external view returns (address);
    function wbnb() external view returns (address);
    function swapper() external view returns (address);
    function oracle() external view returns (address);
    function revenueRouter() external view returns (address);
}

interface ISwapper {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address router, bytes calldata data)
        external
        returns (uint256 amountOut);
}

interface IPriceOracle {
    /// @notice Reverts unless the pool's current price agrees with an independent reference.
    function checkPool(address pool, uint256 maxDeviationBps) external view returns (uint160 sqrtPriceX96, int24 tick);

    /// @notice Value of `amountIn` of `tokenIn` in `tokenOut`, from Chainlink USD feeds. 0 when either feed is missing.
    function quoteUsdFeeds(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256);
}

interface IRevenueRouter {
    function onFee(address user, address[] calldata tokens, uint256[] calldata amounts) external;
    function onSwapFee(address token, uint256 amount) external;
}

interface ITheWell {
    function discountBpsOf(address user) external view returns (uint256);
    function notifyReward() external payable;
}

interface IReferrals {
    function link(address user, bytes8 code) external returns (address referrer);
    function referrerOf(address user) external view returns (address);
    function inviteeDiscountBpsOf(address user) external view returns (uint256);
}
