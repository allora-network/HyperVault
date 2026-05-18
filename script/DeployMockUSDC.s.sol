// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";

/// @notice Deploys a MockUSDC ERC20 on the connected chain and mints a fixed
///         amount to the deployer. For HyperEVM testnet, where there is no
///         real linked USDC ERC20, this token serves as the vault asset.
///
/// Usage:
///     MINT_TO=0x...                              # default: deployer
///     MINT_AMOUNT_USDC=100000                    # default: 100k (in human USDC, 6dp)
///     forge script script/DeployMockUSDC.s.sol \
///         --rpc-url $HYPEREVM_RPC_TESTNET --broadcast
contract DeployMockUSDC is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address mintTo = vm.envOr("MINT_TO", deployer);
        uint256 humanAmount = vm.envOr("MINT_AMOUNT_USDC", uint256(100_000));

        vm.startBroadcast(pk);
        MockUSDC usdc = new MockUSDC();
        usdc.mint(mintTo, humanAmount * 1e6);
        vm.stopBroadcast();

        console2.log("MockUSDC deployed at:", address(usdc));
        console2.log("Minted to:           ", mintTo);
        console2.log("Amount (human USDC): ", humanAmount);
        console2.log("\nUse this address as `usdcAddress` in your deployments/configs/<strategy>.json");
    }
}
