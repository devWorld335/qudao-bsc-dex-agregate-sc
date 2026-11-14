// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IReferrals} from "./interfaces/IQudao.sol";

/// @title Referrals
/// @notice Invite codes and who invited whom. A wallet registers one 8-character code (a–z, 0–9) once; the link
///         then shows the code, not the wallet. A code only counts for a wallet that has never used Qudao, it
///         can't be your own, and it is linked by the factory inside the wallet's first-position transaction.
///         The invitee pays less for a limited time; the referrer's share is paid by the RevenueRouter.
contract Referrals is IReferrals, Ownable {
    uint256 public constant CODE_LENGTH = 8;
    uint256 public constant MAX_INVITEE_DISCOUNT_BPS = 5000;

    address public factory;
    uint16 public inviteeDiscountBps;
    uint32 public inviteeDiscountDuration;

    mapping(bytes8 code => address) public ownerOfCode;
    mapping(address account => bytes8) public codeOf;
    mapping(address user => address) public referrerOf;
    mapping(address user => uint64) public joinedAt;
    mapping(address referrer => uint32) public invitedCount;

    event FactorySet(address factory);
    event InviteeDiscountSet(uint16 bps, uint32 duration);
    event CodeRegistered(address indexed account, bytes8 indexed code);
    event Linked(address indexed user, address indexed referrer, bytes8 code);

    error OnlyFactory();
    error AlreadyRegistered();
    error CodeTaken();
    error InvalidCode();
    error FactoryAlreadySet();
    error DiscountTooHigh();

    constructor(address owner_, uint16 inviteeDiscountBps_, uint32 inviteeDiscountDuration_) Ownable(owner_) {
        _setInviteeDiscount(inviteeDiscountBps_, inviteeDiscountDuration_);
    }

    /// @notice One-time wiring at deployment (the factory is deployed after this contract).
    function setFactory(address factory_) external onlyOwner {
        if (factory != address(0)) revert FactoryAlreadySet();
        factory = factory_;
        emit FactorySet(factory_);
    }

    function setInviteeDiscount(uint16 bps, uint32 duration) external onlyOwner {
        _setInviteeDiscount(bps, duration);
    }

    function _setInviteeDiscount(uint16 bps, uint32 duration) internal {
        if (bps > MAX_INVITEE_DISCOUNT_BPS) revert DiscountTooHigh();
        (inviteeDiscountBps, inviteeDiscountDuration) = (bps, duration);
        emit InviteeDiscountSet(bps, duration);
    }

    /// @notice Registers the caller's invite code. Each wallet gets exactly one, forever.
    function register(bytes8 code) external {
        if (codeOf[msg.sender] != bytes8(0)) revert AlreadyRegistered();
        if (!isValidCode(code)) revert InvalidCode();
        if (ownerOfCode[code] != address(0)) revert CodeTaken();
        ownerOfCode[code] = msg.sender;
        codeOf[msg.sender] = code;
        emit CodeRegistered(msg.sender, code);
    }

    /// @inheritdoc IReferrals
    /// @dev The factory only calls this for wallets opening their very first position.
    function link(address user, bytes8 code) external returns (address referrer) {
        if (msg.sender != factory) revert OnlyFactory();
        if (code == bytes8(0) || referrerOf[user] != address(0)) return address(0);
        referrer = ownerOfCode[code];
        if (referrer == address(0) || referrer == user) return address(0);
        referrerOf[user] = referrer;
        joinedAt[user] = uint64(block.timestamp);
        unchecked {
            invitedCount[referrer]++;
        }
        emit Linked(user, referrer, code);
    }

    /// @inheritdoc IReferrals
    function inviteeDiscountBpsOf(address user) external view returns (uint256) {
        if (referrerOf[user] == address(0)) return 0;
        if (block.timestamp >= uint256(joinedAt[user]) + inviteeDiscountDuration) return 0;
        return inviteeDiscountBps;
    }

    function isValidCode(bytes8 code) public pure returns (bool) {
        for (uint256 i; i < CODE_LENGTH; i++) {
            bytes1 c = code[i];
            bool digit = c >= 0x30 && c <= 0x39;
            bool lower = c >= 0x61 && c <= 0x7a;
            if (!digit && !lower) return false;
        }
        return true;
    }
}
