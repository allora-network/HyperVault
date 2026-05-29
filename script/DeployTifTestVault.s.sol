// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HyperCoreVault} from "../src/HyperCoreVault.sol";

/// @notice Throwaway TEST vault to confirm the v1.3 px/sz-scale + TIF fixes on
///         the live contract path (band + leverage-cap gates exercised with a
///         real BTC perp). admin/operator/emergency are all the deployer for
///         hands-on control + fund recovery. NOT a production deployment — the
///         real flow uses a per-vault TimelockController (see Deploy.s.sol).
contract DeployTifTestVault is Script {
    function run() external {
        address op = vm.envAddress("OPERATOR_ADDR");
        // Existing mainnet USDC used by tier2b (6 decimals); only matters for
        // NAV/ERC4626 wiring — the order test funds perp margin via send_asset.
        address usdc = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;

        HyperCoreVault.Config memory cfg = HyperCoreVault.Config({
            asset: IERC20(usdc),
            name: "TIF Scale Test",
            symbol: "tifscale",
            admin: op,
            operator: op,
            emergencyAdmin: op,
            feeRecipient: op,
            leverageCapBps: 30_000, // 3x — exercises the corrected /1e10 notional
            slippageBandBps: 200,   // 2% — exercises the corrected x10^(2+szDec) band
            mgmtFeeAnnualBps: 0,
            perfFeeBps: 0,
            depositCap: 1_000_000_000_000,
            maxDepositPerAddress: 100_000_000_000
        });

        vm.startBroadcast();
        HyperCoreVault vault = new HyperCoreVault(cfg);
        vm.stopBroadcast();

        console2.log("TIF test vault deployed at:", address(vault));
    }
}
