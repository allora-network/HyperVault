// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {HyperCoreVault} from "../src/HyperCoreVault.sol";
import {HyperCoreVaultRegistry} from "../src/HyperCoreVaultRegistry.sol";

/// @notice Per-strategy deploy. Reads a JSON config from $STRATEGY_CONFIG and
///         deploys: TimelockController → HyperCoreVault → registers it →
///         optionally seeds the asset whitelist (when delay=0).
///
///   STRATEGY_CONFIG=deployments/configs/smoke.json \
///     forge script script/Deploy.s.sol \
///       --rpc-url $HYPEREVM_RPC_TESTNET \
///       --broadcast
contract Deploy is Script {
    string constant VERSION = "v1.0.0";

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        string memory configPath = vm.envString("STRATEGY_CONFIG");
        address registryAddr = _registryFor(block.chainid);
        require(registryAddr != address(0), "Set REGISTRY_TESTNET / REGISTRY_MAINNET in env");

        string memory json = vm.readFile(configPath);

        HyperCoreVault.Config memory cfg;
        cfg.asset                = IERC20(vm.parseJsonAddress(json, ".usdcAddress"));
        cfg.coreUsdcIndex        = uint64(vm.parseJsonUint(json, ".coreUsdcIndex"));
        cfg.coreUsdcDecimals     = uint8(vm.parseJsonUint(json, ".coreUsdcDecimals"));
        cfg.name                 = vm.parseJsonString(json, ".name");
        cfg.symbol               = vm.parseJsonString(json, ".symbol");
        cfg.operator             = vm.parseJsonAddress(json, ".operator");
        cfg.emergencyAdmin       = vm.parseJsonAddress(json, ".emergencyAdmin");
        cfg.feeRecipient         = vm.parseJsonAddress(json, ".feeRecipient");
        cfg.leverageCapBps       = uint16(vm.parseJsonUint(json, ".leverageCapBps"));
        cfg.slippageBandBps      = uint16(vm.parseJsonUint(json, ".slippageBandBps"));
        cfg.mgmtFeeAnnualBps     = uint16(vm.parseJsonUint(json, ".mgmtFeeAnnualBps"));
        cfg.perfFeeBps           = uint16(vm.parseJsonUint(json, ".perfFeeBps"));
        cfg.depositCap           = vm.parseJsonUint(json, ".depositCap");
        cfg.maxDepositPerAddress = vm.parseJsonUint(json, ".maxDepositPerAddress");

        uint256 timelockDelay = vm.parseJsonUint(json, ".timelockMinDelaySec");
        uint256[] memory perpWhitelist = vm.parseJsonUintArray(json, ".whitelistPerps");
        uint256[] memory spotWhitelist = vm.parseJsonUintArray(json, ".whitelistSpots");

        vm.startBroadcast(pk);

        // 1. Per-vault TimelockController (proposer+executor = deployer)
        address[] memory proposers = new address[](1); proposers[0] = deployer;
        address[] memory executors = new address[](1); executors[0] = deployer;
        TimelockController timelock = new TimelockController(timelockDelay, proposers, executors, deployer);
        cfg.admin = address(timelock);

        // 2. Vault — plain CREATE (we skipped the CREATE2 factory; addresses
        //    derived from deployer nonce instead)
        HyperCoreVault vault = new HyperCoreVault(cfg);

        // 3. Register
        HyperCoreVaultRegistry registry = HyperCoreVaultRegistry(registryAddr);
        registry.register(HyperCoreVaultRegistry.VaultMetadata({
            vault: address(vault),
            asset: address(cfg.asset),
            operator: cfg.operator,
            timelock: address(timelock),
            name: cfg.name,
            symbol: cfg.symbol,
            version: VERSION,
            deployBlock: uint64(block.number)
        }));

        // 4. Seed whitelist via timelock when delay=0 (testnet bootstrap)
        if (timelockDelay == 0 && (perpWhitelist.length + spotWhitelist.length) > 0) {
            _seedWhitelistViaTimelock(timelock, address(vault), perpWhitelist, spotWhitelist);
        }

        vm.stopBroadcast();

        console2.log("Vault:    ", address(vault));
        console2.log("Timelock: ", address(timelock));
        console2.log("Operator: ", cfg.operator);

        _writeArtifact(configPath, cfg, address(vault), address(timelock), registryAddr, perpWhitelist, spotWhitelist);

        console2.log("\nNext steps:");
        console2.log(" 1. Opt the vault into HyperEVM big blocks via HL API (see docs/INTEGRATION.md)");
        if (timelockDelay > 0) {
            console2.log(" 2. After the timelock delay, schedule + execute setWhitelistPerp / setWhitelistSpot");
        } else {
            console2.log(" 2. Whitelist seeded (delay=0 bootstrap)");
        }
        console2.log(" 3. Run the frontend and confirm vault appears in registry");
    }

    function _seedWhitelistViaTimelock(
        TimelockController tl,
        address vaultAddr,
        uint256[] memory perps,
        uint256[] memory spots
    ) internal {
        uint256 total = perps.length + spots.length;
        address[] memory targets = new address[](total);
        uint256[] memory values = new uint256[](total);
        bytes[] memory payloads = new bytes[](total);
        uint256 i;
        for (uint256 j; j < perps.length; ++j) {
            targets[i] = vaultAddr;
            values[i] = 0;
            payloads[i] = abi.encodeCall(HyperCoreVault.setWhitelistPerp, (uint32(perps[j]), true));
            i++;
        }
        for (uint256 j; j < spots.length; ++j) {
            targets[i] = vaultAddr;
            values[i] = 0;
            payloads[i] = abi.encodeCall(HyperCoreVault.setWhitelistSpot, (uint32(spots[j]), true));
            i++;
        }
        bytes32 predecessor = bytes32(0);
        bytes32 salt = keccak256(abi.encode("whitelist-seed", block.chainid, vaultAddr));
        tl.scheduleBatch(targets, values, payloads, predecessor, salt, 0);
        tl.executeBatch(targets, values, payloads, predecessor, salt);
        console2.log("Whitelist seeded via timelock:");
        console2.log("  perps:", perps.length);
        console2.log("  spots:", spots.length);
    }

    function _writeArtifact(
        string memory configPath,
        HyperCoreVault.Config memory cfg,
        address vaultAddr,
        address timelockAddr,
        address registryAddr,
        uint256[] memory perpWhitelist,
        uint256[] memory spotWhitelist
    ) internal {
        string memory path = string.concat("deployments/", _chainDir(), "/", _stripPath(configPath));
        string memory j = _buildArtifactJson(cfg, vaultAddr, timelockAddr, registryAddr, perpWhitelist, spotWhitelist);
        vm.writeFile(path, j);
        console2.log("Artifact written:", path);
    }

    function _buildArtifactJson(
        HyperCoreVault.Config memory cfg,
        address vaultAddr,
        address timelockAddr,
        address registryAddr,
        uint256[] memory perpWhitelist,
        uint256[] memory spotWhitelist
    ) internal view returns (string memory) {
        string memory head = string.concat(
            "{\n",
            "  \"chainId\": ", vm.toString(block.chainid), ",\n",
            "  \"vault\": \"", vm.toString(vaultAddr), "\",\n",
            "  \"timelock\": \"", vm.toString(timelockAddr), "\",\n",
            "  \"registry\": \"", vm.toString(registryAddr), "\",\n",
            "  \"asset\": \"", vm.toString(address(cfg.asset)), "\",\n"
        );
        string memory body = string.concat(
            "  \"operator\": \"", vm.toString(cfg.operator), "\",\n",
            "  \"feeRecipient\": \"", vm.toString(cfg.feeRecipient), "\",\n",
            "  \"name\": \"", cfg.name, "\",\n",
            "  \"symbol\": \"", cfg.symbol, "\",\n",
            "  \"deployBlock\": ", vm.toString(block.number), ",\n"
        );
        string memory tail = string.concat(
            "  \"leverageCapBps\": ", vm.toString(cfg.leverageCapBps), ",\n",
            "  \"perfFeeBps\": ", vm.toString(cfg.perfFeeBps), ",\n",
            "  \"mgmtFeeAnnualBps\": ", vm.toString(cfg.mgmtFeeAnnualBps), ",\n",
            "  \"whitelistPerps\": ", _uintArrayToJson(perpWhitelist), ",\n",
            "  \"whitelistSpots\": ", _uintArrayToJson(spotWhitelist), "\n",
            "}\n"
        );
        return string.concat(head, body, tail);
    }

    function _registryFor(uint256 chainId) internal view returns (address) {
        if (chainId == 999) return vm.envOr("REGISTRY_MAINNET", address(0));
        if (chainId == 998) return vm.envOr("REGISTRY_TESTNET", address(0));
        return vm.envOr("REGISTRY_LOCAL", address(0));
    }

    function _chainDir() internal view returns (string memory) {
        if (block.chainid == 999) return "mainnet";
        if (block.chainid == 998) return "testnet";
        return "local";
    }

    function _stripPath(string memory full) internal pure returns (string memory) {
        bytes memory b = bytes(full);
        uint256 lastSlash;
        for (uint256 i; i < b.length; ++i) {
            if (b[i] == "/") lastSlash = i + 1;
        }
        bytes memory out = new bytes(b.length - lastSlash);
        for (uint256 i; i < out.length; ++i) out[i] = b[lastSlash + i];
        return string(out);
    }

    function _uintArrayToJson(uint256[] memory arr) internal pure returns (string memory) {
        if (arr.length == 0) return "[]";
        string memory s = "[";
        for (uint256 i; i < arr.length; ++i) {
            s = string.concat(s, vm.toString(arr[i]));
            if (i + 1 < arr.length) s = string.concat(s, ",");
        }
        return string.concat(s, "]");
    }
}
