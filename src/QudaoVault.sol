// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {VaultLogic} from "./libraries/VaultLogic.sol";
import {IPancakeV3Pool, INonfungiblePositionManager, IMasterChefV3} from "./interfaces/external/IPancakeV3.sol";
import {IWBNB} from "./interfaces/external/IExternal.sol";
import {QudaoTypes, IQudaoFactory, ISwapper, IPriceOracle, IRevenueRouter} from "./interfaces/IQudao.sol";

/// @title QudaoVault
/// @notice One vault per position, owned by one wallet. It holds a PancakeSwap v3 position (staked in MasterChef v3
///         when its pool earns CAKE) and the position's fees. The keeper can only move the range, collect and
///         reinvest — every call is checked against the owner's settings, the strategy bounds and an independent
///         price — and it can never send funds anywhere but back into the position. Only the owner withdraws.
///
///         Accounting: `idle*` belongs to the position (principal not placed yet, plus the reinvested share of
///         fees); `claimable*` are fees waiting for the owner. Both live in this contract.
contract QudaoVault is IERC721Receiver, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant Q96 = 1 << 96;
    /// @dev Gas the calls inside `try` blocks need (MasterChef stake measured at ~445k, harvest ~100k on BSC).
    uint256 internal constant STAKE_GAS = 600_000;
    uint256 internal constant HARVEST_GAS = 200_000;
    uint256 internal constant ORACLE_GAS = 150_000;

    // ---------------------------------------------------------------- state

    IQudaoFactory public factory;
    address public owner;
    address public pool;
    address public token0;
    address public token1;
    uint24 public fee;
    int24 public tickSpacing;

    INonfungiblePositionManager internal npm;
    IMasterChefV3 internal chef;
    address public cake;
    address public wbnb;

    uint256 public tokenId;
    bool public staked;
    bool public closed;
    bool internal _initialized;

    QudaoTypes.Settings internal _settings;
    int24 public lowerOffset; // tickLower − tick at open (static strategy)
    int24 public upperOffset;
    int24 public initialWidth;
    uint64 public openedAt;
    uint64 public lastRebalance;

    uint256 public idle0;
    uint256 public idle1;
    uint256 public idleCake;
    uint256 public claimable0;
    uint256 public claimable1;
    uint256 public claimableCake;

    // ---------------------------------------------------------------- events

    event Opened(int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 amount0, uint256 amount1);
    event FundsAdded(uint128 liquidity, uint256 amount0, uint256 amount1);
    event Withdrawn(uint128 liquidity, uint256 amount0, uint256 amount1);
    event Closed(uint256 amount0, uint256 amount1, uint256 cakeAmount);
    event Rebalanced(int24 oldLower, int24 oldUpper, int24 newLower, int24 newUpper, int24 tick, uint256 newTokenId);
    event Reinvested(uint128 liquidity, uint256 amount0, uint256 amount1);
    event FeesCollected(
        uint256 fees0, uint256 fees1, uint256 cakeEarned, uint256 protocol0, uint256 protocol1, uint256 protocolCake
    );
    event Claimed(uint256 amount0, uint256 amount1, uint256 cakeAmount, uint256 bnb);
    event SettingsUpdated(QudaoTypes.Settings settings);
    event Swapped(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event KeeperRefunded(address indexed keeper, uint256 amount);
    event FarmStaked(uint256 tokenId);
    event FarmUnstaked(uint256 tokenId);

    // ---------------------------------------------------------------- errors

    error AlreadyInitialized();
    error OnlyFactory();
    error OnlyOwner();
    error NotAllowed();
    error Paused();
    error IsClosed();
    error NoPosition();
    error BadRange();
    error RangeOutsideStrategy();
    error StillInRange();
    error OutOfRange();
    error TooSoon();
    error BadSettings();
    error BadSwap();
    error NoPrice();
    error BelowThreshold();
    error TransferFailed();
    error FeeOnTransfer();
    error NotEnoughGas();

    // ---------------------------------------------------------------- modifiers

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    /// @dev The keeper, the owner, or anyone once the keeper has been silent for longer than the grace period.
    modifier onlyAutomation() {
        if (msg.sender != owner && !factory.isKeeper(msg.sender) && !factory.keeperStale()) revert NotAllowed();
        _;
    }

    modifier whenActive() {
        if (factory.paused()) revert Paused();
        if (closed) revert IsClosed();
        _;
    }

    constructor() {
        _initialized = true; // the implementation itself can never be used
    }

    receive() external payable {
        if (msg.sender != wbnb) revert NotAllowed();
    }

    // ---------------------------------------------------------------- setup (factory)

    function initialize(address owner_, address pool_, QudaoTypes.Settings calldata s) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        factory = IQudaoFactory(msg.sender);
        owner = owner_;
        pool = pool_;
        IPancakeV3Pool p = IPancakeV3Pool(pool_);
        token0 = p.token0();
        token1 = p.token1();
        fee = p.fee();
        tickSpacing = p.tickSpacing();
        npm = INonfungiblePositionManager(factory.positionManager());
        chef = IMasterChefV3(factory.masterChef());
        cake = factory.cake();
        wbnb = factory.wbnb();
        _setSettings(s);
    }

    /// @notice Opens the position with the tokens the factory just moved in. What doesn't fit goes back to the owner.
    function openPosition(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1,
        uint256 amount0Min,
        uint256 amount1Min,
        bool refundNative
    ) external returns (uint256 id, uint128 liquidity) {
        if (msg.sender != address(factory)) revert OnlyFactory();
        if (tokenId != 0 || closed) revert BadRange();
        if (IERC20(token0).balanceOf(address(this)) < amount0 || IERC20(token1).balanceOf(address(this)) < amount1) {
            revert FeeOnTransfer();
        }
        (, int24 tick,,,,,) = IPancakeV3Pool(pool).slot0();
        VaultLogic.checkRangeShape(tickLower, tickUpper, tick, tickSpacing, factory.config().minWidthTicks);

        lowerOffset = tickLower - tick;
        upperOffset = tickUpper - tick;
        initialWidth = tickUpper - tickLower;
        openedAt = uint64(block.timestamp);
        lastRebalance = uint64(block.timestamp);

        uint256 used0;
        uint256 used1;
        (id, liquidity, used0, used1) = _mint(tickLower, tickUpper, amount0, amount1, amount0Min, amount1Min);
        _sendOut(token0, amount0 - used0, refundNative);
        _sendOut(token1, amount1 - used1, refundNative);
        _stakeIfFarm();
        emit Opened(tickLower, tickUpper, liquidity, used0, used1);
    }

    // ---------------------------------------------------------------- owner

    function settings() external view returns (QudaoTypes.Settings memory) {
        return _settings;
    }

    function updateSettings(QudaoTypes.Settings calldata s) external onlyOwner {
        _setSettings(s);
    }

    /// @notice Adds funds to the current range. The factory moves the owner's tokens in first (Permit2, approvals
    ///         or native BNB), then calls this; what doesn't fit goes straight back to the owner.
    function addFunds(uint256 amount0, uint256 amount1, uint256 amount0Min, uint256 amount1Min, bool refundNative)
        external
        whenActive
        nonReentrant
    {
        if (msg.sender != address(factory)) revert OnlyFactory();
        if (tokenId == 0) revert NoPosition();
        (uint128 liq, uint256 used0, uint256 used1) = _increase(amount0, amount1, amount0Min, amount1Min);
        _sendOut(token0, amount0 - used0, refundNative);
        _sendOut(token1, amount1 - used1, refundNative);
        emit FundsAdded(liq, used0, used1);
    }

    /// @notice Takes part of the liquidity out to the owner's wallet. Earned fees are collected first (and stay
    ///         claimable), so only principal is sent. Works while paused.
    function withdraw(uint128 liquidity, uint256 amount0Min, uint256 amount1Min)
        external
        onlyOwner
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (tokenId == 0) revert NoPosition();
        _collectFees(true);
        (amount0, amount1) = _decrease(liquidity, amount0Min, amount1Min);
        _collectTo(address(this));
        _sendOut(token0, amount0, false);
        _sendOut(token1, amount1, false);
        emit Withdrawn(liquidity, amount0, amount1);
    }

    /// @notice Closes the position and sends everything — principal, idle tokens, fees and CAKE — to the owner.
    ///         Always works, also while paused.
    function close(uint256 amount0Min, uint256 amount1Min) external onlyOwner nonReentrant {
        if (closed) revert IsClosed();
        _collectFees(false);
        _removeAll(amount0Min, amount1Min);
        closed = true;
        idle0 = idle1 = idleCake = 0;
        claimable0 = claimable1 = claimableCake = 0;
        uint256 a0 = IERC20(token0).balanceOf(address(this));
        uint256 a1 = IERC20(token1).balanceOf(address(this));
        uint256 c = (cake == token0 || cake == token1) ? 0 : IERC20(cake).balanceOf(address(this));
        _sendOut(token0, a0, false);
        _sendOut(token1, a1, false);
        if (c > 0) IERC20(cake).safeTransfer(owner, c);
        emit Closed(a0, a1, c);
    }

    /// @notice Sends the fees ready to claim (per token, plus CAKE) to the owner. Fees still in the pool are
    ///         collected first.
    function claim() external onlyOwner nonReentrant returns (uint256 a0, uint256 a1, uint256 c) {
        _collectFees(false);
        (a0, a1, c) = (claimable0, claimable1, claimableCake);
        claimable0 = claimable1 = claimableCake = 0;
        _sendOut(token0, a0, false);
        _sendOut(token1, a1, false);
        if (c > 0) IERC20(cake).safeTransfer(owner, c);
        emit Claimed(a0, a1, c, 0);
    }

    /// @notice Claims everything as BNB: the other tokens are swapped to WBNB (steps planned off-chain, checked
    ///         against a fair price and the owner's tolerance), then unwrapped. What isn't swapped is sent as is.
    function claimAsBNB(QudaoTypes.SwapStep[] calldata steps) external onlyOwner nonReentrant returns (uint256 bnb) {
        _collectFees(false);
        uint160 sqrtP;
        if (steps.length > 0) (sqrtP,) = _checkedPrice();
        for (uint256 i; i < steps.length; i++) {
            QudaoTypes.SwapStep calldata s = steps[i];
            if (s.tokenOut != wbnb || s.tokenIn == wbnb) revert BadSwap();
            if (s.amountIn > _claimableOf(s.tokenIn)) revert BadSwap();
            (uint256 spent, uint256 out) = _runSwap(s, sqrtP);
            _subClaimable(s.tokenIn, spent);
            bnb += out;
        }
        if (token0 == wbnb) (bnb, claimable0) = (bnb + claimable0, 0);
        if (token1 == wbnb) (bnb, claimable1) = (bnb + claimable1, 0);
        (uint256 a0, uint256 a1, uint256 c) = (claimable0, claimable1, claimableCake);
        claimable0 = claimable1 = claimableCake = 0;
        _sendOut(token0, a0, false);
        _sendOut(token1, a1, false);
        if (c > 0) IERC20(cake).safeTransfer(owner, c);
        if (bnb > 0) {
            IWBNB(wbnb).withdraw(bnb);
            (bool ok,) = owner.call{value: bnb}("");
            if (!ok) revert TransferFailed();
        }
        emit Claimed(a0, a1, c, bnb);
    }

    /// @notice Puts all fees (new and ready to claim) back into the position right away.
    function compound(QudaoTypes.SwapStep[] calldata steps) external onlyOwner whenActive nonReentrant {
        if (tokenId == 0) revert NoPosition();
        (uint160 sqrtP,) = _checkedPrice();
        _collectFees(false);
        (idle0, idle1, idleCake) = (idle0 + claimable0, idle1 + claimable1, idleCake + claimableCake);
        claimable0 = claimable1 = claimableCake = 0;
        _swapIdle(steps, sqrtP);
        _addIdle();
    }

    // ---------------------------------------------------------------- automation

    /// @notice Moves the range around the price once the price has left it. The new range must contain the
    ///         current price and obey the position's strategy; the price must agree with the oracle; and enough
    ///         time must have passed since the last move.
    function rebalance(int24 newLower, int24 newUpper, QudaoTypes.SwapStep[] calldata steps)
        external
        onlyAutomation
        whenActive
        nonReentrant
    {
        uint256 gasStart = gasleft();
        if (tokenId == 0) revert NoPosition();
        QudaoTypes.Config memory cfg = factory.config();
        if (block.timestamp < uint256(lastRebalance) + cfg.minRebalanceInterval) revert TooSoon();
        (uint160 sqrtP, int24 tick) = _checkedPrice();
        (int24 oldLower, int24 oldUpper,) = _range();
        if (tick >= oldLower && tick < oldUpper) revert StillInRange();
        VaultLogic.checkRangeShape(newLower, newUpper, tick, tickSpacing, cfg.minWidthTicks);
        VaultLogic.checkStrategy(
            _settings.strategy, newLower, newUpper, tick, tickSpacing, lowerOffset, upperOffset, initialWidth
        );

        _collectFees(true);
        _removeAll(0, 0);
        _swapIdle(steps, sqrtP);
        (uint256 id,,,) = _mint(newLower, newUpper, idle0, idle1, 0, 0);
        _stakeIfFarm();
        lastRebalance = uint64(block.timestamp);
        emit Rebalanced(oldLower, oldUpper, newLower, newUpper, tick, id);
        _refundKeeper(gasStart);
    }

    /// @notice Collects fees and adds the reinvested share back into the range once it is worth at least
    ///         `minReinvestBps` of the position (the keeper applies stricter thresholds for small positions).
    function reinvest(QudaoTypes.SwapStep[] calldata steps) external onlyAutomation whenActive nonReentrant {
        uint256 gasStart = gasleft();
        if (tokenId == 0) revert NoPosition();
        (uint160 sqrtP, int24 tick) = _checkedPrice();
        (int24 lower, int24 upper, uint128 liq) = _range();
        if (tick < lower || tick >= upper) revert OutOfRange();
        _collectFees(true);

        (uint256 positionValue, uint256 idleValue) = VaultLogic.values(
            IPriceOracle(factory.oracle()), _poolInfo(), cake, sqrtP, lower, upper, liq, idle0, idle1, idleCake
        );
        if (idleValue * BPS < positionValue * factory.config().minReinvestBps) revert BelowThreshold();

        _swapIdle(steps, sqrtP);
        _addIdle();
        _refundKeeper(gasStart);
    }

    // ---------------------------------------------------------------- views

    function range() external view returns (int24 tickLower, int24 tickUpper, uint128 liquidity) {
        return _range();
    }

    /// @notice Principal in the position right now (excludes idle tokens and fees).
    function positionAmounts() external view returns (uint256 amount0, uint256 amount1) {
        if (tokenId == 0) return (0, 0);
        (uint160 sqrtP,,,,,,) = IPancakeV3Pool(pool).slot0();
        (int24 lower, int24 upper, uint128 liq) = _range();
        return VaultLogic.amountsFor(sqrtP, lower, upper, liq);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(npm)) revert NotAllowed();
        return IERC721Receiver.onERC721Received.selector;
    }

    // ---------------------------------------------------------------- internals: settings & checks

    function _setSettings(QudaoTypes.Settings calldata s) internal {
        QudaoTypes.Config memory cfg = factory.config();
        if (s.slippageBps < cfg.minSlippageBps || s.slippageBps > cfg.maxSlippageBps) revert BadSettings();
        if (s.reinvestBps < cfg.minReinvestShareBps || s.reinvestBps > BPS) revert BadSettings();
        _settings = s;
        emit SettingsUpdated(s);
    }

    function _checkedPrice() internal view returns (uint160 sqrtP, int24 tick) {
        return IPriceOracle(factory.oracle()).checkPool(pool, factory.config().maxDeviationBps);
    }

    // ---------------------------------------------------------------- internals: position

    function _range() internal view returns (int24 lower, int24 upper, uint128 liq) {
        if (tokenId == 0) return (0, 0, 0);
        (,,,,, lower, upper, liq,,,,) = npm.positions(tokenId);
    }

    function _mint(int24 lower, int24 upper, uint256 a0, uint256 a1, uint256 min0, uint256 min1)
        internal
        returns (uint256 id, uint128 liq, uint256 used0, uint256 used1)
    {
        IERC20(token0).forceApprove(address(npm), a0);
        IERC20(token1).forceApprove(address(npm), a1);
        (id, liq, used0, used1) = npm.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: fee,
                tickLower: lower,
                tickUpper: upper,
                amount0Desired: a0,
                amount1Desired: a1,
                amount0Min: min0,
                amount1Min: min1,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
        IERC20(token0).forceApprove(address(npm), 0);
        IERC20(token1).forceApprove(address(npm), 0);
        tokenId = id;
        // whatever the mint used of the idle balances is no longer idle
        idle0 = idle0 > used0 ? idle0 - used0 : 0;
        idle1 = idle1 > used1 ? idle1 - used1 : 0;
    }

    function _increase(uint256 a0, uint256 a1, uint256 min0, uint256 min1)
        internal
        returns (uint128 liq, uint256 used0, uint256 used1)
    {
        address spender = staked ? address(chef) : address(npm);
        IERC20(token0).forceApprove(spender, a0);
        IERC20(token1).forceApprove(spender, a1);
        INonfungiblePositionManager.IncreaseLiquidityParams memory p = INonfungiblePositionManager
            .IncreaseLiquidityParams({
            tokenId: tokenId,
            amount0Desired: a0,
            amount1Desired: a1,
            amount0Min: min0,
            amount1Min: min1,
            deadline: block.timestamp
        });
        (liq, used0, used1) = staked ? chef.increaseLiquidity(p) : npm.increaseLiquidity(p);
        IERC20(token0).forceApprove(spender, 0);
        IERC20(token1).forceApprove(spender, 0);
    }

    function _decrease(uint128 liq, uint256 min0, uint256 min1) internal returns (uint256 a0, uint256 a1) {
        if (liq == 0) return (0, 0);
        INonfungiblePositionManager.DecreaseLiquidityParams memory p = INonfungiblePositionManager
            .DecreaseLiquidityParams({
            tokenId: tokenId,
            liquidity: liq,
            amount0Min: min0,
            amount1Min: min1,
            deadline: block.timestamp
        });
        (a0, a1) = staked ? chef.decreaseLiquidity(p) : npm.decreaseLiquidity(p);
    }

    function _collectTo(address to) internal returns (uint256 c0, uint256 c1) {
        INonfungiblePositionManager.CollectParams memory p = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId,
            recipient: to,
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });
        (c0, c1) = staked ? chef.collect(p) : npm.collect(p);
    }

    /// @dev Adds every idle token that fits the current range.
    function _addIdle() internal {
        (uint128 liq, uint256 used0, uint256 used1) = _increase(idle0, idle1, 0, 0);
        idle0 -= used0;
        idle1 -= used1;
        emit Reinvested(liq, used0, used1);
    }

    /// @dev Takes all liquidity out (principal becomes idle) and burns the NFT. Fees must be collected before.
    function _removeAll(uint256 min0, uint256 min1) internal {
        if (tokenId == 0) return;
        if (staked) {
            uint256 reward = chef.withdraw(tokenId, address(this));
            staked = false;
            emit FarmUnstaked(tokenId);
            if (reward > 0) _processEarnings(0, 0, reward, true);
        }
        (,,,,,,, uint128 liq,,,,) = npm.positions(tokenId);
        (uint256 a0, uint256 a1) = _decrease(liq, min0, min1);
        _collectTo(address(this));
        idle0 += a0;
        idle1 += a1;
        npm.burn(tokenId);
        tokenId = 0;
    }

    function _stakeIfFarm() internal {
        if (staked || tokenId == 0) return;
        uint256 pid = chef.v3PoolAddressPid(pool);
        if (pid == 0) return;
        (uint256 alloc,,,,,,) = chef.poolInfo(pid);
        if (alloc == 0 || chef.emergency()) return;
        _needGas(STAKE_GAS);
        try npm.safeTransferFrom(address(this), address(chef), tokenId) {
            staked = true;
            emit FarmStaked(tokenId);
        } catch {}
    }

    /// @dev A `try` that runs out of gas is caught like any other failure. Wallets size gas by searching for the
    ///      lowest amount that doesn't revert, which would land on an amount that silently skips the call (a position
    ///      that never farms CAKE). Requiring the gas up front makes a too-low limit revert instead.
    function _needGas(uint256 inner) private view {
        if (gasleft() < (inner * 64) / 63 + 10_000) revert NotEnoughGas();
    }

    // ---------------------------------------------------------------- internals: fees

    /// @param split true: the reinvest share (if auto-compound is on) goes to the position, the rest is claimable.
    function _collectFees(bool split) internal {
        if (tokenId == 0) return;
        (uint256 f0, uint256 f1) = _collectTo(address(this));
        uint256 c;
        // pendingCake() only reflects the farm's last update; harvest() brings it up to date first.
        if (staked) {
            _needGas(HARVEST_GAS);
            try chef.harvest(tokenId, address(this)) returns (uint256 r) {
                c = r;
            } catch {}
        }
        _processEarnings(f0, f1, c, split);
    }

    function _processEarnings(uint256 f0, uint256 f1, uint256 c, bool split) internal {
        if (c > 0 && cake == token0) (f0, c) = (f0 + c, 0);
        else if (c > 0 && cake == token1) (f1, c) = (f1 + c, 0);
        if (f0 == 0 && f1 == 0 && c == 0) return;

        (uint256 p0, uint256 p1, uint256 pc) = _takeProtocolFee(f0, f1, c);
        emit FeesCollected(f0, f1, c, p0, p1, pc);
        (f0, f1, c) = (f0 - p0, f1 - p1, c - pc);

        uint256 r = (split && _settings.autoCompound) ? _settings.reinvestBps : 0;
        uint256 i0 = (f0 * r) / BPS;
        uint256 i1 = (f1 * r) / BPS;
        uint256 ic = (c * r) / BPS;
        (idle0, idle1, idleCake) = (idle0 + i0, idle1 + i1, idleCake + ic);
        (claimable0, claimable1, claimableCake) = (claimable0 + f0 - i0, claimable1 + f1 - i1, claimableCake + c - ic);
    }

    /// @dev The protocol fee on earnings, taken from the BNB side of the pair (else a stablecoin side) when that
    ///      side alone covers it at a trusted price, so no low-value tokens end up in the treasury.
    function _takeProtocolFee(uint256 f0, uint256 f1, uint256 c) internal returns (uint256 p0, uint256 p1, uint256 pc) {
        uint256 rate = factory.feeBpsFor(owner);
        if (rate == 0) return (0, 0, 0);
        (p0, p1, pc) = ((f0 * rate) / BPS, (f1 * rate) / BPS, (c * rate) / BPS);

        bool pref1 = token1 == wbnb || (token0 != wbnb && factory.isStable(token1));
        bool pref0 = !pref1 && (token0 == wbnb || factory.isStable(token0));
        if ((pref1 && p0 > 0) || (pref0 && p1 > 0)) {
            _needGas(ORACLE_GAS);
            try IPriceOracle(factory.oracle()).checkPool(pool, factory.config().maxDeviationBps) returns (
                uint160 sqrtP, int24
            ) {
                if (pref1) {
                    uint256 v = _convert0to1(p0, sqrtP);
                    if (f1 - p1 >= v) (p1, p0) = (p1 + v, 0);
                } else {
                    uint256 v = _convert1to0(p1, sqrtP);
                    if (f0 - p0 >= v) (p0, p1) = (p0 + v, 0);
                }
            } catch {}
        }

        address router = factory.revenueRouter();
        uint256 n = (p0 > 0 ? 1 : 0) + (p1 > 0 ? 1 : 0) + (pc > 0 ? 1 : 0);
        if (n == 0) return (p0, p1, pc);
        address[] memory tokens = new address[](n);
        uint256[] memory amounts = new uint256[](n);
        uint256 k;
        if (p0 > 0) (tokens[k], amounts[k++]) = (token0, p0);
        if (p1 > 0) (tokens[k], amounts[k++]) = (token1, p1);
        if (pc > 0) (tokens[k], amounts[k++]) = (cake, pc);
        for (uint256 i; i < n; i++) {
            IERC20(tokens[i]).safeTransfer(router, amounts[i]);
        }
        IRevenueRouter(router).onFee(owner, tokens, amounts);
    }

    /// @dev Keeper gas is paid back from the vault's WBNB (fees first, then idle), capped by the factory.
    function _refundKeeper(uint256 gasStart) internal {
        if (!factory.isKeeper(msg.sender)) return;
        factory.recordKeeperAction();
        if (token0 != wbnb && token1 != wbnb) return;
        QudaoTypes.Config memory cfg = factory.config();
        uint256 price = tx.gasprice < cfg.maxKeeperGasPrice ? tx.gasprice : cfg.maxKeeperGasPrice;
        uint256 refund = (gasStart - gasleft() + cfg.keeperGasOverhead) * price;
        if (refund > cfg.maxKeeperRefund) refund = cfg.maxKeeperRefund;
        bool zero = token0 == wbnb;
        uint256 fromFees = zero ? claimable0 : claimable1;
        if (fromFees > refund) fromFees = refund;
        uint256 fromIdle = refund - fromFees;
        uint256 idleW = zero ? idle0 : idle1;
        if (fromIdle > idleW) fromIdle = idleW;
        if (zero) (claimable0, idle0) = (claimable0 - fromFees, idle0 - fromIdle);
        else (claimable1, idle1) = (claimable1 - fromFees, idle1 - fromIdle);
        uint256 paid = fromFees + fromIdle;
        if (paid > 0) {
            IERC20(wbnb).safeTransfer(msg.sender, paid);
            emit KeeperRefunded(msg.sender, paid);
        }
    }

    // ---------------------------------------------------------------- internals: swaps

    function _swapIdle(QudaoTypes.SwapStep[] calldata steps, uint160 sqrtP) internal {
        for (uint256 i; i < steps.length; i++) {
            QudaoTypes.SwapStep calldata s = steps[i];
            if (s.tokenOut != token0 && s.tokenOut != token1) revert BadSwap();
            if (s.amountIn > _idleOf(s.tokenIn)) revert BadSwap();
            (uint256 spent, uint256 out) = _runSwap(s, sqrtP);
            _subIdle(s.tokenIn, spent);
            if (s.tokenOut == token0) idle0 += out;
            else idle1 += out;
        }
    }

    function _runSwap(QudaoTypes.SwapStep calldata s, uint160 sqrtP) internal returns (uint256 spent, uint256 out) {
        if (s.tokenIn == s.tokenOut) revert BadSwap();
        if (s.tokenIn != token0 && s.tokenIn != token1 && s.tokenIn != cake) revert BadSwap();
        uint256 fair = _fairOut(s.tokenIn, s.tokenOut, s.amountIn, sqrtP);
        if (fair == 0) revert NoPrice();
        uint256 minOut = (fair * (BPS - _settings.slippageBps)) / BPS;
        address swapper = factory.swapper();
        uint256 before = IERC20(s.tokenIn).balanceOf(address(this));
        IERC20(s.tokenIn).forceApprove(swapper, s.amountIn);
        out = ISwapper(swapper).swap(s.tokenIn, s.tokenOut, s.amountIn, minOut, s.router, s.data);
        IERC20(s.tokenIn).forceApprove(swapper, 0);
        spent = before - IERC20(s.tokenIn).balanceOf(address(this));
        emit Swapped(s.tokenIn, s.tokenOut, spent, out);
    }

    function _fairOut(address tIn, address tOut, uint256 amountIn, uint160 sqrtP) internal view returns (uint256) {
        return VaultLogic.fairOut(IPriceOracle(factory.oracle()), _poolInfo(), tIn, tOut, amountIn, sqrtP);
    }

    function _poolInfo() internal view returns (VaultLogic.Pool memory) {
        return VaultLogic.Pool(token0, token1, tickSpacing);
    }

    function _idleOf(address t) internal view returns (uint256) {
        return t == token0 ? idle0 : t == token1 ? idle1 : t == cake ? idleCake : 0;
    }

    function _subIdle(address t, uint256 a) internal {
        if (t == token0) idle0 -= a;
        else if (t == token1) idle1 -= a;
        else idleCake -= a;
    }

    function _claimableOf(address t) internal view returns (uint256) {
        return t == token0 ? claimable0 : t == token1 ? claimable1 : t == cake ? claimableCake : 0;
    }

    function _subClaimable(address t, uint256 a) internal {
        if (t == token0) claimable0 -= a;
        else if (t == token1) claimable1 -= a;
        else claimableCake -= a;
    }

    // ---------------------------------------------------------------- internals: math & transfers

    function _convert0to1(uint256 a, uint160 sqrtP) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(a, sqrtP, Q96), sqrtP, Q96);
    }

    function _convert1to0(uint256 a, uint160 sqrtP) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(a, Q96, sqrtP), Q96, sqrtP);
    }

    function _sendOut(address token, uint256 amount, bool asNative) internal {
        if (amount == 0) return;
        if (asNative && token == wbnb) {
            IWBNB(wbnb).withdraw(amount);
            (bool ok,) = owner.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(owner, amount);
        }
    }
}
