// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {IWBNB, IFlapPortal, IPancakeV2Pair} from "./interfaces/external/IExternal.sol";
import {IPancakeV3Pool} from "./interfaces/external/IPancakeV3.sol";
import {IQudaoFactory, ISwapper, IPriceOracle} from "./interfaces/IQudao.sol";

/// @title BuybackBurner
/// @notice Buys QDAO with its share of protocol revenue and burns all of it (sends it to 0x…dEaD).
///         While QDAO trades on its flap.sh bonding curve it buys on the curve; once QDAO graduates to its
///         PancakeSwap pool (v3 for a standard token, v2 for a tax token) it buys there. The switch happens by
///         itself. Each buy is capped and spaced out, and only goes ahead if the price has stayed nearly the same
///         for at least `stabilitySec` (arm, then execute), which makes it hard to pump the price just before a buy.
contract BuybackBurner is Ownable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint8 public constant STATUS_CURVE = 1;
    uint8 public constant STATUS_DEX = 4;
    uint256 public constant BPS = 10_000;

    struct Params {
        uint32 curveMinInterval; // seconds between curve buys
        uint32 curveMaxWait; // buy smaller amounts after waiting this long
        uint128 curveMinAmount; // wait for at least this much BNB on the curve
        uint32 dexMinInterval;
        uint128 dexMaxPerBuy;
        uint32 stabilitySec;
        uint16 stabilityBps;
        uint16 maxBuyTaxBps; // skip while the token's buy tax is above this (e.g. anti-snipe tax)
        uint16 slippageBps;
        uint32 armValidity; // an armed buy expires after this long
    }

    struct Armed {
        uint128 amountIn;
        uint128 quote;
        uint64 at;
        bool onCurve;
    }

    IQudaoFactory public immutable factory;
    IWBNB public immutable wbnb;
    IFlapPortal public immutable portal;
    address public immutable pancakeV2Factory;

    IERC20 public qdao;
    address public immutable launcher; // admin Safe: may set QDAO once, without the timelock delay
    Params public params;
    Armed public armed;
    uint64 public lastBuy;
    uint64 public waitingSince;

    uint256 public totalBnbSpent;
    uint256 public totalBurned;

    event QdaoSet(address qdao);
    event ParamsSet(Params params);
    event BuyArmed(uint256 amountIn, uint256 quote, bool onCurve);
    event BoughtAndBurned(uint256 bnbIn, uint256 qdaoBurned, bool onCurve);
    event Burned(uint256 amount);

    error OnlyKeeper();
    error QdaoNotSet();
    error QdaoAlreadySet();
    error NothingToBuy();
    error TaxTooHigh(uint256 buyTaxBps);
    error NoQuote();
    error NotArmed();
    error TooEarly();
    error Expired();
    error PriceMoved(uint256 armedQuote, uint256 nowQuote);
    error PhaseChanged();

    modifier onlyKeeper() {
        if (!factory.isKeeper(msg.sender) && !factory.keeperStale() && msg.sender != owner()) revert OnlyKeeper();
        _;
    }

    constructor(
        address owner_,
        address launcher_,
        IQudaoFactory factory_,
        IWBNB wbnb_,
        IFlapPortal portal_,
        address v2Factory_,
        Params memory p
    ) Ownable(owner_) {
        launcher = launcher_;
        factory = factory_;
        wbnb = wbnb_;
        portal = portal_;
        pancakeV2Factory = v2Factory_;
        params = p;
        emit ParamsSet(p);
    }

    receive() external payable {
        if (msg.sender != address(wbnb) && waitingSince == 0) waitingSince = uint64(block.timestamp);
    }

    // ---------------------------------------------------------------- admin (timelock)

    function setQdao(IERC20 qdao_) external {
        if (msg.sender != owner() && msg.sender != launcher) revert OwnableUnauthorizedAccount(msg.sender);
        if (address(qdao) != address(0)) revert QdaoAlreadySet();
        qdao = qdao_;
        emit QdaoSet(address(qdao_));
    }

    function setParams(Params calldata p) external onlyOwner {
        params = p;
        emit ParamsSet(p);
    }

    // ---------------------------------------------------------------- views

    /// @notice Where QDAO trades now, its DEX pool once graduated, and its current buy tax (bps).
    function phase() public view returns (bool onCurve, address dexPool, uint256 buyTaxBps) {
        if (address(qdao) == address(0)) revert QdaoNotSet();
        IFlapPortal.TokenStateV8 memory s = portal.getTokenV8Safe(address(qdao));
        return (s.status == STATUS_CURVE, s.pool, s.buyTaxRate);
    }

    /// @notice How much BNB the next buy would spend right now (0 = nothing due yet).
    function nextBuyAmount() public view returns (uint256 amount, bool onCurve) {
        (onCurve,,) = phase();
        uint256 bal = address(this).balance;
        Params memory p = params;
        if (onCurve) {
            if (block.timestamp < uint256(lastBuy) + p.curveMinInterval) return (0, onCurve);
            bool waitedLong = waitingSince != 0 && block.timestamp >= uint256(waitingSince) + p.curveMaxWait;
            amount = (bal >= p.curveMinAmount || waitedLong) ? bal : 0;
        } else {
            if (block.timestamp < uint256(lastBuy) + p.dexMinInterval) return (0, onCurve);
            amount = bal < p.dexMaxPerBuy ? bal : p.dexMaxPerBuy;
        }
    }

    // ---------------------------------------------------------------- buy (keeper: arm, wait, execute)

    function arm() external onlyKeeper {
        (uint256 amount, bool onCurve) = nextBuyAmount();
        if (amount == 0) revert NothingToBuy();
        (,, uint256 tax) = phase();
        if (tax > params.maxBuyTaxBps) revert TaxTooHigh(tax);
        uint256 q = quote(amount, onCurve);
        if (q == 0) revert NoQuote();
        armed = Armed(uint128(amount), uint128(q), uint64(block.timestamp), onCurve);
        emit BuyArmed(amount, q, onCurve);
    }

    /// @param router,data PancakeSwap Smart Router calldata for the DEX phase (ignored on the curve).
    function execute(address router, bytes calldata data) external onlyKeeper nonReentrant returns (uint256 burned) {
        Armed memory a = armed;
        Params memory p = params;
        if (a.at == 0) revert NotArmed();
        if (block.timestamp < uint256(a.at) + p.stabilitySec) revert TooEarly();
        if (block.timestamp > uint256(a.at) + p.armValidity) revert Expired();
        (bool onCurve,, uint256 tax) = phase();
        if (onCurve != a.onCurve) revert PhaseChanged();
        if (tax > p.maxBuyTaxBps) revert TaxTooHigh(tax);

        uint256 q = quote(a.amountIn, onCurve);
        uint256 diff = q > a.quote ? q - a.quote : a.quote - q;
        if (diff * BPS > uint256(a.quote) * p.stabilityBps) revert PriceMoved(a.quote, q);
        uint256 minOut = (uint256(a.quote) * (BPS - p.slippageBps)) / BPS;

        delete armed;
        if (onCurve) {
            portal.swapExactInput{value: a.amountIn}(
                IFlapPortal.ExactInputParams({
                    inputToken: address(0),
                    outputToken: address(qdao),
                    inputAmount: a.amountIn,
                    minOutputAmount: minOut,
                    permitData: ""
                })
            );
        } else {
            wbnb.deposit{value: a.amountIn}();
            address swapper = factory.swapper();
            IERC20(address(wbnb)).forceApprove(swapper, a.amountIn);
            ISwapper(swapper).swap(address(wbnb), address(qdao), a.amountIn, minOut, router, data);
            uint256 leftover = wbnb.balanceOf(address(this));
            if (leftover > 0) wbnb.withdraw(leftover);
        }

        burned = qdao.balanceOf(address(this));
        qdao.safeTransfer(DEAD, burned);
        lastBuy = uint64(block.timestamp);
        waitingSince = address(this).balance > 0 ? uint64(block.timestamp) : 0;
        totalBnbSpent += a.amountIn;
        totalBurned += burned;
        emit BoughtAndBurned(a.amountIn, burned, onCurve);
    }

    /// @notice Burns any QDAO this contract holds (e.g. sent here directly).
    function burnHeld() external returns (uint256 amount) {
        amount = qdao.balanceOf(address(this));
        if (amount == 0) return 0;
        qdao.safeTransfer(DEAD, amount);
        totalBurned += amount;
        emit Burned(amount);
    }

    /// @notice Expected QDAO for `amountIn` BNB, after the token's buy tax.
    function quote(uint256 amountIn, bool onCurve) public returns (uint256 out) {
        if (onCurve) {
            try portal.quoteExactInput(
                IFlapPortal.QuoteExactInputParams({inputToken: address(0), outputToken: address(qdao), inputAmount: amountIn})
            ) returns (uint256 q) {
                return q;
            } catch {
                return 0;
            }
        }
        (, address pool, uint256 tax) = phase();
        if (pool == address(0)) return 0;
        out = _dexQuote(pool, amountIn);
        out = (out * (BPS - (tax > BPS ? BPS : tax))) / BPS;
    }

    function _dexQuote(address pool, uint256 bnbIn) internal view returns (uint256) {
        address q = address(qdao);
        bool isV2 = _isV2(pool);
        address t0 = isV2 ? IPancakeV2Pair(pool).token0() : IPancakeV3Pool(pool).token0();
        address t1 = isV2 ? IPancakeV2Pair(pool).token1() : IPancakeV3Pool(pool).token1();
        address other = t0 == q ? t1 : t0;
        uint256 amountIn = bnbIn;
        if (other != address(wbnb)) {
            // QDAO paired with a stablecoin (e.g. USD1/USDT): value the BNB in that token via Chainlink.
            amountIn = IPriceOracle(factory.oracle()).quoteUsdFeeds(address(wbnb), other, bnbIn);
            if (amountIn == 0) return 0;
        }
        if (isV2) {
            (uint112 r0, uint112 r1,) = IPancakeV2Pair(pool).getReserves();
            (uint256 rIn, uint256 rOut) = t0 == q ? (uint256(r1), uint256(r0)) : (uint256(r0), uint256(r1));
            uint256 inWithFee = amountIn * 9975; // PancakeSwap v2: 0.25% fee
            return (inWithFee * rOut) / (rIn * BPS + inWithFee);
        }
        (uint160 sqrtP,,,,,,) = IPancakeV3Pool(pool).slot0();
        uint256 fee = IPancakeV3Pool(pool).fee(); // in hundredths of a bip
        uint256 afterFee = (amountIn * (1_000_000 - fee)) / 1_000_000;
        // price = token1 per token0 = sqrtP^2 / 2^192
        if (t0 == q) {
            // paying token1 for token0: out = in / price
            return FullMath.mulDiv(FullMath.mulDiv(afterFee, 1 << 96, sqrtP), 1 << 96, sqrtP);
        }
        return FullMath.mulDiv(FullMath.mulDiv(afterFee, sqrtP, 1 << 96), sqrtP, 1 << 96);
    }

    function _isV2(address pool) internal view returns (bool) {
        (bool ok, bytes memory ret) = pool.staticcall(abi.encodeWithSignature("factory()"));
        return ok && ret.length == 32 && abi.decode(ret, (address)) == pancakeV2Factory;
    }
}
