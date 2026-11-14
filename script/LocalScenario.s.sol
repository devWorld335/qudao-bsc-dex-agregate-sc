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

interface ISmartRouterS {
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

/// @notice Local-fork scenario for end-to-end testing of the indexer and keeper.
///   forge script script/LocalScenario.s.sol --sig "open()"  --rpc-url http://127.0.0.1:8545 --broadcast --unlocked --sender <user>
///   forge script script/LocalScenario.s.sol --sig "push()"  --rpc-url http://127.0.0.1:8545 --broadcast --unlocked --sender <whale>
contract LocalScenario is Script {
    using stdJson for string;

    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant POOL = 0x36696169C63e42cd08ce11f5deeBbCeBae652050;
    address constant SMART_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;

    function _d() internal view returns (string memory) {
        return vm.readFile(string.concat(vm.projectRoot(), "/deployments/local.json"));
    }

    function _tick() internal view returns (int24 t) {
        (, t,,,,,) = IPancakeV3Pool(POOL).slot0();
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
        vm.startBroadcast();
        (, address user,) = vm.readCallers();

        // 1. in-app swap: 5 BNB → USDT through the Qudao Swapper (0.15% fee to the revenue router)
        bytes memory data = abi.encodeCall(
            ISmartRouterS.exactInputSingle,
            (ISmartRouterS.ExactInputSingleParams(WBNB, USDT, 500, address(swapper), 5 ether, 0, 0))
        );
        uint256 usdt = swapper.swapForUser{value: 5 ether}(address(0), USDT, 5 ether, 1, SMART_ROUTER, data, user);
        console2.log("USDT from in-app swap", usdt);

        // 2. open a narrow USDT/WBNB position with native BNB on the WBNB side
        IERC20(USDT).approve(address(factory), type(uint256).max);
        int24 tick = _tick();
        QudaoTypes.OpenParams memory p = QudaoTypes.OpenParams({
            token0: USDT,
            token1: WBNB,
            fee: 500,
            tickLower: _floor(tick - 110, 10),
            tickUpper: _floor(tick + 110, 10) + 10,
            amount0: usdt,
            amount1: 5 ether,
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
        (address vault, uint256 id, uint128 liq) = factory.openPosition{value: 5 ether}(p, empty, "");
        vm.stopBroadcast();
        console2.log("vault", vault);
        console2.log("tokenId", id);
        console2.log("liquidity", liq);
        console2.log("tick", tick);
    }

    /// @notice Sells WBNB into the pool until the tick is `target` ticks above where the user's range ends.
    function push() external {
        string memory d = _d();
        d;
        vm.startBroadcast();
        (, address whale,) = vm.readCallers();
        IWBNB(WBNB).deposit{value: 8000 ether}();
        IERC20(WBNB).approve(SMART_ROUTER, type(uint256).max);
        int24 start = _tick();
        int24 target = start + int24(int256(vm.envOr("PUSH_TICKS", uint256(160))));
        for (uint256 i; i < 40 && _tick() < target; i++) {
            ISmartRouterS(SMART_ROUTER).exactInputSingle(
                ISmartRouterS.ExactInputSingleParams(WBNB, USDT, 500, whale, 150 ether, 0, 0)
            );
        }
        vm.stopBroadcast();
        console2.log("tick from", start);
        console2.log("tick to", _tick());
    }
}
