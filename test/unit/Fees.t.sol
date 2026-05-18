// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {VaultBaseTest} from "./Base.t.sol";

contract FeesTest is VaultBaseTest {
    // Mgmt fee: 2%/yr. After 1 year, fee shares = ~2% of NAV worth.
    function test_mgmtFee_accruesOverTime() public {
        _depositAs(alice, 100_000 * 1e6);
        uint256 supplyBefore = vault.totalSupply();
        uint256 feeBefore = vault.balanceOf(feeWallet);

        // Skip 1 year
        vm.warp(block.timestamp + 365 days);

        // Trigger accrual via setFees — that's the admin call that accrues at the old rate
        vm.prank(admin);
        vault.setFees(MGMT_FEE, PERF_FEE);

        uint256 feeShares = vault.balanceOf(feeWallet) - feeBefore;
        assertGt(feeShares, 0);
        // Fee recipient should own ~2% of total value
        uint256 supplyAfter = vault.totalSupply();
        uint256 feeFraction = (feeShares * 1e18) / supplyAfter;
        assertApproxEqRel(feeFraction, 0.02e18, 0.01e18); // ~2% ± 1% relative
        // sanity: supply grew
        assertGt(supplyAfter, supplyBefore);
    }

    function test_mgmtFee_zeroIfNoTime() public {
        _depositAs(alice, 100_000 * 1e6);
        uint256 feeBefore = vault.balanceOf(feeWallet);
        // No time passes between deposit and another accrual trigger
        vm.prank(admin);
        vault.setFees(MGMT_FEE, PERF_FEE);
        assertEq(vault.balanceOf(feeWallet), feeBefore);
    }

    function test_perfFee_chargesOnGain() public {
        _depositAs(alice, 100_000 * 1e6);
        // Simulate gain by minting extra USDC into vault (50% gain → 50k extra)
        usdc.mint(address(vault), 50_000 * 1e6);

        // Post-audit C-3: perf fee is paid in `asset()` directly to feeRecipient
        // (no share mint, no dilution). Assert on USDC balance, not share balance.
        uint256 feeUsdcBefore = usdc.balanceOf(feeWallet);
        uint256 sharesAlice = vault.balanceOf(alice);

        vm.startPrank(alice);
        uint256 assetsOut = vault.redeem(sharesAlice, alice, alice);
        vm.stopPrank();

        uint256 feeUsdcGained = usdc.balanceOf(feeWallet) - feeUsdcBefore;
        assertGt(feeUsdcGained, 0, "fee recipient received USDC");
        // Gain was 50k USDC. Perf fee at 15% on gain = 7500 USDC. Alice should
        // receive approximately 150k - 7500 = 142500 USDC.
        assertApproxEqRel(assetsOut, 142_500 * 1e6, 0.02e18);
        // Fee paid should be ~7500 USDC (15% of 50k gain).
        assertApproxEqRel(feeUsdcGained, 7_500 * 1e6, 0.02e18);
        // No fee shares minted (audit C-3 fix).
        assertEq(vault.balanceOf(feeWallet), 0, "no fee shares minted");
    }

    function test_perfFee_noChargeWithoutGain() public {
        _depositAs(alice, 100_000 * 1e6);
        uint256 feeUsdcBefore = usdc.balanceOf(feeWallet);
        uint256 sharesAlice = vault.balanceOf(alice);

        vm.startPrank(alice);
        vault.redeem(sharesAlice, alice, alice);
        vm.stopPrank();

        // Neither USDC nor shares accrue to feeRecipient when there's no gain.
        assertEq(usdc.balanceOf(feeWallet), feeUsdcBefore);
        assertEq(vault.balanceOf(feeWallet), 0);
    }
}
