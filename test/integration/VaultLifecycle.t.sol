// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {VaultBaseTest} from "../unit/Base.t.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {MockPrecompiles} from "../mocks/MockPrecompiles.sol";

/// @notice End-to-end lifecycle test.
///
///         Flow:
///           1. Two LPs deposit
///           2. Operator pushes idle USDC to Core spot
///           3. Operator transfers USD class to perp
///           4. Operator places a limit order (cap + slippage gates exercised)
///           5. (Simulated) Core position gains value
///           6. Operator transfers margin back to spot, pulls spot back to EVM
///           7. LPs redeem; perf fee crystallizes on the gain
///
///         For a "real" integration test against the actual CoreSimulator
///         from `hyperliquid-dev/hyper-evm-lib`, install that library and
///         replace the mocked precompile responses with simulator calls.
contract VaultLifecycleTest is VaultBaseTest {
    uint32 constant BTC_PERP = 0;

    function test_full_lifecycle() public {
        // 1. Two LPs deposit 50k each
        _depositAs(alice, 50_000 * 1e6);
        _depositAs(bob, 50_000 * 1e6);
        assertEq(vault.totalAssets(), 100_000 * 1e6);

        // 2. Whitelist BTC perp; set price + mark
        _whitelistPerp(BTC_PERP);
        // Oracle precompile in 6-dec scale; limit-order action in 8-dec scale.
        // For BTC at $50k with szDecimals=5: oraclePx raw = 50_000 * 10 = 500_000.
        MockPrecompiles.setOraclePx(vm, BTC_PERP, 500_000);
        MockPrecompiles.setMarkPx(vm, BTC_PERP, 500_000);
        MockPrecompiles.setPosition(vm, address(vault), BTC_PERP, 0, 0);

        // 3. Operator pushes 80k to Core, then 70k of that to perp margin
        vm.startPrank(operator);
        vault.pushToCore(80_000 * 1e6);
        // Simulate the bridge crediting Core spot
        MockPrecompiles.setSpotBalance(vm, address(vault), Constants.USDC_CORE_INDEX, 80_000 * 1e8, 0);
        // usd_class_transfer to move 70k from spot → perp
        vault.usdSpotToPerp(70_000 * 1e6);
        MockPrecompiles.setSpotBalance(vm, address(vault), Constants.USDC_CORE_INDEX, 10_000 * 1e8, 0);
        MockPrecompiles.setWithdrawable(vm, address(vault), 70_000 * 1e6);

        // NAV unchanged after internal moves
        assertEq(vault.totalAssets(), 100_000 * 1e6);

        // 4. Operator places a tiny limit order
        uint128 cloid = // limit price 50_000_000 = $50k in 8-dec scale (szDec=5 → 10^3 multiplier)
vault.placeLimitOrder(BTC_PERP, true, 50_000_000, 1, false, Constants.TIF_GTC);
        assertEq(cloid, 1);
        vm.stopPrank();

        // 5. Simulate gain: perp withdrawable grows by 10k (PnL realized + funding)
        MockPrecompiles.setWithdrawable(vm, address(vault), 80_000 * 1e6);
        assertEq(vault.totalAssets(), 110_000 * 1e6);

        // 6. Operator pulls everything back to EVM (simulated by mock state)
        vm.startPrank(operator);
        vault.usdPerpToSpot(80_000 * 1e6);
        MockPrecompiles.setWithdrawable(vm, address(vault), 0);
        MockPrecompiles.setSpotBalance(vm, address(vault), Constants.USDC_CORE_INDEX, 90_000 * 1e8, 0);
        vault.pullFromCore(90_000 * 1e8);
        // Simulate the bridge crediting the EVM ERC20
        usdc.mint(address(vault), 90_000 * 1e6 - usdc.balanceOf(address(vault)) + 20_000 * 1e6);
        MockPrecompiles.setSpotBalance(vm, address(vault), Constants.USDC_CORE_INDEX, 0, 0);
        vm.stopPrank();

        // NAV ≈ 110k
        assertApproxEqRel(vault.totalAssets(), 110_000 * 1e6, 0.01e18);

        // 7. Alice redeems → gets ~55k (her half) minus perf fee on gain
        uint256 aliceSharesBefore = vault.balanceOf(alice);
        uint256 feeUsdcBefore = usdc.balanceOf(feeWallet);
        vm.prank(alice);
        uint256 aliceOut = vault.redeem(aliceSharesBefore, alice, alice);

        // She put in 50k, NAV grew 10%, perf fee = 15% on the 10% gain
        // Expected ≈ 55,000 - (5,000 * 0.15) = 54,250
        assertApproxEqRel(aliceOut, 54_250 * 1e6, 0.02e18);
        // Post-audit C-3: perf fee paid in USDC (no share dilution).
        assertGt(usdc.balanceOf(feeWallet) - feeUsdcBefore, 0);
    }
}
