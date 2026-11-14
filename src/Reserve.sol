// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Reserve
/// @notice A named treasury bucket (safety fund, boosted-pools reserve, expansion reserve). It cannot swap or sell
///         anything itself. Its owner is the 48-hour timelock, so every payment is public two days in advance and
///         carries a reason that is stored on-chain.
contract Reserve is Ownable {
    using SafeERC20 for IERC20;

    string public name;

    event Received(address indexed from, uint256 amount);
    event Paid(address indexed token, address indexed to, uint256 amount, string reason);

    error TransferFailed();

    constructor(address owner_, string memory name_) Ownable(owner_) {
        name = name_;
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    /// @param token address(0) for BNB.
    function pay(address token, address to, uint256 amount, string calldata reason) external onlyOwner {
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit Paid(token, to, amount, reason);
    }
}
