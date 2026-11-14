// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ITheWell} from "./interfaces/IQudao.sol";

/// @title The Well
/// @notice QDAO staking with no lock. How much you stake picks the row and how long you have stayed staked picks
///         the column of a 4×4 tier grid; your tier gives a discount on the protocol fee and a boost on rewards.
///         BNB rewards from protocol revenue are streamed over `rewardDuration` (30 days): every second each staker
///         earns in proportion to stake × boost. While nobody stakes, the stream waits. Nobody — including the
///         owner — can take BNB out of this contract except stakers claiming their rewards.
contract TheWell is ITheWell, Ownable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint256 public constant TIERS = 4;
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_DISCOUNT_BPS = 5_000;
    uint256 public constant MAX_BOOST_BPS = 30_000;
    uint256 private constant PRECISION = 1e18;

    struct Account {
        uint256 amount;
        uint64 since; // effective start of "time staked"
        uint256 weight; // amount × boost at the last update
        uint256 paid; // rewardPerWeight already accounted
        uint256 rewards; // claimable BNB
    }

    struct Tiers {
        uint256[TIERS] amounts; // minimum stake per row (token base units), ascending
        uint32[TIERS] times; // minimum time staked per column (seconds), ascending, times[0] = 0
        uint16[TIERS][TIERS] discountBps; // [row][col]
        uint16[TIERS][TIERS] boostBps; // [row][col], 10000 = 1x
    }

    IERC20 public token; // QDAO, set once after its flap.sh launch
    address public immutable launcher; // admin Safe: may set the token once, without the timelock delay
    uint32 public immutable rewardDuration;
    Tiers internal _tiers;

    mapping(address => Account) public accounts;
    uint256 public totalStaked;
    uint256 public totalWeight;

    uint256 public rewardRateX18; // wei per second × 1e18
    uint64 public periodFinish;
    uint64 public lastUpdate;
    uint256 public rewardPerWeightX18;

    uint256 public totalNotified;
    uint256 public totalClaimed;

    event TokenSet(address token);
    event TiersSet();
    event Staked(address indexed user, uint256 amount, uint256 total, uint64 since);
    event Unstaked(address indexed user, uint256 amount, uint256 total);
    event Claimed(address indexed user, uint256 amount);
    event RewardAdded(address indexed from, uint256 amount, uint256 rateX18, uint64 periodFinish);
    event Reweighted(address indexed user, uint256 weight);

    error TokenNotSet();
    error TokenAlreadySet();
    error ZeroAmount();
    error InsufficientStake();
    error BadTiers();
    error TransferFailed();

    constructor(address owner_, address launcher_, uint32 rewardDuration_, Tiers memory tiers_) Ownable(owner_) {
        launcher = launcher_;
        if (rewardDuration_ == 0) revert BadTiers();
        rewardDuration = rewardDuration_;
        _setTiers(tiers_);
        lastUpdate = uint64(block.timestamp);
    }

    // ---------------------------------------------------------------- admin (timelock)

    function setToken(IERC20 token_) external {
        if (msg.sender != owner() && msg.sender != launcher) revert OwnableUnauthorizedAccount(msg.sender);
        if (address(token) != address(0)) revert TokenAlreadySet();
        token = token_;
        emit TokenSet(address(token_));
    }

    function setTiers(Tiers calldata tiers_) external onlyOwner {
        _setTiers(tiers_);
    }

    function _setTiers(Tiers memory t) internal {
        if (t.times[0] != 0) revert BadTiers();
        for (uint256 i; i < TIERS; i++) {
            if (i > 0 && (t.amounts[i] <= t.amounts[i - 1] || t.times[i] <= t.times[i - 1])) revert BadTiers();
            for (uint256 j; j < TIERS; j++) {
                if (t.discountBps[i][j] > MAX_DISCOUNT_BPS) revert BadTiers();
                if (t.boostBps[i][j] < BPS || t.boostBps[i][j] > MAX_BOOST_BPS) revert BadTiers();
            }
        }
        _tiers = t;
        emit TiersSet();
    }

    function tiers() external view returns (Tiers memory) {
        return _tiers;
    }

    // ---------------------------------------------------------------- rewards in

    /// @inheritdoc ITheWell
    /// @dev Anyone can add BNB; the revenue router sends the stakers' share here every distribution.
    function notifyReward() external payable {
        if (msg.value == 0) return;
        _updateGlobal();
        uint256 nowTs = block.timestamp;
        uint256 leftover = nowTs < periodFinish ? (periodFinish - nowTs) * rewardRateX18 : 0;
        rewardRateX18 = (msg.value * PRECISION + leftover) / rewardDuration;
        periodFinish = uint64(nowTs + rewardDuration);
        lastUpdate = uint64(nowTs);
        totalNotified += msg.value;
        emit RewardAdded(msg.sender, msg.value, rewardRateX18, periodFinish);
    }

    // ---------------------------------------------------------------- staking

    function stake(uint256 amount) external nonReentrant {
        if (address(token) == address(0)) revert TokenNotSet();
        if (amount == 0) revert ZeroAmount();
        _updateUser(msg.sender);
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;

        Account storage a = accounts[msg.sender];
        uint256 nowTs = block.timestamp;
        if (a.amount == 0) {
            a.since = uint64(nowTs);
        } else {
            // A top-up keeps time staked in proportion to the old stake: doubling it halves the time.
            uint256 elapsed = nowTs - a.since;
            a.since = uint64(nowTs - (elapsed * a.amount) / (a.amount + received));
        }
        a.amount += received;
        totalStaked += received;
        _reweight(msg.sender);
        emit Staked(msg.sender, received, a.amount, a.since);
    }

    /// @notice Instant unstake. A partial unstake keeps your time staked; unstaking everything resets it.
    function unstake(uint256 amount) external nonReentrant {
        Account storage a = accounts[msg.sender];
        if (amount == 0) revert ZeroAmount();
        if (amount > a.amount) revert InsufficientStake();
        _updateUser(msg.sender);
        a.amount -= amount;
        if (a.amount == 0) a.since = 0;
        totalStaked -= amount;
        _reweight(msg.sender);
        token.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount, a.amount);
    }

    function claim() external nonReentrant returns (uint256 amount) {
        _updateUser(msg.sender);
        _reweight(msg.sender);
        Account storage a = accounts[msg.sender];
        amount = a.rewards;
        if (amount == 0) return 0;
        a.rewards = 0;
        totalClaimed += amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Claimed(msg.sender, amount);
    }

    /// @notice Re-applies each user's current tier boost (time staked moves tiers up). The keeper calls this hourly.
    function poke(address[] calldata users) external {
        for (uint256 i; i < users.length; i++) {
            _updateUser(users[i]);
            _reweight(users[i]);
        }
    }

    // ---------------------------------------------------------------- views

    /// @inheritdoc ITheWell
    function discountBpsOf(address user) external view returns (uint256) {
        if (address(token) == address(0)) return 0;
        (bool has, uint256 row, uint256 col) = tierOf(user);
        return has ? _tiers.discountBps[row][col] : 0;
    }

    function boostBpsOf(address user) public view returns (uint256) {
        (bool has, uint256 row, uint256 col) = tierOf(user);
        return has ? _tiers.boostBps[row][col] : BPS;
    }

    function tierOf(address user) public view returns (bool has, uint256 row, uint256 col) {
        Account memory a = accounts[user];
        if (a.amount < _tiers.amounts[0]) return (false, 0, 0);
        for (uint256 i = TIERS; i > 0; i--) {
            if (a.amount >= _tiers.amounts[i - 1]) {
                row = i - 1;
                break;
            }
        }
        uint256 elapsed = block.timestamp - a.since;
        for (uint256 j = TIERS; j > 0; j--) {
            if (elapsed >= _tiers.times[j - 1]) {
                col = j - 1;
                break;
            }
        }
        has = true;
    }

    function earned(address user) external view returns (uint256) {
        Account memory a = accounts[user];
        return a.rewards + (a.weight * (_currentRewardPerWeight() - a.paid)) / PRECISION;
    }

    /// @notice BNB still to be streamed to stakers.
    function streaming() external view returns (uint256) {
        if (block.timestamp >= periodFinish) return 0;
        return ((periodFinish - block.timestamp) * rewardRateX18) / PRECISION;
    }

    // ---------------------------------------------------------------- internals

    function _currentRewardPerWeight() internal view returns (uint256) {
        if (totalWeight == 0) return rewardPerWeightX18;
        uint256 t = block.timestamp < periodFinish ? block.timestamp : periodFinish;
        if (t <= lastUpdate) return rewardPerWeightX18;
        return rewardPerWeightX18 + ((t - lastUpdate) * rewardRateX18) / totalWeight;
    }

    function _updateGlobal() internal {
        uint256 nowTs = block.timestamp;
        if (totalWeight == 0) {
            // Nobody earns while nobody stakes: push the end of the stream back so nothing is lost.
            if (periodFinish > lastUpdate) periodFinish = uint64(periodFinish + (nowTs - lastUpdate));
        } else {
            rewardPerWeightX18 = _currentRewardPerWeight();
        }
        lastUpdate = uint64(nowTs);
    }

    function _updateUser(address user) internal {
        _updateGlobal();
        Account storage a = accounts[user];
        a.rewards += (a.weight * (rewardPerWeightX18 - a.paid)) / PRECISION;
        a.paid = rewardPerWeightX18;
    }

    function _reweight(address user) internal {
        Account storage a = accounts[user];
        uint256 w = a.amount == 0 ? 0 : (a.amount * boostBpsOf(user)) / BPS;
        if (w != a.weight) {
            totalWeight = totalWeight - a.weight + w;
            a.weight = w;
            emit Reweighted(user, w);
        }
    }
}
