// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IFlapPortal, IWBNB} from "../src/interfaces/external/IExternal.sol";
import {QudaoTypes, IQudaoFactory, IReferrals} from "../src/interfaces/IQudao.sol";
import {QudaoFactory} from "../src/QudaoFactory.sol";
import {QudaoVault} from "../src/QudaoVault.sol";
import {Swapper} from "../src/Swapper.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {Referrals} from "../src/Referrals.sol";
import {TheWell} from "../src/TheWell.sol";
import {BuybackBurner} from "../src/BuybackBurner.sol";
import {Reserve} from "../src/Reserve.sol";

/// @notice Deploys and wires every Qudao contract from config/protocol.json and config/chains.json.
///         Used by the deploy script and by the fork tests, so both run the exact same setup.
abstract contract QudaoDeploy is CommonBase {
    using stdJson for string;

    struct Roles {
        address owner; // the 48h timelock in production (the test contract in tests)
        address guardian; // admin Safe: can pause immediately and set the QDAO address once
        address keeper;
        address team; // team Safe
    }

    struct ChainAddrs {
        address v3Factory;
        address positionManager;
        address smartRouter;
        address masterChef;
        address v2Factory;
        address permit2;
        address flapPortal;
        address wbnb;
        address cake;
    }

    struct TokenInfo {
        // alphabetical order: required for vm.parseJson struct decoding
        address feed;
        bool stable;
        string symbol;
        address token;
    }

    struct Deployment {
        QudaoFactory factory;
        QudaoVault vaultImplementation;
        Swapper swapper;
        PriceOracle oracle;
        RevenueRouter router;
        Referrals referrals;
        TheWell well;
        BuybackBurner burner;
        Reserve safetyFund;
        Reserve boostReserve;
        Reserve expansionReserve;
    }

    function _configDir() internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/config/");
    }

    function _protocol() internal view returns (string memory) {
        return vm.readFile(string.concat(_configDir(), "protocol.json"));
    }

    function _chain(string memory key) internal view returns (ChainAddrs memory c, TokenInfo[] memory tokens) {
        string memory j = vm.readFile(string.concat(_configDir(), "chains.json"));
        string memory b = string.concat(".", key);
        c.v3Factory = j.readAddress(string.concat(b, ".pancake.v3Factory"));
        c.positionManager = j.readAddress(string.concat(b, ".pancake.positionManager"));
        c.smartRouter = j.readAddress(string.concat(b, ".pancake.smartRouter"));
        c.masterChef = j.readAddress(string.concat(b, ".pancake.masterChefV3"));
        c.v2Factory = j.readAddress(string.concat(b, ".pancake.v2Factory"));
        c.permit2 = j.readAddress(string.concat(b, ".permit2"));
        c.flapPortal = j.readAddress(string.concat(b, ".flapPortal"));
        c.wbnb = j.readAddress(string.concat(b, ".wbnb"));
        c.cake = j.readAddress(string.concat(b, ".cake"));
        tokens = abi.decode(vm.parseJson(j, string.concat(b, ".tokens")), (TokenInfo[]));
    }

    /// @dev false on testnet: testnet pools don't follow real prices, so the oracle must not compare them to Chainlink.
    function _oracleFeeds(string memory key) internal view returns (bool) {
        string memory j = vm.readFile(string.concat(_configDir(), "chains.json"));
        string memory path = string.concat(".", key, ".oracleFeeds");
        return vm.keyExistsJson(j, path) ? j.readBool(path) : true;
    }

    function _uint(string memory j, string memory path) internal pure returns (uint256) {
        return j.readUint(path);
    }

    /// @dev "0.0005" style decimal strings → wei.
    function _ether(string memory j, string memory path) internal pure returns (uint256) {
        return _parseDecimal(j.readString(path), 18);
    }

    function _parseDecimal(string memory s, uint256 decimals) internal pure returns (uint256 v) {
        bytes memory b = bytes(s);
        uint256 frac;
        bool dot;
        for (uint256 i; i < b.length; i++) {
            if (b[i] == ".") {
                dot = true;
                continue;
            }
            v = v * 10 + (uint8(b[i]) - 48);
            if (dot) frac++;
        }
        v = v * 10 ** (decimals - frac);
    }

    function _config(string memory j) internal pure returns (QudaoTypes.Config memory c) {
        c.protocolFeeBps = uint16(_uint(j, ".fees.protocolFeeBps"));
        c.minReinvestBps = uint16(_uint(j, ".automation.minReinvestBps"));
        c.maxDeviationBps = uint16(_uint(j, ".automation.oracle.maxDeviationBps"));
        c.minSlippageBps = uint16(_uint(j, ".automation.slippage.minBps"));
        c.maxSlippageBps = uint16(_uint(j, ".automation.slippage.maxBps"));
        c.minReinvestShareBps = uint16(_uint(j, ".automation.reinvestShareMinBps"));
        c.minWidthTicks = uint24(_uint(j, ".automation.minRangeWidthTicks"));
        c.minRebalanceInterval = uint32(_uint(j, ".automation.minRebalanceIntervalSec"));
        c.keeperGrace = uint32(_uint(j, ".automation.keeper.graceHours") * 1 hours);
        c.keeperGasOverhead = uint32(_uint(j, ".automation.keeper.gasOverhead"));
        c.maxKeeperGasPrice = uint64(_parseDecimal(j.readString(".automation.keeper.maxGasPriceGwei"), 9));
        c.maxKeeperRefund = uint128(_ether(j, ".automation.keeper.maxRefundBnb"));
    }

    function _tiers(string memory j) internal pure returns (TheWell.Tiers memory t) {
        for (uint256 i; i < 4; i++) {
            string memory idx = vm.toString(i);
            t.amounts[i] = _parseDecimal(j.readString(string.concat(".staking.tierAmounts[", idx, "]")), 18);
            t.times[i] = uint32(_uint(j, string.concat(".staking.tierDays[", idx, "]")) * 1 days);
            for (uint256 k; k < 4; k++) {
                string memory cell = string.concat("[", idx, "][", vm.toString(k), "]");
                t.discountBps[i][k] = uint16(_uint(j, string.concat(".staking.discountBps", cell)));
                t.boostBps[i][k] = uint16(_uint(j, string.concat(".staking.boostBps", cell)));
            }
        }
    }

    function _burnerParams(string memory j) internal pure returns (BuybackBurner.Params memory p) {
        p.curveMinInterval = uint32(_uint(j, ".buyback.curve.minIntervalSec"));
        p.curveMaxWait = uint32(_uint(j, ".buyback.curve.maxWaitSec"));
        p.curveMinAmount = uint128(_ether(j, ".buyback.curve.minAmountBnb"));
        p.dexMinInterval = uint32(_uint(j, ".buyback.dex.minIntervalSec"));
        p.dexMaxPerBuy = uint128(_ether(j, ".buyback.dex.maxPerBuyBnb"));
        p.stabilitySec = uint32(_uint(j, ".buyback.stabilitySec"));
        p.stabilityBps = uint16(_uint(j, ".buyback.stabilityBps"));
        p.maxBuyTaxBps = uint16(_uint(j, ".buyback.maxBuyTaxBps"));
        p.slippageBps = uint16(_uint(j, ".buyback.slippageBps"));
        p.armValidity = 30 minutes;
    }

    /// @notice Deploys everything with `self` as temporary owner, wires it, then hands ownership to `roles.owner`.
    /// @param self The account sending the deployment transactions (temporary owner during wiring).
    function _deployQudao(Roles memory roles, string memory chainKey, address self) internal returns (Deployment memory d) {
        string memory j = _protocol();
        (ChainAddrs memory c, TokenInfo[] memory tokens) = _chain(chainKey);

        d.referrals = new Referrals(
            self,
            uint16(_uint(j, ".referrals.inviteeDiscountBps")),
            uint32(_uint(j, ".referrals.inviteeDiscountDays") * 1 days)
        );
        d.well = new TheWell(roles.owner, roles.guardian, uint32(_uint(j, ".staking.rewardStreamDays") * 1 days), _tiers(j));
        d.oracle = new PriceOracle(
            self,
            uint32(_uint(j, ".automation.oracle.twapSeconds")),
            uint32(_uint(j, ".automation.oracle.delayedMinSec")),
            uint32(_uint(j, ".automation.oracle.delayedMaxSec"))
        );
        uint32 maxAge = uint32(_uint(j, ".automation.oracle.chainlinkMaxAgeSec"));
        for (uint256 i; i < tokens.length; i++) {
            if (tokens[i].feed != address(0) && _oracleFeeds(chainKey)) d.oracle.setFeed(tokens[i].token, tokens[i].feed, maxAge);
        }

        d.vaultImplementation = new QudaoVault();
        d.factory = new QudaoFactory(
            self,
            roles.guardian,
            QudaoFactory.Externals({
                positionManager: c.positionManager,
                v3Factory: c.v3Factory,
                masterChef: c.masterChef,
                cake: c.cake,
                wbnb: c.wbnb,
                permit2: c.permit2
            }),
            address(d.vaultImplementation),
            _config(j)
        );
        d.swapper = new Swapper(self, IQudaoFactory(address(d.factory)), IWBNB(c.wbnb), uint16(_uint(j, ".fees.swapFeeBps")));
        d.swapper.setRouter(c.smartRouter, true);

        d.safetyFund = new Reserve(roles.owner, "Safety fund");
        d.boostReserve = new Reserve(roles.owner, "Boosted pools reserve");
        d.expansionReserve = new Reserve(roles.owner, "Expansion reserve");
        d.burner = new BuybackBurner(
            roles.owner,
            roles.guardian,
            IQudaoFactory(address(d.factory)),
            IWBNB(c.wbnb),
            IFlapPortal(c.flapPortal),
            c.v2Factory,
            _burnerParams(j)
        );
        d.router = new RevenueRouter(
            roles.owner,
            roles.guardian,
            IQudaoFactory(address(d.factory)),
            IReferrals(address(d.referrals)),
            IWBNB(c.wbnb),
            RevenueRouter.Destinations({
                well: address(d.well),
                boostReserve: address(d.boostReserve),
                buyback: address(d.burner),
                safetyFund: address(d.safetyFund),
                team: roles.team,
                expansionReserve: address(d.expansionReserve)
            }),
            [
                uint16(_uint(j, ".revenue.bnbSplitBps.well")),
                uint16(_uint(j, ".revenue.bnbSplitBps.boostReserve")),
                uint16(_uint(j, ".revenue.bnbSplitBps.buyback")),
                uint16(_uint(j, ".revenue.bnbSplitBps.safetyFund")),
                uint16(_uint(j, ".revenue.bnbSplitBps.team"))
            ],
            [
                uint16(_uint(j, ".revenue.qdaoSplitBps.burn")),
                uint16(_uint(j, ".revenue.qdaoSplitBps.expansionReserve")),
                uint16(_uint(j, ".revenue.qdaoSplitBps.boostReserve"))
            ],
            uint16(_uint(j, ".referrals.referrerShareBps")),
            0.01 ether
        );

        // wiring
        d.factory.setModules(
            QudaoFactory.Modules({
                swapper: address(d.swapper),
                oracle: address(d.oracle),
                revenueRouter: address(d.router),
                referrals: address(d.referrals),
                well: address(d.well)
            })
        );
        if (roles.keeper != address(0)) d.factory.setKeeper(roles.keeper, true);
        for (uint256 i; i < tokens.length; i++) {
            if (tokens[i].stable) d.factory.setStable(tokens[i].token, true);
        }
        d.referrals.setFactory(address(d.factory));
        d.swapper.setModule(address(d.router), true);
        d.swapper.setModule(address(d.burner), true);

        // hand over to the timelock
        if (roles.owner != self) {
            d.factory.transferOwnership(roles.owner);
            d.swapper.transferOwnership(roles.owner);
            d.oracle.transferOwnership(roles.owner);
            d.referrals.transferOwnership(roles.owner);
        }
    }
}
