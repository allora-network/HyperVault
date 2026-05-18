// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {HyperCoreVaultRegistry} from "../src/HyperCoreVaultRegistry.sol";

/// @notice One-time-per-chain deploy of the vault registry. The factory is
///         intentionally omitted (its inlined `creationCode` exceeds EIP-170);
///         the registry is configured to also accept `owner()` as a writer so
///         `Deploy.s.sol` can register vaults directly via the deployer EOA.
///
///   forge script script/DeployRegistry.s.sol \
///     --rpc-url $HYPEREVM_RPC_TESTNET \
///     --broadcast
contract DeployRegistry is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        HyperCoreVaultRegistry registry = new HyperCoreVaultRegistry(deployer);
        // factory is left unset (address(0)); register() falls back to owner()
        vm.stopBroadcast();

        console2.log("Registry:", address(registry));
        console2.log("Owner:   ", deployer);

        string memory chainDir = _chainDir();
        string memory path = string.concat("deployments/", chainDir, "/registry.json");
        string memory json = string.concat(
            "{\n",
            "  \"chainId\": ", vm.toString(block.chainid), ",\n",
            "  \"registry\": \"", vm.toString(address(registry)), "\",\n",
            "  \"deployer\": \"", vm.toString(deployer), "\",\n",
            "  \"deployBlock\": ", vm.toString(block.number), "\n",
            "}\n"
        );
        vm.writeFile(path, json);
        console2.log("Artifact written:", path);
    }

    function _chainDir() internal view returns (string memory) {
        if (block.chainid == 999) return "mainnet";
        if (block.chainid == 998) return "testnet";
        return "local";
    }
}
