// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {QudaoTypes} from "../src/interfaces/IQudao.sol";
import {QudaoFactory} from "../src/QudaoFactory.sol";
import {Swapper} from "../src/Swapper.sol";
import {IPancakeV3Pool} from "../src/interfaces/external/IPancakeV3.sol";
import {IWBNB} from "../src/interfaces/external/IExternal.sol";

interface ISmartRouterT {
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

/// @notice Testnet scenario: open a position with tBNB in any WBNB pool, and push a pool's price to test the
///         keeper. Works on BSC testnet and on an anvil fork of it.
///   QUDAO_DEPLOYMENT_FILE=deployments/bsc_testnet.json POOL=0x… BNB=0.02 HALF_WIDTH=100 \
///   forge script script/TestnetScenario.s.sol --sig "open()" --rpc-url <rpc> --broadcast --private-key <user key>
///   POOL=0x… PUSH_TICKS=150 CHUNK=0.01 forge script … --sig "push()" …
contract TestnetScenario is Script {
    using stdJson for string;

    address constant WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;

    function _d() internal view returns (string memory) {
        return vm.readFile(vm.envOr("QUDAO_DEPLOYMENT_FILE", string.concat(vm.projectRoot(), "/deployments/bsc_testnet.json")));
    }

    function _router() internal view returns (address) {
        string memory c = vm.readFile(string.concat(vm.projectRoot(), "/config/chains.json"));
        return c.readAddress(".bsc_testnet.pancake.smartRouter");
    }

    function _pool() internal view returns (IPancakeV3Pool) {
        return IPancakeV3Pool(vm.envOr("POOL", address(0x2dbB5a4c235164B9f772179A43faca2c71a8abDB))); // WBNB/USDT 0.05%
    }

    function _tick(IPancakeV3Pool p) internal view returns (int24 t) {
        (, t,,,,,) = p.slot0();
    }

    function _floor(int24 t, int24 s) internal pure returns (int24) {
        int24 r = t / s;
        if (t < 0 && t % s != 0) r--;
        return r * s;
    }

    function open() external {
        string memory d = _d();
        QudaoFactory factory = QudaoFactory(d.readAddress(".factory"));
        Swapper swapper = Swapper(payable(d.readAddress(".swapper")));
        IPancakeV3Pool pool = _pool();
        address t0 = pool.token0();
        address t1 = pool.token1();
        require(t0 == WBNB || t1 == WBNB, "pool needs WBNB on one side");
        address other = t0 == WBNB ? t1 : t0;
        uint24 fee = pool.fee();
        int24 spacing = pool.tickSpacing();
        uint256 bnb = vm.envOr("BNB", uint256(0.02 ether));
        int24 half = int24(int256(vm.envOr("HALF_WIDTH", uint256(100))));

        vm.startBroadcast();
        (, address user,) = vm.readCallers();
        // half the BNB → the other token, through Qudao's in-app swap
        bytes memory data = abi.encodeCall(
            ISmartRouterT.exactInputSingle, (ISmartRouterT.ExactInputSingleParams(WBNB, other, fee, address(swapper), bnb / 2, 0, 0))
        );
        uint256 got = swapper.swapForUser{value: bnb / 2}(address(0), other, bnb / 2, 1, _router(), data, user);
        IERC20(other).approve(address(factory), type(uint256).max);
        int24 tick = _tick(pool);
        QudaoTypes.OpenParams memory p = QudaoTypes.OpenParams({
            token0: t0,
            token1: t1,
            fee: fee,
            tickLower: _floor(tick - half, spacing),
            tickUpper: _floor(tick + half, spacing) + spacing,
            amount0: t0 == WBNB ? bnb / 2 : got,
            amount1: t1 == WBNB ? bnb / 2 : got,
            amount0Min: 0,
            amount1Min: 0,
            createPoolSqrtPriceX96: 0,
            settings: QudaoTypes.Settings({
                strategy: QudaoTypes.Strategy.Static,
                waitForMarket: false,
                autoCompound: true,
                reinvestBps: 5000,
                slippageBps: 400
            }),
            referralCode: bytes8(0),
            deadline: block.timestamp + 1 hours
        });
        ISignatureTransfer.PermitBatchTransferFrom memory empty;
        (address vault, uint256 id,) = factory.openPosition{value: bnb / 2}(p, empty, "");
        vm.stopBroadcast();
        console2.log("vault", vault);
        console2.log("tokenId", id);
        console2.log("tick", tick);
        console2.log("received from swap", got);
    }

    /// @notice Sells WBNB into the pool (or buys it, with UP=false) until the tick has moved PUSH_TICKS.
    function push() external {
        IPancakeV3Pool pool = _pool();
        address other = pool.token0() == WBNB ? pool.token1() : pool.token0();
        uint256 chunk = vm.envOr("CHUNK", uint256(0.01 ether));
        int24 target = int24(int256(vm.envOr("PUSH_TICKS", uint256(150))));
        vm.startBroadcast();
        (, address whale,) = vm.readCallers();
        IWBNB(WBNB).deposit{value: chunk * 20}();
        IERC20(WBNB).approve(_router(), type(uint256).max);
        int24 start = _tick(pool);
        for (uint256 i; i < 20; i++) {
            int24 t = _tick(pool);
            if (t - start >= target || start - t >= target) break;
            ISmartRouterT(_router()).exactInputSingle(ISmartRouterT.ExactInputSingleParams(WBNB, other, pool.fee(), whale, chunk, 0, 0));
        }
        vm.stopBroadcast();
        console2.log("tick from", start);
        console2.log("tick to", _tick(pool));
    }
}
