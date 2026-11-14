// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IWBNB} from "./interfaces/external/IExternal.sol";
import {IQudaoFactory, ISwapper, IRevenueRouter} from "./interfaces/IQudao.sol";

/// @title Swapper
/// @notice Runs swaps planned off-chain by PancakeSwap's Smart Router SDK. It only calls whitelisted routers,
///         checks what actually arrived against a minimum, and sends everything straight back: it holds nothing
///         between transactions. Vaults, the revenue router and the buyback burner use {swap}; users swap in the
///         app with {swapForUser}, which takes the in-app swap fee for protocol revenue.
contract Swapper is ISwapper, Ownable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    address public constant NATIVE = address(0);
    uint256 public constant MAX_SWAP_FEE_BPS = 100; // 1%

    IQudaoFactory public immutable factory;
    IWBNB public immutable wbnb;

    mapping(address router => bool) public isRouter;
    mapping(address caller => bool) public isModule; // revenue router, buyback burner
    uint16 public swapFeeBps;

    event RouterSet(address indexed router, bool allowed);
    event ModuleSet(address indexed module, bool allowed);
    event SwapFeeSet(uint16 bps);
    event Swapped(
        address indexed caller, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );
    event UserSwap(
        address indexed user, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, uint256 fee
    );

    error NotAllowed();
    error RouterNotAllowed(address router);
    error TooLittleReceived(uint256 received, uint256 minimum);
    error SameToken();
    error BadValue();
    error FeeTooHigh();

    constructor(address owner_, IQudaoFactory factory_, IWBNB wbnb_, uint16 swapFeeBps_) Ownable(owner_) {
        factory = factory_;
        wbnb = wbnb_;
        _setSwapFee(swapFeeBps_);
    }

    receive() external payable {
        if (msg.sender != address(wbnb)) revert NotAllowed();
    }

    // ---------------------------------------------------------------- admin (timelock)

    function setRouter(address router, bool allowed) external onlyOwner {
        isRouter[router] = allowed;
        emit RouterSet(router, allowed);
    }

    function setModule(address module, bool allowed) external onlyOwner {
        isModule[module] = allowed;
        emit ModuleSet(module, allowed);
    }

    function setSwapFee(uint16 bps) external onlyOwner {
        _setSwapFee(bps);
    }

    function _setSwapFee(uint16 bps) internal {
        if (bps > MAX_SWAP_FEE_BPS) revert FeeTooHigh();
        swapFeeBps = bps;
        emit SwapFeeSet(bps);
    }

    // ---------------------------------------------------------------- protocol swaps

    /// @inheritdoc ISwapper
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address router, bytes calldata data)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (!factory.isVault(msg.sender) && !isModule[msg.sender]) revert NotAllowed();
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 unused;
        (amountOut, unused) = _route(tokenIn, tokenOut, amountIn, router, data);
        if (amountOut < minOut) revert TooLittleReceived(amountOut, minOut);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        if (unused > 0) IERC20(tokenIn).safeTransfer(msg.sender, unused);
        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn - unused, amountOut);
    }

    // ---------------------------------------------------------------- in-app swaps

    /// @notice Swap from the app. Use address(0) for native BNB on either side. `minOut` is what the user must
    ///         receive after the swap fee.
    function swapForUser(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address router,
        bytes calldata data,
        address recipient
    ) external payable nonReentrant returns (uint256 received) {
        if (tokenIn == tokenOut) revert SameToken();
        address inToken = tokenIn == NATIVE ? address(wbnb) : tokenIn;
        address outToken = tokenOut == NATIVE ? address(wbnb) : tokenOut;
        if (inToken == outToken) revert SameToken();

        if (tokenIn == NATIVE) {
            if (msg.value != amountIn) revert BadValue();
            wbnb.deposit{value: amountIn}();
        } else {
            if (msg.value != 0) revert BadValue();
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        }

        (uint256 out, uint256 unused) = _route(inToken, outToken, amountIn, router, data);
        uint256 fee = (out * swapFeeBps) / 10_000;
        received = out - fee;
        if (received < minOut) revert TooLittleReceived(received, minOut);

        if (fee > 0) {
            address rr = factory.revenueRouter();
            IERC20(outToken).safeTransfer(rr, fee);
            IRevenueRouter(rr).onSwapFee(outToken, fee);
        }
        _send(tokenOut, outToken, recipient, received);
        if (unused > 0) _send(tokenIn, inToken, msg.sender, unused);
        emit UserSwap(msg.sender, tokenIn, tokenOut, amountIn - unused, received, fee);
    }

    // ---------------------------------------------------------------- internals

    function _route(address tokenIn, address tokenOut, uint256 amountIn, address router, bytes calldata data)
        internal
        returns (uint256 amountOut, uint256 unused)
    {
        if (tokenIn == tokenOut) revert SameToken();
        if (!isRouter[router]) revert RouterNotAllowed(router);
        uint256 inBefore = IERC20(tokenIn).balanceOf(address(this)) - amountIn;
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        IERC20(tokenIn).forceApprove(router, amountIn);
        (bool ok, bytes memory ret) = router.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
        IERC20(tokenIn).forceApprove(router, 0);

        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        unused = IERC20(tokenIn).balanceOf(address(this)) - inBefore;
    }

    function _send(address token, address erc20, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (token == NATIVE) {
            wbnb.withdraw(amount);
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert BadValue();
        } else {
            IERC20(erc20).safeTransfer(to, amount);
        }
    }
}
