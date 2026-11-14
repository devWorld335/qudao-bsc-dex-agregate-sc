// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {QudaoDeploy} from "./QudaoDeploy.sol";

/// @notice Deploys Qudao behind a 48-hour timelock run by the admin Safe.
///
///   QUDAO_CHAIN=bsc QUDAO_ADMIN_SAFE=0x… QUDAO_TEAM_SAFE=0x… QUDAO_KEEPER=0x… \
///   forge script script/Deploy.s.sol --rpc-url bsc --broadcast --account <your-keystore>
///
/// The deployer key only pays gas: ownership ends with the timelock, the admin Safe can pause and set the QDAO
/// address once, and the deployer keeps no role.
contract Deploy is Script, QudaoDeploy {
    using stdJson for string;

    function run() external returns (Deployment memory d, TimelockController timelock) {
        string memory chainKey = vm.envOr("QUDAO_CHAIN", string("bsc"));
        address adminSafe = vm.envAddress("QUDAO_ADMIN_SAFE");
        address teamSafe = vm.envAddress("QUDAO_TEAM_SAFE");
        address keeper = vm.envAddress("QUDAO_KEEPER");
        uint256 delay = _protocol().readUint(".governance.timelockHours") * 1 hours;
        bool placeholder = vm.indexOf(_protocol().readString("._status"), "PLACEHOLDER") != type(uint256).max;
        require(!placeholder || vm.envOr("QUDAO_ALLOW_PLACEHOLDERS", false),
            "protocol.json still has placeholder numbers (set QUDAO_ALLOW_PLACEHOLDERS=true for testnet)");
        // placeholders never reach BSC mainnet: on chain 56 they're only allowed for the local fork
        require(
            !placeholder || block.chainid != 56 || keccak256(bytes(vm.envOr("QUDAO_DEPLOYMENT_NAME", string("")))) == keccak256("local"),
            "placeholder numbers on BSC mainnet: set the real numbers in config/protocol.json first"
        );

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        address[] memory admins = new address[](1);
        admins[0] = adminSafe;
        timelock = new TimelockController(delay, admins, admins, address(0));
        d = _deployQudao(Roles({owner: address(timelock), guardian: adminSafe, keeper: keeper, team: teamSafe}), chainKey, deployer);
        vm.stopBroadcast();

        _write(chainKey, d, timelock, adminSafe, teamSafe, keeper);
    }

    function _write(string memory chainKey, Deployment memory d, TimelockController t, address admin, address team, address keeper)
        internal
    {
        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "block", block.number);
        vm.serializeAddress(k, "timelock", address(t));
        vm.serializeAddress(k, "adminSafe", admin);
        vm.serializeAddress(k, "teamSafe", team);
        vm.serializeAddress(k, "keeper", keeper);
        vm.serializeAddress(k, "factory", address(d.factory));
        vm.serializeAddress(k, "vaultImplementation", address(d.vaultImplementation));
        vm.serializeAddress(k, "swapper", address(d.swapper));
        vm.serializeAddress(k, "oracle", address(d.oracle));
        vm.serializeAddress(k, "revenueRouter", address(d.router));
        vm.serializeAddress(k, "referrals", address(d.referrals));
        vm.serializeAddress(k, "well", address(d.well));
        vm.serializeAddress(k, "buybackBurner", address(d.burner));
        vm.serializeAddress(k, "safetyFund", address(d.safetyFund));
        vm.serializeAddress(k, "boostReserve", address(d.boostReserve));
        string memory out = vm.serializeAddress(k, "expansionReserve", address(d.expansionReserve));
        string memory name = vm.envOr("QUDAO_DEPLOYMENT_NAME", chainKey);
        string memory path = string.concat(vm.projectRoot(), "/deployments/", name, ".json");
        vm.writeJson(out, path);
        console2.log("Deployment written to", path);
    }
}
