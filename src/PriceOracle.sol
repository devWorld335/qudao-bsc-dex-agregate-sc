// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {IPancakeV3Pool} from "./interfaces/external/IPancakeV3.sol";
import {IAggregatorV3} from "./interfaces/external/IExternal.sol";
import {IPriceOracle} from "./interfaces/IQudao.sol";

/// @title PriceOracle
/// @notice Decides whether a PancakeSwap v3 pool's price can be trusted right now, before a vault moves a range,
///         reinvests or swaps. One tick is 0.01%, so deviations are compared in ticks (bps ≈ ticks).
///         Reference, in order of preference:
///           1. Chainlink USD feeds for both tokens,
///           2. the pool's own time-weighted average price (TWAP),
///           3. a price recorded 1–30 minutes earlier with {snapshot}, for pools without enough history.
contract PriceOracle is IPriceOracle, Ownable {
    struct Feed {
        IAggregatorV3 aggregator;
        uint32 maxAge;
    }

    struct Snapshot {
        int24 tick;
        uint64 at;
    }

    mapping(address token => Feed) public usdFeeds;
    mapping(address pool => Snapshot) public snapshots;

    uint32 public twapSeconds;
    uint32 public delayedMin;
    uint32 public delayedMax;

    event FeedSet(address indexed token, address aggregator, uint32 maxAge);
    event WindowsSet(uint32 twapSeconds, uint32 delayedMin, uint32 delayedMax);
    event Snapshotted(address indexed pool, int24 tick);

    error NoReference(address pool);
    error PriceDeviates(address pool, int24 tick, int24 referenceTick);
    error StaleFeed(address token);
    error BadWindows();
    error NotEnoughGas();

    constructor(address owner_, uint32 twapSeconds_, uint32 delayedMin_, uint32 delayedMax_) Ownable(owner_) {
        _setWindows(twapSeconds_, delayedMin_, delayedMax_);
    }

    // ---------------------------------------------------------------- admin (timelock)

    function setFeed(address token, address aggregator, uint32 maxAge) external onlyOwner {
        usdFeeds[token] = Feed(IAggregatorV3(aggregator), maxAge);
        emit FeedSet(token, aggregator, maxAge);
    }

    function setWindows(uint32 twapSeconds_, uint32 delayedMin_, uint32 delayedMax_) external onlyOwner {
        _setWindows(twapSeconds_, delayedMin_, delayedMax_);
    }

    function _setWindows(uint32 t, uint32 dMin, uint32 dMax) internal {
        if (t == 0 || dMin == 0 || dMax <= dMin) revert BadWindows();
        (twapSeconds, delayedMin, delayedMax) = (t, dMin, dMax);
        emit WindowsSet(t, dMin, dMax);
    }

    // ---------------------------------------------------------------- delayed confirmation

    /// @notice Records the pool's current price. Pools without a feed or TWAP history can act 1–30 minutes later
    ///         if the price is still about the same. Anyone may call it (the keeper does, hourly).
    function snapshot(address pool) external {
        (, int24 tick,,,,,) = IPancakeV3Pool(pool).slot0();
        snapshots[pool] = Snapshot(tick, uint64(block.timestamp));
        emit Snapshotted(pool, tick);
    }

    // ---------------------------------------------------------------- checks

    /// @inheritdoc IPriceOracle
    function checkPool(address pool, uint256 maxDeviationBps) external view returns (uint160 sqrtPriceX96, int24 tick) {
        (sqrtPriceX96, tick,,,,,) = IPancakeV3Pool(pool).slot0();
        (bool ok, int24 refTick) = referenceTick(pool);
        if (!ok) revert NoReference(pool);
        int256 diff = int256(tick) - int256(refTick);
        if (diff < 0) diff = -diff;
        if (uint256(diff) > maxDeviationBps) revert PriceDeviates(pool, tick, refTick);
    }

    /// @notice The reference tick used by {checkPool}, and whether one is available.
    function referenceTick(address pool) public view returns (bool ok, int24 tick) {
        IPancakeV3Pool p = IPancakeV3Pool(pool);
        (ok, tick) = _chainlinkTick(p.token0(), p.token1());
        if (ok) return (ok, tick);
        (ok, tick) = _twapTick(p);
        if (ok) return (ok, tick);
        Snapshot memory s = snapshots[pool];
        if (s.at != 0 && block.timestamp >= s.at + delayedMin && block.timestamp <= s.at + delayedMax) {
            return (true, s.tick);
        }
        return (false, 0);
    }

    /// @inheritdoc IPriceOracle
    function quoteUsdFeeds(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256) {
        (bool okIn, uint256 pIn) = _usdPrice(tokenIn);
        (bool okOut, uint256 pOut) = _usdPrice(tokenOut);
        if (!okIn || !okOut || pOut == 0) return 0;
        // amountOut = amountIn * pIn / pOut, adjusted for token decimals (prices are scaled to 1e18).
        uint8 dIn = IERC20Metadata(tokenIn).decimals();
        uint8 dOut = IERC20Metadata(tokenOut).decimals();
        uint256 out = FullMath.mulDiv(amountIn, pIn, pOut);
        if (dOut > dIn) out *= 10 ** (dOut - dIn);
        else if (dIn > dOut) out /= 10 ** (dIn - dOut);
        return out;
    }

    // ---------------------------------------------------------------- internals

    /// @dev USD price scaled to 1e18, or (false, 0) when there is no fresh feed.
    function _usdPrice(address token) internal view returns (bool, uint256) {
        Feed memory f = usdFeeds[token];
        if (address(f.aggregator) == address(0)) return (false, 0);
        (, int256 answer,, uint256 updatedAt,) = f.aggregator.latestRoundData();
        if (answer <= 0 || updatedAt + f.maxAge < block.timestamp) return (false, 0);
        uint8 d = f.aggregator.decimals();
        uint256 p = uint256(answer);
        return (true, d <= 18 ? p * 10 ** (18 - d) : p / 10 ** (d - 18));
    }

    /// @dev Tick of token1-per-token0 implied by the two USD feeds.
    function _chainlinkTick(address token0, address token1) internal view returns (bool, int24) {
        (bool ok0, uint256 p0) = _usdPrice(token0);
        (bool ok1, uint256 p1) = _usdPrice(token1);
        if (!ok0 || !ok1 || p1 == 0) return (false, 0);
        uint8 d0 = IERC20Metadata(token0).decimals();
        uint8 d1 = IERC20Metadata(token1).decimals();
        // raw price (token1 base units per token0 base unit) = p0/p1 * 10^d1 / 10^d0, as a Q192 ratio.
        uint256 num = p0 * 10 ** d1;
        uint256 den = p1 * 10 ** d0;
        uint256 ratioX192 = FullMath.mulDiv(num, 1 << 192, den);
        uint256 sqrtP = Math.sqrt(ratioX192);
        if (sqrtP < TickMath.MIN_SQRT_RATIO || sqrtP >= TickMath.MAX_SQRT_RATIO) return (false, 0);
        return (true, TickMath.getTickAtSqrtRatio(uint160(sqrtP)));
    }

    function _twapTick(IPancakeV3Pool p) internal view returns (bool, int24) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = twapSeconds;
        // a `try` that runs out of gas would silently fall back to the snapshot: require the gas up front
        if (gasleft() < 100_000) revert NotEnoughGas();
        try p.observe(ago) returns (int56[] memory cum, uint160[] memory) {
            int56 delta = cum[1] - cum[0];
            int24 avg = int24(delta / int56(uint56(twapSeconds)));
            if (delta < 0 && (delta % int56(uint56(twapSeconds)) != 0)) avg--;
            return (true, avg);
        } catch {
            return (false, 0);
        }
    }
}
