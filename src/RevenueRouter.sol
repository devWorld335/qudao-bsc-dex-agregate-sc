// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IWBNB} from "./interfaces/external/IExternal.sol";
import {
    IQudaoFactory, IRevenueRouter, IReferrals, ITheWell, ISwapper, IPriceOracle
} from "./interfaces/IQudao.sol";

/// @title RevenueRouter
/// @notice Receives all protocol revenue: the protocol fee from vaults, the in-app swap fee from the Swapper and
///         launchpad fees on QDAO (flap.sh tax/creator fees, sent here as BNB). Referral rewards are set aside
///         first, then BNB is split between The Well, the boosted-pools reserve, the buyback burner, the safety
///         fund and the team; QDAO is never sold and is split between burning, the expansion reserve and the
///         boosted-pools reserve. Revenue in other tokens is converted to BNB by the keeper, with a price check.
contract RevenueRouter is IRevenueRouter, Ownable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_REFERRER_SHARE_BPS = 5_000;
    uint256 private constant PRECISION = 1e18;

    enum Bnb {
        Well,
        BoostReserve,
        Buyback,
        SafetyFund,
        Team
    }

    enum Qdao {
        Burn,
        ExpansionReserve,
        BoostReserve
    }

    struct Destinations {
        address well;
        address boostReserve;
        address buyback;
        address safetyFund;
        address team;
        address expansionReserve;
    }

    struct Credit {
        uint256 amount; // token units owed, converted at the next conversion of that token
        uint64 epoch;
    }

    IQudaoFactory public immutable factory;
    IReferrals public immutable referrals;
    IWBNB public immutable wbnb;

    IERC20 public qdao; // set once after launch
    address public immutable launcher; // admin Safe: may set QDAO once, without the timelock delay
    Destinations public destinations;
    uint16[5] public bnbSplitBps;
    uint16[3] public qdaoSplitBps;
    uint16 public referrerShareBps;
    uint256 public minDistribution;

    // Referral rewards
    mapping(address referrer => uint256) public referralBnb; // settled, claimable BNB
    uint256 public referralBnbOwed; // all BNB owed to referrers (settled or not)
    mapping(address referrer => uint256) public referralQdao;
    uint256 public referralQdaoOwed;
    mapping(address referrer => mapping(address token => Credit)) public credits;
    mapping(address token => uint256) public pendingReferralToken;
    mapping(address token => uint64) public epochOf;
    mapping(address token => mapping(uint64 epoch => uint256)) public rateX18; // BNB per token unit × 1e18

    // Stats
    uint256 public totalDistributedBnb;
    uint256 public totalReferralPaidBnb;

    event FeeReceived(address indexed user, address indexed token, uint256 amount, address indexed referrer, uint256 referralShare);
    event SwapFeeReceived(address indexed token, uint256 amount);
    event BnbReceived(address indexed from, uint256 amount);
    event Converted(address indexed token, uint256 amountIn, uint256 bnbOut, uint64 epoch);
    event Distributed(uint256 total, uint256 well, uint256 boostReserve, uint256 buyback, uint256 safetyFund, uint256 team);
    event QdaoDistributed(uint256 total, uint256 burned, uint256 expansionReserve, uint256 boostReserve);
    event ReferralClaimed(address indexed referrer, uint256 bnb, uint256 qdao);
    event DestinationsSet(Destinations destinations);
    event SplitsSet(uint16[5] bnbSplitBps, uint16[3] qdaoSplitBps);
    event ReferrerShareSet(uint16 bps);
    event QdaoSet(address qdao);

    error OnlyVault();
    error OnlySwapper();
    error OnlyKeeper();
    error BadSplit();
    error CannotConvert(address token);
    error PriceTooLow(uint256 out, uint256 floor);
    error QdaoAlreadySet();
    error TransferFailed();

    constructor(
        address owner_,
        address launcher_,
        IQudaoFactory factory_,
        IReferrals referrals_,
        IWBNB wbnb_,
        Destinations memory destinations_,
        uint16[5] memory bnbSplit_,
        uint16[3] memory qdaoSplit_,
        uint16 referrerShareBps_,
        uint256 minDistribution_
    ) Ownable(owner_) {
        launcher = launcher_;
        factory = factory_;
        referrals = referrals_;
        wbnb = wbnb_;
        _setDestinations(destinations_);
        _setSplits(bnbSplit_, qdaoSplit_);
        _setReferrerShare(referrerShareBps_);
        minDistribution = minDistribution_;
    }

    receive() external payable {
        // Unwrapping WBNB is internal; any other BNB is revenue (e.g. flap.sh tax on QDAO).
        if (msg.sender != address(wbnb)) emit BnbReceived(msg.sender, msg.value);
    }

    // ---------------------------------------------------------------- admin (timelock)

    function setQdao(IERC20 qdao_) external {
        if (msg.sender != owner() && msg.sender != launcher) revert OwnableUnauthorizedAccount(msg.sender);
        if (address(qdao) != address(0)) revert QdaoAlreadySet();
        qdao = qdao_;
        emit QdaoSet(address(qdao_));
    }

    function setDestinations(Destinations calldata d) external onlyOwner {
        _setDestinations(d);
    }

    function setSplits(uint16[5] calldata bnbSplit_, uint16[3] calldata qdaoSplit_) external onlyOwner {
        _setSplits(bnbSplit_, qdaoSplit_);
    }

    function setReferrerShare(uint16 bps) external onlyOwner {
        _setReferrerShare(bps);
    }

    function setMinDistribution(uint256 amount) external onlyOwner {
        minDistribution = amount;
    }

    function _setDestinations(Destinations memory d) internal {
        destinations = d;
        emit DestinationsSet(d);
    }

    function _setSplits(uint16[5] memory b, uint16[3] memory q) internal {
        uint256 sb;
        uint256 sq;
        for (uint256 i; i < 5; i++) sb += b[i];
        for (uint256 i; i < 3; i++) sq += q[i];
        if (sb != BPS || sq != BPS) revert BadSplit();
        bnbSplitBps = b;
        qdaoSplitBps = q;
        emit SplitsSet(b, q);
    }

    function _setReferrerShare(uint16 bps) internal {
        if (bps > MAX_REFERRER_SHARE_BPS) revert BadSplit();
        referrerShareBps = bps;
        emit ReferrerShareSet(bps);
    }

    // ---------------------------------------------------------------- revenue in

    /// @inheritdoc IRevenueRouter
    /// @dev The vault has already transferred the tokens. The referral share is set aside before any split.
    function onFee(address user, address[] calldata tokens, uint256[] calldata amounts) external {
        if (!factory.isVault(msg.sender)) revert OnlyVault();
        address referrer = referrals.referrerOf(user);
        for (uint256 i; i < tokens.length; i++) {
            uint256 share = referrer == address(0) ? 0 : (amounts[i] * referrerShareBps) / BPS;
            if (share > 0) _creditReferral(referrer, tokens[i], share);
            emit FeeReceived(user, tokens[i], amounts[i], referrer, share);
        }
    }

    /// @inheritdoc IRevenueRouter
    function onSwapFee(address token, uint256 amount) external {
        if (msg.sender != factory.swapper()) revert OnlySwapper();
        emit SwapFeeReceived(token, amount);
    }

    function _creditReferral(address referrer, address token, uint256 share) internal {
        if (token == address(wbnb)) {
            referralBnb[referrer] += share;
            referralBnbOwed += share;
        } else if (token == address(qdao)) {
            referralQdao[referrer] += share;
            referralQdaoOwed += share;
        } else {
            Credit storage c = credits[referrer][token];
            _settle(referrer, token, c);
            c.amount += share;
            c.epoch = epochOf[token];
            pendingReferralToken[token] += share;
        }
    }

    function _settle(address referrer, address token, Credit storage c) internal {
        if (c.amount > 0 && c.epoch < epochOf[token]) {
            referralBnb[referrer] += (c.amount * rateX18[token][c.epoch]) / PRECISION;
            c.amount = 0;
        }
    }

    // ---------------------------------------------------------------- conversion (keeper)

    /// @notice Swaps this contract's whole balance of `token` to WBNB through the Swapper (PancakeSwap Smart Router
    ///         calldata planned off-chain). When both tokens have Chainlink feeds, the result must be within the
    ///         protocol's max slippage of the oracle price.
    function convert(address token, uint256 minOut, address router, bytes calldata data)
        external
        nonReentrant
        returns (uint256 bnbOut)
    {
        if (!factory.isKeeper(msg.sender)) revert OnlyKeeper();
        if (token == address(wbnb) || token == address(qdao) || token == address(0)) revert CannotConvert(token);
        uint256 amountIn = IERC20(token).balanceOf(address(this));
        if (amountIn == 0) return 0;

        uint256 fair = IPriceOracle(factory.oracle()).quoteUsdFeeds(token, address(wbnb), amountIn);
        if (fair > 0) {
            uint256 floor = (fair * (BPS - factory.config().maxSlippageBps)) / BPS;
            if (minOut < floor) minOut = floor;
        }

        address swapper = factory.swapper();
        IERC20(token).forceApprove(swapper, amountIn);
        bnbOut = ISwapper(swapper).swap(token, address(wbnb), amountIn, minOut, router, data);
        uint256 spent = amountIn - IERC20(token).balanceOf(address(this));
        if (spent == 0) revert CannotConvert(token);

        uint64 e = epochOf[token];
        uint256 rate = (bnbOut * PRECISION) / spent;
        rateX18[token][e] = rate;
        epochOf[token] = e + 1;
        uint256 pending = pendingReferralToken[token];
        if (pending > 0) {
            referralBnbOwed += (pending * rate) / PRECISION;
            pendingReferralToken[token] = 0;
        }
        emit Converted(token, spent, bnbOut, e);
    }

    // ---------------------------------------------------------------- distribution (anyone; keeper hourly)

    /// @notice BNB available for the split: everything held minus what is owed to referrers.
    function distributable() public view returns (uint256) {
        uint256 total = address(this).balance + wbnb.balanceOf(address(this));
        return total > referralBnbOwed ? total - referralBnbOwed : 0;
    }

    function distribute() external nonReentrant returns (uint256 total) {
        total = distributable();
        if (total < minDistribution || total == 0) return 0;
        uint256 w = wbnb.balanceOf(address(this));
        if (w > 0) wbnb.withdraw(w);

        Destinations memory d = destinations;
        uint256 toWell = (total * bnbSplitBps[uint8(Bnb.Well)]) / BPS;
        uint256 toBoost = (total * bnbSplitBps[uint8(Bnb.BoostReserve)]) / BPS;
        uint256 toBuyback = (total * bnbSplitBps[uint8(Bnb.Buyback)]) / BPS;
        uint256 toSafety = (total * bnbSplitBps[uint8(Bnb.SafetyFund)]) / BPS;
        uint256 toTeam = total - toWell - toBoost - toBuyback - toSafety;

        if (toWell > 0) ITheWell(d.well).notifyReward{value: toWell}();
        _pay(d.boostReserve, toBoost);
        _pay(d.buyback, toBuyback);
        _pay(d.safetyFund, toSafety);
        _pay(d.team, toTeam);
        totalDistributedBnb += total;
        emit Distributed(total, toWell, toBoost, toBuyback, toSafety, toTeam);
    }

    function distributeQdao() external nonReentrant returns (uint256 total) {
        if (address(qdao) == address(0)) return 0;
        uint256 bal = qdao.balanceOf(address(this));
        total = bal > referralQdaoOwed ? bal - referralQdaoOwed : 0;
        if (total == 0) return 0;
        Destinations memory d = destinations;
        uint256 burned = (total * qdaoSplitBps[uint8(Qdao.Burn)]) / BPS;
        uint256 expansion = (total * qdaoSplitBps[uint8(Qdao.ExpansionReserve)]) / BPS;
        uint256 boost = total - burned - expansion;
        if (burned > 0) qdao.safeTransfer(DEAD, burned);
        if (expansion > 0) qdao.safeTransfer(d.expansionReserve, expansion);
        if (boost > 0) qdao.safeTransfer(d.boostReserve, boost);
        emit QdaoDistributed(total, burned, expansion, boost);
    }

    // ---------------------------------------------------------------- referral claims

    /// @notice What `referrer` can claim now, in BNB, counting credits in `tokens` already converted.
    function claimableReferral(address referrer, address[] calldata tokens) external view returns (uint256 bnb) {
        bnb = referralBnb[referrer];
        for (uint256 i; i < tokens.length; i++) {
            Credit memory c = credits[referrer][tokens[i]];
            if (c.amount > 0 && c.epoch < epochOf[tokens[i]]) {
                bnb += (c.amount * rateX18[tokens[i]][c.epoch]) / PRECISION;
            }
        }
    }

    /// @notice Pays the caller's referral rewards in BNB (and QDAO, if any arrived in QDAO). `tokens` lists the fee
    ///         tokens whose converted credits should be settled first.
    function claimReferral(address[] calldata tokens) external nonReentrant returns (uint256 bnb, uint256 q) {
        for (uint256 i; i < tokens.length; i++) {
            _settle(msg.sender, tokens[i], credits[msg.sender][tokens[i]]);
        }
        bnb = referralBnb[msg.sender];
        q = referralQdao[msg.sender];
        if (bnb > 0) {
            referralBnb[msg.sender] = 0;
            referralBnbOwed -= bnb;
            totalReferralPaidBnb += bnb;
            if (address(this).balance < bnb) wbnb.withdraw(bnb - address(this).balance);
            _pay(msg.sender, bnb);
        }
        if (q > 0) {
            referralQdao[msg.sender] = 0;
            referralQdaoOwed -= q;
            qdao.safeTransfer(msg.sender, q);
        }
        emit ReferralClaimed(msg.sender, bnb, q);
    }

    function _pay(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
