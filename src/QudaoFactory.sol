// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {IPancakeV3Factory, INonfungiblePositionManager} from "./interfaces/external/IPancakeV3.sol";
import {IWBNB} from "./interfaces/external/IExternal.sol";
import {QudaoTypes, IQudaoFactory, IReferrals, ITheWell} from "./interfaces/IQudao.sol";
import {QudaoVault} from "./QudaoVault.sol";

/// @title QudaoFactory
/// @notice Creates a personal vault for every position and holds the protocol settings. Owned by the 48-hour
///         timelock; the guardian (admin Safe) can pause straight away. While paused there are no new positions
///         and no automatic actions, but closing, withdrawing and claiming keep working.
contract QudaoFactory is IQudaoFactory, Ownable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_PROTOCOL_FEE_BPS = 1_000; // the protocol fee can never exceed 10%
    uint16 public constant MAX_SLIPPAGE_BPS = 500; // swaps are never allowed more than 5% below the checked price
    uint256 internal constant BPS = 10_000;

    struct Externals {
        address positionManager;
        address v3Factory;
        address masterChef;
        address cake;
        address wbnb;
        address permit2;
    }

    struct Modules {
        address swapper;
        address oracle;
        address revenueRouter;
        address referrals;
        address well;
    }

    address public immutable positionManager;
    address public immutable v3Factory;
    address public immutable masterChef;
    address public immutable cake;
    address public immutable wbnb;
    address public immutable permit2;
    address public immutable vaultImplementation;

    address public swapper;
    address public oracle;
    address public revenueRouter;
    address public referrals;
    address public well;

    QudaoTypes.Config internal _config;
    address public guardian;
    bool public paused;
    uint64 public lastKeeperAction;

    mapping(address => bool) public isKeeper;
    mapping(address => bool) public isVault;
    mapping(address => bool) public isStable;
    mapping(address => bool) public hasUsed;
    mapping(address => address[]) internal _vaultsOf;
    address[] public allVaults;

    event PositionOpened(
        address indexed owner,
        address indexed vault,
        address indexed pool,
        uint256 tokenId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address referrer
    );
    event PoolCreated(address indexed pool, address token0, address token1, uint24 fee, uint160 sqrtPriceX96);
    event ConfigSet(QudaoTypes.Config config);
    event ModulesSet(Modules modules);
    event KeeperSet(address indexed keeper, bool allowed);
    event GuardianSet(address guardian);
    event StableSet(address indexed token, bool stable);
    event PausedSet(bool paused);
    event KeeperHeartbeat(address indexed keeper);

    error NotGuardian();
    error IsPaused();
    error Expired();
    error BadConfig();
    error BadTokens();
    error NoPool();
    error BadPermit();
    error BadValue();
    error FeeOnTransfer();
    error OnlyVault();

    constructor(
        address owner_,
        address guardian_,
        Externals memory ext,
        address vaultImplementation_,
        QudaoTypes.Config memory config_
    ) Ownable(owner_) {
        positionManager = ext.positionManager;
        v3Factory = ext.v3Factory;
        masterChef = ext.masterChef;
        cake = ext.cake;
        wbnb = ext.wbnb;
        permit2 = ext.permit2;
        vaultImplementation = vaultImplementation_;
        guardian = guardian_;
        lastKeeperAction = uint64(block.timestamp);
        _setConfig(config_);
    }

    // ---------------------------------------------------------------- admin (timelock)

    function setModules(Modules calldata m) external onlyOwner {
        (swapper, oracle, revenueRouter, referrals, well) = (m.swapper, m.oracle, m.revenueRouter, m.referrals, m.well);
        emit ModulesSet(m);
    }

    function setConfig(QudaoTypes.Config calldata c) external onlyOwner {
        _setConfig(c);
    }

    function setKeeper(address keeper, bool allowed) external onlyOwner {
        isKeeper[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    function setGuardian(address guardian_) external onlyOwner {
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    function setStable(address token, bool stable) external onlyOwner {
        isStable[token] = stable;
        emit StableSet(token, stable);
    }

    /// @notice Emergency stop. The guardian (admin Safe) acts immediately; the timelock can too.
    function setPaused(bool paused_) external {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardian();
        paused = paused_;
        emit PausedSet(paused_);
    }

    function _setConfig(QudaoTypes.Config memory c) internal {
        if (
            c.protocolFeeBps > MAX_PROTOCOL_FEE_BPS || c.maxSlippageBps > MAX_SLIPPAGE_BPS
                || c.minSlippageBps > c.maxSlippageBps || c.minReinvestShareBps > BPS || c.minReinvestBps > BPS
                || c.keeperGrace == 0
        ) revert BadConfig();
        _config = c;
        emit ConfigSet(c);
    }

    // ---------------------------------------------------------------- keeper liveness

    /// @notice Vaults record keeper activity; keepers can also check in directly.
    function recordKeeperAction() external {
        if (!isVault[msg.sender]) revert OnlyVault();
        lastKeeperAction = uint64(block.timestamp);
    }

    function heartbeat() external {
        if (!isKeeper[msg.sender]) revert OnlyVault();
        lastKeeperAction = uint64(block.timestamp);
        emit KeeperHeartbeat(msg.sender);
    }

    /// @notice True once the keeper has been silent for longer than the grace period: then anyone may trigger a
    ///         due range move or reinvest (still fully checked by the vault).
    function keeperStale() external view returns (bool) {
        return block.timestamp > uint256(lastKeeperAction) + _config.keeperGrace;
    }

    // ---------------------------------------------------------------- views

    function config() external view returns (QudaoTypes.Config memory) {
        return _config;
    }

    /// @notice The protocol fee this user pays on earnings: the base fee, less the staking discount (The Well)
    ///         and the invitee discount (first months after joining through a link).
    function feeBpsFor(address user) external view returns (uint256 bps) {
        bps = _config.protocolFeeBps;
        if (well != address(0)) bps = (bps * (BPS - ITheWell(well).discountBpsOf(user))) / BPS;
        if (referrals != address(0)) bps = (bps * (BPS - IReferrals(referrals).inviteeDiscountBpsOf(user))) / BPS;
    }

    function vaultsOf(address owner_) external view returns (address[] memory) {
        return _vaultsOf[owner_];
    }

    function vaultCount() external view returns (uint256) {
        return allVaults.length;
    }

    // ---------------------------------------------------------------- open a position

    /// @notice Opens a position in one transaction: creates the pool if asked, creates the caller's vault, links an
    ///         invite code for first-time wallets, moves the tokens straight from the wallet into the vault (Permit2
    ///         signature, plain approvals, or native BNB for the WBNB side) and opens the range.
    /// @param permit Permit2 batch for the ERC-20 sides (spender: this factory). Pass an empty signature to use
    ///        plain approvals instead.
    function openPosition(
        QudaoTypes.OpenParams calldata p,
        ISignatureTransfer.PermitBatchTransferFrom calldata permit,
        bytes calldata signature
    ) external payable nonReentrant returns (address vault, uint256 tokenId, uint128 liquidity) {
        if (paused) revert IsPaused();
        if (block.timestamp > p.deadline) revert Expired();
        if (p.token0 >= p.token1) revert BadTokens();

        address pool = IPancakeV3Factory(v3Factory).getPool(p.token0, p.token1, p.fee);
        if (pool == address(0)) {
            if (p.createPoolSqrtPriceX96 == 0) revert NoPool();
            pool = INonfungiblePositionManager(positionManager).createAndInitializePoolIfNecessary(
                p.token0, p.token1, p.fee, p.createPoolSqrtPriceX96
            );
            emit PoolCreated(pool, p.token0, p.token1, p.fee, p.createPoolSqrtPriceX96);
        }

        address referrer;
        if (!hasUsed[msg.sender]) {
            hasUsed[msg.sender] = true;
            if (p.referralCode != bytes8(0) && referrals != address(0)) {
                referrer = IReferrals(referrals).link(msg.sender, p.referralCode);
            }
        }

        vault = Clones.clone(vaultImplementation);
        isVault[vault] = true;
        _vaultsOf[msg.sender].push(vault);
        allVaults.push(vault);
        QudaoVault(payable(vault)).initialize(msg.sender, pool, p.settings);

        _pullInto(vault, p.token0, p.token1, p.amount0, p.amount1, permit, signature);
        (tokenId, liquidity) = QudaoVault(payable(vault)).openPosition(
            p.tickLower, p.tickUpper, p.amount0, p.amount1, p.amount0Min, p.amount1Min, msg.value > 0
        );
        emit PositionOpened(msg.sender, vault, pool, tokenId, p.tickLower, p.tickUpper, liquidity, referrer);
    }

    /// @notice Adds funds to one of the caller's open positions, pulling the tokens the same ways as
    ///         {openPosition}. What doesn't fit the range goes straight back to the wallet.
    function addFunds(
        address vault,
        uint256 amount0,
        uint256 amount1,
        uint256 amount0Min,
        uint256 amount1Min,
        ISignatureTransfer.PermitBatchTransferFrom calldata permit,
        bytes calldata signature
    ) external payable nonReentrant {
        if (paused) revert IsPaused();
        if (!isVault[vault] || QudaoVault(payable(vault)).owner() != msg.sender) revert OnlyVault();
        address t0 = QudaoVault(payable(vault)).token0();
        address t1 = QudaoVault(payable(vault)).token1();
        _pullInto(vault, t0, t1, amount0, amount1, permit, signature);
        QudaoVault(payable(vault)).addFunds(amount0, amount1, amount0Min, amount1Min, msg.value > 0);
    }

    function _pullInto(
        address vault,
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        ISignatureTransfer.PermitBatchTransferFrom calldata permit,
        bytes calldata signature
    ) internal {
        bool native0 = msg.value > 0 && token0 == wbnb;
        bool native1 = msg.value > 0 && token1 == wbnb;
        if (msg.value > 0) {
            if (!(native0 && msg.value == amount0) && !(native1 && msg.value == amount1)) revert BadValue();
            IWBNB(wbnb).deposit{value: msg.value}();
            IERC20(wbnb).safeTransfer(vault, msg.value);
        }

        uint256 b0 = IERC20(token0).balanceOf(vault);
        uint256 b1 = IERC20(token1).balanceOf(vault);
        uint256 want0 = native0 ? 0 : amount0;
        uint256 want1 = native1 ? 0 : amount1;

        if (signature.length > 0) {
            uint256 n = permit.permitted.length;
            ISignatureTransfer.SignatureTransferDetails[] memory details =
                new ISignatureTransfer.SignatureTransferDetails[](n);
            for (uint256 i; i < n; i++) {
                address t = permit.permitted[i].token;
                uint256 want = t == token0 ? want0 : t == token1 ? want1 : 0;
                if (want == 0 || permit.permitted[i].amount < want) revert BadPermit();
                details[i] = ISignatureTransfer.SignatureTransferDetails(vault, want);
            }
            ISignatureTransfer(permit2).permitTransferFrom(permit, details, msg.sender, signature);
        } else {
            if (want0 > 0) IERC20(token0).safeTransferFrom(msg.sender, vault, want0);
            if (want1 > 0) IERC20(token1).safeTransferFrom(msg.sender, vault, want1);
        }

        // Tokens that take a fee on transfer would lose money on every rebalance: refuse them.
        if (IERC20(token0).balanceOf(vault) - b0 != want0) revert FeeOnTransfer();
        if (IERC20(token1).balanceOf(vault) - b1 != want1) revert FeeOnTransfer();
    }
}
