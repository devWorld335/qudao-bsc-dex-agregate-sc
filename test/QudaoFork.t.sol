// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {QudaoDeploy} from "../script/QudaoDeploy.sol";
import {QudaoTypes} from "../src/interfaces/IQudao.sol";
import {IPancakeV3Pool, INonfungiblePositionManager, IMasterChefV3} from "../src/interfaces/external/IPancakeV3.sol";
import {IFlapPortal} from "../src/interfaces/external/IExternal.sol";
import {QudaoVault} from "../src/QudaoVault.sol";
import {QudaoFactory} from "../src/QudaoFactory.sol";
import {TheWell} from "../src/TheWell.sol";
import {BuybackBurner} from "../src/BuybackBurner.sol";
import {PriceOracle} from "../src/PriceOracle.sol";

interface ISmartRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256);
}

interface IPermit2Domain {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

contract MockQdao is ERC20 {
    constructor() ERC20("Qudao", "QDAO") {
        _mint(msg.sender, 1_000_000_000e18);
    }
}

/// @notice Runs against BNB Smart Chain mainnet state (real PancakeSwap v3, MasterChef v3, Chainlink, flap.sh).
contract QudaoForkTest is Test, QudaoDeploy {
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address constant POOL = 0x36696169C63e42cd08ce11f5deeBbCeBae652050; // USDT/WBNB 0.05%, CAKE farm
    address constant SMART_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    address constant NPM = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    address constant CHEF = 0x556B9306565093C855AEA9AE92A594704c2Cd59e;
    address constant PORTAL = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    Deployment d;
    address guardian = makeAddr("qudao.test.guardian");
    address keeper = makeAddr("qudao.test.keeper");
    address team = makeAddr("qudao.test.team");
    address alice = makeAddr("qudao.test.alice");
    address bob = makeAddr("qudao.test.bob");
    address whale = makeAddr("qudao.test.whale");

    function setUp() public {
        vm.createSelectFork(vm.envOr("BSC_RPC_URL", string("https://bsc-rpc.publicnode.com")));
        d = _deployQudao(Roles({owner: address(this), guardian: guardian, keeper: keeper, team: team}), "bsc", address(this));
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        deal(USDT, alice, 100_000e18);
        deal(USDT, bob, 100_000e18);
        deal(WBNB, whale, 100_000 ether);
        deal(USDT, whale, 100_000_000e18);
    }

    // ---------------------------------------------------------------- helpers

    function _settings() internal pure returns (QudaoTypes.Settings memory) {
        return QudaoTypes.Settings({
            strategy: QudaoTypes.Strategy.Static,
            waitForMarket: false,
            autoCompound: true,
            reinvestBps: 5000,
            slippageBps: 400
        });
    }

    function _tick() internal view returns (int24 tick) {
        (, tick,,,,,) = IPancakeV3Pool(POOL).slot0();
    }

    function _floor(int24 t, int24 s) internal pure returns (int24) {
        int24 r = t / s;
        if (t < 0 && t % s != 0) r--;
        return r * s;
    }

    function _emptyPermit() internal pure returns (ISignatureTransfer.PermitBatchTransferFrom memory p) {}

    /// @dev Opens USDT/WBNB with `bnb` native BNB on the WBNB side and enough USDT for the other side.
    function _open(address user, int24 halfWidth, uint256 bnb, bytes8 code) internal returns (QudaoVault v) {
        int24 tick = _tick();
        QudaoTypes.OpenParams memory p = QudaoTypes.OpenParams({
            token0: USDT,
            token1: WBNB,
            fee: 500,
            tickLower: _floor(tick - halfWidth, 10),
            tickUpper: _floor(tick + halfWidth, 10) + 10,
            amount0: bnb * 1000, // more USDT than needed; the rest comes back
            amount1: bnb,
            amount0Min: 0,
            amount1Min: 0,
            createPoolSqrtPriceX96: 0,
            settings: _settings(),
            referralCode: code,
            deadline: block.timestamp + 1 hours
        });
        vm.startPrank(user);
        IERC20(USDT).approve(address(d.factory), type(uint256).max);
        (address vault,,) = d.factory.openPosition{value: bnb}(p, _emptyPermit(), "");
        vm.stopPrank();
        v = QudaoVault(payable(vault));
    }

    function _routerSwap(address tokenIn, address tokenOut, uint256 amountIn, address recipient)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(
            ISmartRouter.exactInputSingle,
            (ISmartRouter.ExactInputSingleParams(tokenIn, tokenOut, 500, recipient, amountIn, 0, 0))
        );
    }

    /// @dev Trades back and forth through the pool to generate fees (net price change ≈ 0).
    function _volume(uint256 rounds, uint256 bnbPerRound) internal {
        vm.startPrank(whale);
        IERC20(WBNB).approve(SMART_ROUTER, type(uint256).max);
        IERC20(USDT).approve(SMART_ROUTER, type(uint256).max);
        for (uint256 i; i < rounds; i++) {
            uint256 got = ISmartRouter(SMART_ROUTER).exactInputSingle(
                ISmartRouter.ExactInputSingleParams(WBNB, USDT, 500, whale, bnbPerRound, 0, 0)
            );
            ISmartRouter(SMART_ROUTER).exactInputSingle(
                ISmartRouter.ExactInputSingleParams(USDT, WBNB, 500, whale, got, 0, 0)
            );
        }
        vm.stopPrank();
    }

    function _pushPrice(bool up, uint256 chunk, int24 untilTick) internal {
        vm.startPrank(whale);
        IERC20(WBNB).approve(SMART_ROUTER, type(uint256).max);
        IERC20(USDT).approve(SMART_ROUTER, type(uint256).max);
        for (uint256 i; i < 60; i++) {
            int24 t = _tick();
            if (up ? t >= untilTick : t < untilTick) break;
            if (up) {
                // selling WBNB (token1) for USDT raises token1-per-token0 → tick up
                ISmartRouter(SMART_ROUTER).exactInputSingle(
                    ISmartRouter.ExactInputSingleParams(WBNB, USDT, 500, whale, chunk, 0, 0)
                );
            } else {
                ISmartRouter(SMART_ROUTER).exactInputSingle(
                    ISmartRouter.ExactInputSingleParams(USDT, WBNB, 500, whale, chunk * 600, 0, 0)
                );
            }
        }
        vm.stopPrank();
    }

    function _looseOracle() internal {
        QudaoTypes.Config memory c = d.factory.config();
        c.maxDeviationBps = 2000;
        c.minReinvestBps = 0;
        d.factory.setConfig(c);
    }

    // ---------------------------------------------------------------- open

    function test_OpenWithNativeBnb_StakesInFarm() public {
        uint256 usdtBefore = IERC20(USDT).balanceOf(alice);
        QudaoVault v = _open(alice, 300, 1 ether, bytes8(0));
        assertEq(v.owner(), alice);
        assertTrue(v.tokenId() != 0, "position minted");
        assertTrue(v.staked(), "staked in MasterChef v3");
        assertEq(INonfungiblePositionManager(NPM).ownerOf(v.tokenId()), CHEF);
        (int24 lo, int24 hi, uint128 liq) = v.range();
        assertTrue(liq > 0 && lo < _tick() && _tick() < hi);
        // only what the range needed was taken; the rest of the USDT came back
        uint256 usdtSpent = usdtBefore - IERC20(USDT).balanceOf(alice);
        assertTrue(usdtSpent > 0 && usdtSpent < 1000e18);
        assertEq(IERC20(USDT).balanceOf(address(v)), 0);
        assertTrue(d.factory.hasUsed(alice));
        assertEq(d.factory.vaultsOf(alice)[0], address(v));
    }

    /// Wallets pick the lowest gas that doesn't revert. No gas limit may open a position that skips the farm.
    function test_NoGasLimitSkipsTheFarm() public {
        int24 tick = _tick();
        QudaoTypes.OpenParams memory p = QudaoTypes.OpenParams({
            token0: USDT,
            token1: WBNB,
            fee: 500,
            tickLower: _floor(tick - 300, 10),
            tickUpper: _floor(tick + 300, 10) + 10,
            amount0: 1000e18,
            amount1: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            createPoolSqrtPriceX96: 0,
            settings: _settings(),
            referralCode: bytes8(0),
            deadline: block.timestamp + 1 hours
        });
        vm.prank(alice);
        IERC20(USDT).approve(address(d.factory), type(uint256).max);
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        uint256 g0 = gasleft();
        d.factory.openPosition{value: 1 ether}(p, _emptyPermit(), "");
        uint256 used = g0 - gasleft();
        uint256 succeeded;
        // the guard needs headroom above what is actually used, so the minimum lies somewhat above `used`
        for (uint256 gas = used - 700_000; gas <= used + 500_000; gas += 25_000) {
            vm.revertToState(snap);
            vm.prank(alice);
            try d.factory.openPosition{value: 1 ether, gas: gas}(p, _emptyPermit(), "") returns (address vault, uint256, uint128) {
                succeeded++;
                assertTrue(QudaoVault(payable(vault)).staked(), "a successful open always stakes in the farm");
            } catch {}
        }
        assertTrue(succeeded > 0, "some limit in the sweep succeeds");
    }

    function test_OpenRejectsBadRangeAndPaused() public {
        vm.prank(guardian);
        d.factory.setPaused(true);
        vm.expectRevert(QudaoFactory.IsPaused.selector);
        this.openFor(alice, 300);
        vm.prank(guardian);
        d.factory.setPaused(false);
        vm.expectRevert(); // narrower than the 200-tick minimum
        this.openFor(alice, 50);
    }

    function openFor(address user, int24 hw) external returns (QudaoVault) {
        return _open(user, hw, 1 ether, bytes8(0));
    }

    // ---------------------------------------------------------------- fees, protocol fee, CAKE, reinvest

    function test_FeesCakeAndReinvest() public {
        QudaoVault v = _open(alice, 400, 5 ether, bytes8(0));
        (,, uint128 liqBefore) = v.range();
        skip(2 hours);
        _volume(6, 300 ether);

        _looseOracle();
        uint256 routerWbnb = IERC20(WBNB).balanceOf(address(d.router));
        uint256 routerCake = IERC20(CAKE).balanceOf(address(d.router));
        vm.prank(keeper);
        v.reinvest(new QudaoTypes.SwapStep[](0));

        assertTrue(IERC20(WBNB).balanceOf(address(d.router)) > routerWbnb, "protocol fee taken from the BNB side");
        assertTrue(IERC20(CAKE).balanceOf(address(d.router)) > routerCake, "protocol fee on CAKE");
        assertTrue(v.claimable0() + v.claimable1() > 0, "half the fees wait for the owner");
        assertTrue(v.claimableCake() > 0, "CAKE share claimable");
        (,, uint128 liqAfter) = v.range();
        assertTrue(liqAfter > liqBefore, "reinvested share added to the position");
        assertTrue(d.factory.lastKeeperAction() == block.timestamp);
    }

    function test_ReinvestOnlyByAutomation() public {
        QudaoVault v = _open(alice, 400, 1 ether, bytes8(0));
        vm.prank(bob);
        vm.expectRevert(QudaoVault.NotAllowed.selector);
        v.reinvest(new QudaoTypes.SwapStep[](0));
        // once the keeper is silent past the grace period, anyone may trigger a due action
        skip(d.factory.config().keeperGrace + 1);
        assertTrue(d.factory.keeperStale());
    }

    // ---------------------------------------------------------------- rebalance

    function test_RebalanceStaticRange() public {
        QudaoVault v = _open(alice, 150, 5 ether, bytes8(0));
        (int24 lo, int24 hi,) = v.range();
        uint256 oldId = v.tokenId();
        _looseOracle();
        skip(11 minutes);

        vm.prank(keeper);
        vm.expectRevert(QudaoVault.StillInRange.selector);
        v.rebalance(lo, hi, new QudaoTypes.SwapStep[](0));

        _pushPrice(true, 500 ether, hi + 20);
        int24 tick = _tick();
        assertTrue(tick >= hi, "price left the range");
        skip(11 minutes);

        // the position is now all WBNB: swap a bit under half of it to USDT for the new range
        (, uint256 amt1) = v.positionAmounts();
        QudaoTypes.SwapStep[] memory steps = new QudaoTypes.SwapStep[](1);
        steps[0] = QudaoTypes.SwapStep(
            WBNB, USDT, (amt1 * 45) / 100, SMART_ROUTER, _routerSwap(WBNB, USDT, (amt1 * 45) / 100, address(d.swapper))
        );
        int24 newLo = _floor(tick + v.lowerOffset(), 10);
        int24 newHi = _floor(tick + v.upperOffset(), 10);

        // a range that ignores the static distances is refused
        vm.prank(keeper);
        vm.expectRevert();
        v.rebalance(newLo - 200, newHi, steps);

        vm.txGasPrice(1 gwei);
        uint256 keeperBefore = IERC20(WBNB).balanceOf(keeper);
        vm.prank(keeper);
        v.rebalance(newLo, newHi, steps);

        (int24 lo2, int24 hi2, uint128 liq2) = v.range();
        assertEq(lo2, newLo);
        assertEq(hi2, newHi);
        assertTrue(liq2 > 0 && v.tokenId() != oldId && v.staked());
        assertTrue(IERC20(WBNB).balanceOf(keeper) > keeperBefore, "keeper gas refunded from the vault");
        assertTrue(IERC20(WBNB).balanceOf(keeper) - keeperBefore <= 0.0005 ether, "refund capped");

        skip(11 minutes);
        vm.prank(keeper);
        vm.expectRevert(QudaoVault.StillInRange.selector);
        v.rebalance(newLo, newHi, new QudaoTypes.SwapStep[](0));
    }

    function test_OracleRejectsMovedPrice() public {
        QudaoVault v = _open(alice, 150, 5 ether, bytes8(0));
        (, int24 hi,) = v.range();
        _pushPrice(true, 1000 ether, hi + 300); // pool now ≈3% away from Chainlink
        skip(11 minutes);
        bytes memory expected = abi.encodeWithSelector(PriceOracle.PriceDeviates.selector, POOL, _tick(), _chainlinkTick());
        vm.prank(keeper);
        vm.expectRevert(expected);
        v.rebalance(hi, hi + 300, new QudaoTypes.SwapStep[](0));
    }

    function _chainlinkTick() internal view returns (int24 t) {
        (, t) = d.oracle.referenceTick(POOL);
    }

    // ---------------------------------------------------------------- claim, close, pause

    function test_ClaimCloseAndPause() public {
        QudaoVault v = _open(alice, 400, 3 ether, bytes8(0));
        skip(1 hours);
        _volume(4, 300 ether);

        uint256 u0 = IERC20(USDT).balanceOf(alice);
        uint256 w0 = IERC20(WBNB).balanceOf(alice);
        vm.prank(alice);
        (uint256 a0, uint256 a1, uint256 c) = v.claim();
        assertTrue(a0 + a1 > 0 && c > 0, "fees and CAKE claimed");
        assertEq(IERC20(USDT).balanceOf(alice) - u0, a0);
        assertEq(IERC20(WBNB).balanceOf(alice) - w0, a1);

        vm.prank(guardian);
        d.factory.setPaused(true);
        _looseOracle();
        vm.prank(keeper);
        vm.expectRevert(QudaoVault.Paused.selector);
        v.reinvest(new QudaoTypes.SwapStep[](0));

        // closing always works, also while paused
        vm.prank(alice);
        v.close(0, 0);
        assertTrue(v.closed());
        assertEq(v.tokenId(), 0);
        assertEq(IERC20(USDT).balanceOf(address(v)), 0);
        assertEq(IERC20(WBNB).balanceOf(address(v)), 0);
        assertTrue(IERC20(WBNB).balanceOf(alice) > w0 + 2 ether, "principal returned");
    }

    function test_OnlyOwnerWithdraws() public {
        QudaoVault v = _open(alice, 400, 1 ether, bytes8(0));
        vm.startPrank(keeper);
        vm.expectRevert(QudaoVault.OnlyOwner.selector);
        v.close(0, 0);
        vm.expectRevert(QudaoVault.OnlyOwner.selector);
        v.claim();
        vm.expectRevert(QudaoVault.OnlyOwner.selector);
        v.withdraw(1, 0, 0);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- referrals

    function test_ReferralDiscountAndReward() public {
        vm.prank(bob);
        d.referrals.register(bytes8("qudao001"));
        uint256 baseFee = d.factory.feeBpsFor(alice);
        QudaoVault v = _open(alice, 400, 5 ether, bytes8("qudao001"));
        assertEq(d.referrals.referrerOf(alice), bob);
        assertEq(d.factory.feeBpsFor(alice), (baseFee * 9000) / 10_000, "invitee pays 10% less");

        _volume(6, 300 ether);
        _looseOracle();
        vm.prank(keeper);
        v.reinvest(new QudaoTypes.SwapStep[](0));
        uint256 owed = d.router.referralBnb(bob);
        assertTrue(owed > 0, "referrer credited in BNB");

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        d.router.claimReferral(new address[](0));
        assertEq(bob.balance - bobBefore, owed);

        // a code only counts for a wallet's first position, and never for yourself
        vm.prank(alice);
        d.referrals.register(bytes8("alice123"));
        QudaoVault v2 = _open(bob, 400, 1 ether, bytes8("alice123"));
        assertEq(d.referrals.referrerOf(bob), alice, "bob had never used Qudao");
        v2;
    }

    // ---------------------------------------------------------------- revenue split + The Well

    function test_DistributeAndStake() public {
        MockQdao qdao = new MockQdao();
        vm.startPrank(guardian);
        d.well.setToken(IERC20(address(qdao)));
        d.router.setQdao(IERC20(address(qdao)));
        d.burner.setQdao(IERC20(address(qdao)));
        vm.stopPrank();

        qdao.transfer(alice, 300_000e18);
        vm.startPrank(alice);
        qdao.approve(address(d.well), type(uint256).max);
        d.well.stake(300_000e18);
        vm.stopPrank();
        assertEq(d.well.discountBpsOf(alice), 600, "200k+ row, right away column");

        vm.deal(address(d.router), 10 ether);
        d.router.distribute();
        assertEq(address(d.burner).balance, 3.5 ether);
        assertEq(address(d.safetyFund).balance, 1.5 ether);
        assertEq(team.balance, 1.5 ether);
        assertEq(address(d.boostReserve).balance, 0.5 ether);
        assertEq(address(d.well).balance, 3 ether);

        skip(15 days);
        assertApproxEqRel(d.well.earned(alice), 1.5 ether, 0.001e18, "half the 30-day stream");
        uint256 before = alice.balance;
        vm.prank(alice);
        d.well.claim();
        assertApproxEqRel(alice.balance - before, 1.5 ether, 0.001e18);

        skip(16 days);
        assertEq(d.well.discountBpsOf(alice), 1000, "1-month column");
        // doubling the stake halves the time staked
        qdao.transfer(alice, 300_000e18);
        vm.prank(alice);
        d.well.stake(300_000e18);
        (, uint64 since,,,) = d.well.accounts(alice);
        assertApproxEqAbs(block.timestamp - since, 31 days / 2, 1);
    }

    function test_WellStreamWaitsWhileNobodyStakes() public {
        MockQdao qdao = new MockQdao();
        vm.prank(guardian);
        d.well.setToken(IERC20(address(qdao)));
        d.well.notifyReward{value: 3 ether}();
        skip(10 days); // nobody staked: nothing is lost
        qdao.approve(address(d.well), type(uint256).max);
        d.well.stake(1000e18);
        skip(30 days);
        assertApproxEqRel(d.well.earned(address(this)), 3 ether, 0.001e18);
    }

    receive() external payable {}

    // ---------------------------------------------------------------- in-app swap fee

    function test_SwapForUserTakesFee() public {
        bytes memory data = _routerSwap(WBNB, USDT, 1 ether, address(d.swapper));
        uint256 before = IERC20(USDT).balanceOf(alice);
        vm.prank(alice);
        uint256 got = d.swapper.swapForUser{value: 1 ether}(address(0), USDT, 1 ether, 1, SMART_ROUTER, data, alice);
        assertEq(IERC20(USDT).balanceOf(alice) - before, got);
        uint256 fee = IERC20(USDT).balanceOf(address(d.router));
        assertApproxEqAbs(fee, ((got + fee) * 15) / 10_000, 1, "0.15% of the output");

        // a router that isn't whitelisted is refused
        vm.prank(alice);
        vm.expectRevert();
        d.swapper.swapForUser{value: 1 ether}(address(0), USDT, 1 ether, 1, address(0xBEEF), data, alice);
    }

    // ---------------------------------------------------------------- buyback & burn

    function test_BuybackOnFlapCurve() public {
        // any token currently trading on its flap.sh bonding curve stands in for QDAO before graduation
        address curveToken = vm.envOr("FLAP_CURVE_TOKEN", address(0x65360A563dBfEB08739C78b30b5E64B5980D7777));
        IFlapPortal.TokenStateV8 memory s = IFlapPortal(PORTAL).getTokenV8Safe(curveToken);
        if (s.status != 1) {
            vm.skip(true);
            return;
        }
        vm.prank(guardian);
        d.burner.setQdao(IERC20(curveToken));
        vm.deal(address(d.burner), 0.05 ether);

        vm.prank(keeper);
        d.burner.arm();
        vm.prank(keeper);
        vm.expectRevert(BuybackBurner.TooEarly.selector);
        d.burner.execute(address(0), "");
        skip(61);
        uint256 deadBefore = IERC20(curveToken).balanceOf(DEAD);
        vm.prank(keeper);
        uint256 burned = d.burner.execute(address(0), "");
        assertTrue(burned > 0);
        assertEq(IERC20(curveToken).balanceOf(DEAD) - deadBefore, burned);
        assertEq(address(d.burner).balance, 0);
    }

    function test_BuybackOnPancakeAfterGraduation() public {
        // a fresh QDAO/WBNB v3 pool stands in for QDAO after graduation
        MockQdao qdao = new MockQdao();
        (address t0, address t1) = address(qdao) < WBNB ? (address(qdao), WBNB) : (WBNB, address(qdao));
        // 1 BNB = 100,000 QDAO
        uint256 q96 = 1 << 96;
        uint160 sqrtP = address(qdao) < WBNB ? uint160(q96 / 316) : uint160(q96 * 316);
        INonfungiblePositionManager npm = INonfungiblePositionManager(NPM);
        address pool = npm.createAndInitializePoolIfNecessary(t0, t1, 2500, sqrtP);
        IERC20(address(qdao)).approve(NPM, type(uint256).max);
        deal(WBNB, address(this), 100 ether);
        IERC20(WBNB).approve(NPM, type(uint256).max);
        npm.mint(
            INonfungiblePositionManager.MintParams(
                t0, t1, 2500, -887200, 887200, t0 == WBNB ? 50 ether : 5_000_000e18, t0 == WBNB ? 5_000_000e18 : 50 ether, 0, 0, address(this), block.timestamp
            )
        );
        IFlapPortal.TokenStateV8 memory s;
        s.status = 4;
        s.pool = pool;
        vm.mockCall(PORTAL, abi.encodeWithSelector(IFlapPortal.getTokenV8Safe.selector, address(qdao)), abi.encode(s));

        vm.prank(guardian);
        d.burner.setQdao(IERC20(address(qdao)));
        vm.deal(address(d.burner), 2 ether);
        skip(7 hours);

        vm.prank(keeper);
        d.burner.arm();
        (uint128 amountIn,,,) = d.burner.armed();
        assertEq(amountIn, 0.5 ether, "capped per buy");
        skip(61);
        bytes memory data = abi.encodeCall(
            ISmartRouter.exactInputSingle,
            (ISmartRouter.ExactInputSingleParams(WBNB, address(qdao), 2500, address(d.swapper), amountIn, 0, 0))
        );
        vm.prank(keeper);
        uint256 burned = d.burner.execute(SMART_ROUTER, data);
        assertTrue(burned > 40_000e18, "about 50k QDAO for 0.5 BNB");
        assertEq(qdao.balanceOf(DEAD), burned);
        assertEq(address(d.burner).balance, 1.5 ether, "the rest waits for the next buy");

        vm.prank(keeper);
        vm.expectRevert(BuybackBurner.NothingToBuy.selector);
        d.burner.arm(); // 6h between DEX buys
    }

    // ---------------------------------------------------------------- more vault features

    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant STABLE_POOL = 0x92b7807bF19b7DDdf89b706143896d05228f3121; // USDT/USDC 0.01%

    function _permitSig(uint256 pk, address token, uint256 amount, address spender, uint256 nonce, uint256 deadline)
        internal
        view
        returns (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory sig)
    {
        ISignatureTransfer.TokenPermissions[] memory perms = new ISignatureTransfer.TokenPermissions[](1);
        perms[0] = ISignatureTransfer.TokenPermissions(token, amount);
        permit = ISignatureTransfer.PermitBatchTransferFrom(perms, nonce, deadline);
        bytes32 tokenHash = keccak256(
            abi.encode(keccak256("TokenPermissions(address token,uint256 amount)"), token, amount)
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "PermitBatchTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
                ),
                keccak256(abi.encodePacked(tokenHash)),
                spender,
                nonce,
                deadline
            )
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", IPermit2Domain(PERMIT2).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s_) = vm.sign(pk, digest);
        sig = abi.encodePacked(r, s_, v);
    }

    function test_OpenWithPermit2Signature() public {
        (address carol, uint256 pk) = makeAddrAndKey("qudao.test.carol");
        vm.deal(carol, 5 ether);
        deal(USDT, carol, 10_000e18);
        vm.prank(carol);
        IERC20(USDT).approve(PERMIT2, type(uint256).max); // one-time Permit2 approval

        int24 tick = _tick();
        QudaoTypes.OpenParams memory p = QudaoTypes.OpenParams({
            token0: USDT,
            token1: WBNB,
            fee: 500,
            tickLower: _floor(tick - 400, 10),
            tickUpper: _floor(tick + 400, 10) + 10,
            amount0: 1000e18,
            amount1: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            createPoolSqrtPriceX96: 0,
            settings: _settings(),
            referralCode: bytes8(0),
            deadline: block.timestamp + 30 minutes
        });
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory sig) =
            _permitSig(pk, USDT, 1000e18, address(d.factory), 7, block.timestamp + 30 minutes);
        vm.prank(carol);
        (address vault, uint256 id,) = d.factory.openPosition{value: 1 ether}(p, permit, sig);
        assertTrue(id != 0 && QudaoVault(payable(vault)).staked());
        assertEq(IERC20(USDT).allowance(carol, address(d.factory)), 0, "no approval to Qudao needed");

        // the same signature can't be used twice
        vm.prank(carol);
        vm.expectRevert();
        d.factory.openPosition{value: 1 ether}(p, permit, sig);
    }

    function test_CreatePoolAndOpen() public {
        MockQdao token = new MockQdao();
        token.transfer(alice, 1_000_000e18);
        (address t0, address t1) = address(token) < USDT ? (address(token), USDT) : (USDT, address(token));
        uint256 q96 = 1 << 96;
        // 1 TOKEN = 0.01 USDT
        uint160 sqrtP = t0 == address(token) ? uint160(q96 / 10) : uint160(q96 * 10);
        int24 tick = t0 == address(token) ? int24(-46055) : int24(46054);
        QudaoTypes.OpenParams memory p = QudaoTypes.OpenParams({
            token0: t0,
            token1: t1,
            fee: 2500,
            tickLower: _floor(tick - 2000, 50),
            tickUpper: _floor(tick + 2000, 50),
            amount0: t0 == USDT ? 1000e18 : 100_000e18,
            amount1: t1 == USDT ? 1000e18 : 100_000e18,
            amount0Min: 0,
            amount1Min: 0,
            createPoolSqrtPriceX96: sqrtP,
            settings: _settings(),
            referralCode: bytes8(0),
            deadline: block.timestamp + 1 hours
        });
        vm.startPrank(alice);
        IERC20(USDT).approve(address(d.factory), type(uint256).max);
        token.approve(address(d.factory), type(uint256).max);
        (address vault, uint256 id, uint128 liq) = d.factory.openPosition(p, _emptyPermit(), "");
        vm.stopPrank();
        assertTrue(id != 0 && liq > 0, "pool created and first position opened in one transaction");
        assertFalse(QudaoVault(payable(vault)).staked(), "a new pool has no farm");
    }

    function test_AddWithdrawCompoundClaimAsBnb() public {
        QudaoVault v = _open(alice, 400, 3 ether, bytes8(0));
        (,, uint128 l0) = v.range();

        vm.prank(alice);
        d.factory.addFunds{value: 1 ether}(address(v), 1000e18, 1 ether, 0, 0, _emptyPermit(), "");
        (,, uint128 l1) = v.range();
        assertTrue(l1 > l0, "funds added to the same range");

        vm.prank(bob);
        vm.expectRevert(QudaoFactory.OnlyVault.selector);
        d.factory.addFunds{value: 1 ether}(address(v), 0, 1 ether, 0, 0, _emptyPermit(), "");

        uint256 wBefore = IERC20(WBNB).balanceOf(alice);
        vm.prank(alice);
        v.withdraw(l1 / 2, 0, 0);
        (,, uint128 l2) = v.range();
        assertEq(l2, l1 - l1 / 2);
        assertTrue(IERC20(WBNB).balanceOf(alice) > wBefore, "principal taken out");

        _volume(4, 300 ether);
        vm.prank(alice);
        v.compound(new QudaoTypes.SwapStep[](0));
        assertEq(v.claimable0() + v.claimable1(), 0, "all fees went back in");

        _volume(4, 300 ether);
        vm.prank(alice);
        v.claim(); // flush, then earn a little more
        _volume(4, 300 ether);
        skip(10 minutes);
        _volume(1, 1 ether);
        // collect so we know how much USDT is waiting, then claim it all as BNB
        vm.prank(alice);
        v.compound(new QudaoTypes.SwapStep[](0));
        _volume(4, 300 ether);
        uint256 bnbBefore = alice.balance;
        // the swap amount must not exceed claimable USDT after collecting: use a conservative 1 wei-level step
        QudaoTypes.SwapStep[] memory steps = new QudaoTypes.SwapStep[](0);
        vm.prank(alice);
        uint256 bnb = v.claimAsBNB(steps);
        assertTrue(bnb > 0 && alice.balance - bnbBefore == bnb, "WBNB fees arrive as native BNB");
    }

    function test_DynamicStrategyBounds() public {
        int24 tick = _tick();
        QudaoTypes.Settings memory s = _settings();
        s.strategy = QudaoTypes.Strategy.WidenWhenVolatile;
        QudaoTypes.OpenParams memory p = QudaoTypes.OpenParams({
            token0: USDT,
            token1: WBNB,
            fee: 500,
            tickLower: _floor(tick - 150, 10),
            tickUpper: _floor(tick + 150, 10) + 10,
            amount0: 5000e18,
            amount1: 5 ether,
            amount0Min: 0,
            amount1Min: 0,
            createPoolSqrtPriceX96: 0,
            settings: s,
            referralCode: bytes8(0),
            deadline: block.timestamp + 1 hours
        });
        vm.startPrank(alice);
        IERC20(USDT).approve(address(d.factory), type(uint256).max);
        (address vault,,) = d.factory.openPosition{value: 5 ether}(p, _emptyPermit(), "");
        vm.stopPrank();
        QudaoVault v = QudaoVault(payable(vault));
        int24 w = v.initialWidth();
        _looseOracle();
        (, int24 hi,) = v.range();
        _pushPrice(true, 500 ether, hi + 20);
        skip(11 minutes);
        int24 t = _tick();

        vm.prank(keeper);
        vm.expectRevert(); // more than twice the starting width
        v.rebalance(_floor(t - w * 2, 10), _floor(t + w * 2, 10), new QudaoTypes.SwapStep[](0));

        (, uint256 amt1) = v.positionAmounts();
        QudaoTypes.SwapStep[] memory steps = new QudaoTypes.SwapStep[](1);
        steps[0] = QudaoTypes.SwapStep(
            WBNB, USDT, (amt1 * 45) / 100, SMART_ROUTER, _routerSwap(WBNB, USDT, (amt1 * 45) / 100, address(d.swapper))
        );
        int24 lo2 = _floor(t - (w * 3) / 4, 10);
        int24 hi2 = _floor(t + (w * 3) / 4, 10);
        vm.prank(keeper);
        v.rebalance(lo2, hi2, steps); // 1.5× wider: allowed
        (int24 a, int24 b,) = v.range();
        assertEq(b - a, hi2 - lo2);
    }

    function test_ConvertStableRevenueAndReferralCredits() public {
        vm.prank(bob);
        d.referrals.register(bytes8("bobcode1"));
        deal(USDC, alice, 50_000e18);
        deal(USDC, whale, 50_000_000e18);
        (, int24 tick,,,,,) = IPancakeV3Pool(STABLE_POOL).slot0();
        QudaoTypes.OpenParams memory p = QudaoTypes.OpenParams({
            token0: USDT,
            token1: USDC,
            fee: 100,
            tickLower: tick - 200,
            tickUpper: tick + 201,
            amount0: 20_000e18,
            amount1: 20_000e18,
            amount0Min: 0,
            amount1Min: 0,
            createPoolSqrtPriceX96: 0,
            settings: _settings(),
            referralCode: bytes8("bobcode1"),
            deadline: block.timestamp + 1 hours
        });
        vm.startPrank(alice);
        IERC20(USDT).approve(address(d.factory), type(uint256).max);
        IERC20(USDC).approve(address(d.factory), type(uint256).max);
        (address vault,,) = d.factory.openPosition(p, _emptyPermit(), "");
        vm.stopPrank();

        vm.startPrank(whale);
        IERC20(USDT).approve(SMART_ROUTER, type(uint256).max);
        IERC20(USDC).approve(SMART_ROUTER, type(uint256).max);
        for (uint256 i; i < 6; i++) {
            uint256 got = ISmartRouter(SMART_ROUTER).exactInputSingle(
                ISmartRouter.ExactInputSingleParams(USDT, USDC, 100, whale, 2_000_000e18, 0, 0)
            );
            ISmartRouter(SMART_ROUTER).exactInputSingle(ISmartRouter.ExactInputSingleParams(USDC, USDT, 100, whale, got, 0, 0));
        }
        vm.stopPrank();

        _looseOracle();
        vm.prank(keeper);
        QudaoVault(payable(vault)).reinvest(new QudaoTypes.SwapStep[](0));
        uint256 usdcFees = IERC20(USDC).balanceOf(address(d.router));
        assertTrue(usdcFees > 0, "fee taken from the stablecoin side");
        assertTrue(d.router.pendingReferralToken(USDC) > 0, "referral credit waits for conversion");

        // keeper converts the router's USDC to WBNB (USDC/WBNB 0.01% pool), with a Chainlink floor
        bytes memory data = abi.encodeCall(
            ISmartRouter.exactInputSingle,
            (ISmartRouter.ExactInputSingleParams(USDC, WBNB, 100, address(d.swapper), usdcFees, 0, 0))
        );
        vm.prank(keeper);
        uint256 out = d.router.convert(USDC, 0, SMART_ROUTER, data);
        assertTrue(out > 0);
        assertEq(d.router.pendingReferralToken(USDC), 0);

        address[] memory toks = new address[](1);
        toks[0] = USDC;
        uint256 claimable = d.router.claimableReferral(bob, toks);
        assertApproxEqRel(claimable, (out * 2000) / 10_000, 0.001e18, "20% of the converted fee");
        uint256 before = bob.balance;
        vm.prank(bob);
        d.router.claimReferral(toks);
        assertEq(bob.balance - before, claimable);
    }
}
