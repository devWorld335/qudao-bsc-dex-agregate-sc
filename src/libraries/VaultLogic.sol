// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {IPriceOracle, QudaoTypes} from "../interfaces/IQudao.sol";

/// @title VaultLogic
/// @notice Price, range and valuation checks used by every QudaoVault. Deployed once and linked (external library),
///         which keeps the vault under the 24 KB contract size limit.
library VaultLogic {
    uint256 internal constant Q96 = 1 << 96;

    error BadRange();
    error RangeOutsideStrategy();

    struct Pool {
        address token0;
        address token1;
        int24 tickSpacing;
    }

    /// @notice A range must be on the tick grid, contain the current price and be at least `minWidth` ticks wide.
    function checkRangeShape(int24 lower, int24 upper, int24 tick, int24 spacing, uint256 minWidth) external pure {
        if (lower >= upper || lower % spacing != 0 || upper % spacing != 0) revert BadRange();
        if (lower < TickMath.MIN_TICK || upper > TickMath.MAX_TICK) revert BadRange();
        if (tick < lower || tick >= upper) revert BadRange();
        if (uint256(int256(upper - lower)) < minWidth) revert BadRange();
    }

    /// @notice Static: the same distances from the price as when opened (±1 tick spacing for rounding).
    ///         Dynamic rules: any width between half and twice the starting width (the keeper computes the rule).
    function checkStrategy(
        QudaoTypes.Strategy strategy,
        int24 lower,
        int24 upper,
        int24 tick,
        int24 spacing,
        int24 lowerOffset,
        int24 upperOffset,
        int24 initialWidth
    ) external pure {
        if (strategy == QudaoTypes.Strategy.Static) {
            int24 expLower = floorToSpacing(tick + lowerOffset, spacing);
            int24 expUpper = floorToSpacing(tick + upperOffset, spacing);
            if (absDiff(lower, expLower) > spacing || absDiff(upper, expUpper) > spacing) {
                revert RangeOutsideStrategy();
            }
        } else {
            int24 width = upper - lower;
            if (width * 2 < initialWidth || width > initialWidth * 2) revert RangeOutsideStrategy();
        }
    }

    /// @notice Token amounts held by `liq` liquidity in [lower, upper) at price `sqrtP`.
    function amountsFor(uint160 sqrtP, int24 lower, int24 upper, uint128 liq)
        external
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        return LiquidityAmounts.getAmountsForLiquidity(
            sqrtP, TickMath.getSqrtRatioAtTick(lower), TickMath.getSqrtRatioAtTick(upper), liq
        );
    }

    /// @notice Fair output for a swap: the (oracle-checked) pool price between the pool's own tokens; Chainlink
    ///         USD feeds otherwise; or feeds to one pool token and the pool price on to the other. 0 = no fair price.
    function fairOut(IPriceOracle oracle, Pool memory p, address tIn, address tOut, uint256 amountIn, uint160 sqrtP)
        public
        view
        returns (uint256)
    {
        bool inPool = tIn == p.token0 || tIn == p.token1;
        bool outPool = tOut == p.token0 || tOut == p.token1;
        if (inPool && outPool) return tIn == p.token0 ? convert0to1(amountIn, sqrtP) : convert1to0(amountIn, sqrtP);
        uint256 q = oracle.quoteUsdFeeds(tIn, tOut, amountIn);
        if (q > 0 || !outPool) return q;
        address other = tOut == p.token0 ? p.token1 : p.token0;
        q = oracle.quoteUsdFeeds(tIn, other, amountIn);
        if (q == 0) return 0;
        return other == p.token0 ? convert0to1(q, sqrtP) : convert1to0(q, sqrtP);
    }

    /// @notice Value, in token1, of a position plus idle tokens (CAKE valued via {fairOut}; 0 if unpriceable).
    function values(
        IPriceOracle oracle,
        Pool memory p,
        address cake,
        uint160 sqrtP,
        int24 lower,
        int24 upper,
        uint128 liq,
        uint256 idle0,
        uint256 idle1,
        uint256 idleCake
    ) external view returns (uint256 positionValue, uint256 idleValue) {
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtP, TickMath.getSqrtRatioAtTick(lower), TickMath.getSqrtRatioAtTick(upper), liq
        );
        positionValue = a1 + convert0to1(a0, sqrtP);
        idleValue = idle1 + convert0to1(idle0, sqrtP);
        if (idleCake > 0) idleValue += fairOut(oracle, p, cake, p.token1, idleCake, sqrtP);
    }

    function convert0to1(uint256 a, uint160 sqrtP) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(a, sqrtP, Q96), sqrtP, Q96);
    }

    function convert1to0(uint256 a, uint160 sqrtP) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(a, Q96, sqrtP), Q96, sqrtP);
    }

    function floorToSpacing(int24 t, int24 spacing) internal pure returns (int24) {
        int24 r = t / spacing;
        if (t < 0 && t % spacing != 0) r--;
        return r * spacing;
    }

    function absDiff(int24 a, int24 b) internal pure returns (int24) {
        return a > b ? a - b : b - a;
    }
}
