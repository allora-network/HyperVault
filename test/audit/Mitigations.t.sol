// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {VaultBaseTest} from "../unit/Base.t.sol";
import {HyperCoreVault} from "../../src/HyperCoreVault.sol";
import {IHyperCoreVault} from "../../src/interfaces/IHyperCoreVault.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {AssetId} from "../../src/libraries/AssetId.sol";
import {PrecompileLib} from "../../src/libraries/PrecompileLib.sol";
import {MockPrecompiles} from "../mocks/MockPrecompiles.sol";

/// @title  Mitigations — positive regression tests for the seven audit fixes
///
/// For each CRITICAL/HIGH finding, this suite either:
///   (a) reproduces the original exploit attempt and asserts that the
///       defensive code in `HyperCoreVault` (or `PrecompileLib`) blocks it, OR
///   (b) for opt-in mitigations (H-1, H-3), enables the protection via the
///       new admin surface, then asserts the previously-exploitable behaviour
///       now reverts.
contract MitigationsTest is VaultBaseTest {
    address internal constant ATTACKER = address(0xBADD);
    address internal constant THIEF    = address(0xBEEF);
    address internal constant TREASURY = address(0xFEED);

    // -------------------------------------------------------------------------
    // C-1 — sweep() must NOT drain the vault's own share token (escrow)
    // -------------------------------------------------------------------------
    function test_C1_sweep_blocksVaultShareToken() public {
        _depositAs(alice, 1_000 * 1e6);
        uint256 aliceShares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.requestWithdraw(aliceShares);
        assertEq(vault.balanceOf(address(vault)), aliceShares, "escrow seeded");

        // The original attack: admin sweeps the share token to attacker.
        vm.prank(admin);
        vm.expectRevert(IHyperCoreVault.SweepingAsset.selector);
        vault.sweep(IERC20(address(vault)), THIEF);

        // Escrow untouched. Alice can still fulfil/cancel normally.
        assertEq(vault.balanceOf(address(vault)), aliceShares, "escrow intact");

        vm.prank(alice);
        vault.cancelWithdrawRequest();
        assertEq(vault.balanceOf(alice), aliceShares, "alice got her shares back");

        // Sanity: sweep of underlying `asset()` is still blocked too.
        vm.prank(admin);
        vm.expectRevert(IHyperCoreVault.SweepingAsset.selector);
        vault.sweep(IERC20(address(usdc)), THIEF);

        // Sanity: a genuinely foreign token may still be swept.
        // (Not exercised here — covered by the existing test/unit suite.)

        console2.log("=== C-1 mitigated: sweep() rejects vault's own share token ===");
    }

    // -------------------------------------------------------------------------
    // C-2 — operatorRecoverSpot requires destination to be on the allowlist
    // -------------------------------------------------------------------------
    function test_C2_operatorRecoverSpot_requiresAllowlistedDest() public {
        MockPrecompiles.setSpotBalance(vm, address(vault), Constants.USDC_CORE_INDEX, 1_000_000 * 1e8, 0);

        // The original attack: OPERATOR drains to attacker.
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IHyperCoreVault.SpotRecoverDestinationNotAllowed.selector, ATTACKER)
        );
        vault.operatorRecoverSpot(ATTACKER, Constants.USDC_CORE_INDEX, 1_000_000 * 1e8);

        // Defensive path: admin allowlists a treasury; operator may now send only there.
        vm.prank(admin);
        vault.setSpotRecoverDest(TREASURY, true);

        uint256 actionsBefore = _coreWriter().actionCount();
        vm.prank(operator);
        vault.operatorRecoverSpot(TREASURY, Constants.USDC_CORE_INDEX, 1_000_000 * 1e8);
        assertEq(_coreWriter().actionCount(), actionsBefore + 1, "allowlisted send succeeded");

        // Admin can also revoke; subsequent attempts revert.
        vm.prank(admin);
        vault.setSpotRecoverDest(TREASURY, false);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IHyperCoreVault.SpotRecoverDestinationNotAllowed.selector, TREASURY)
        );
        vault.operatorRecoverSpot(TREASURY, Constants.USDC_CORE_INDEX, 1_000_000 * 1e8);

        console2.log("=== C-2 mitigated: operatorRecoverSpot gated on allowlist ===");
    }

    function test_C2_setSpotRecoverDest_revertsForNonAdmin() public {
        vm.prank(operator);
        vm.expectRevert(); // AccessControlUnauthorizedAccount
        vault.setSpotRecoverDest(TREASURY, true);
    }

    // -------------------------------------------------------------------------
    // C-3 — perf fee comes out of LP's payout (USDC), not via dilution
    // -------------------------------------------------------------------------
    function test_C3_perfFee_noDilutionOfOtherLPs() public {
        // Same scenario as the original exploit: two LPs, 10% NAV gain,
        // Alice exits. Under the fix, Alice should receive ~54_250 (intended)
        // and Bob's stake should remain ~55_000 (no dilution).
        _depositAs(alice, 50_000 * 1e6);
        _depositAs(bob,   50_000 * 1e6);
        usdc.mint(address(vault), 10_000 * 1e6);

        uint256 bobValueBefore = vault.convertToAssets(vault.balanceOf(bob));
        uint256 feeUsdcBefore  = usdc.balanceOf(feeWallet);
        assertApproxEqRel(bobValueBefore, 55_000 * 1e6, 0.001e18, "Bob ~ 55k pre-redeem");

        uint256 aliceSharesAll = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 aliceOut = vault.redeem(aliceSharesAll, alice, alice);

        // Alice receives ~54_250 (NOT over-paid).
        assertApproxEqRel(aliceOut, 54_250 * 1e6, 0.005e18, "Alice gets intended payout");

        // Bob's stake is unchanged within rounding (NOT silently taxed).
        uint256 bobValueAfter = vault.convertToAssets(vault.balanceOf(bob));
        assertApproxEqRel(bobValueAfter, bobValueBefore, 0.001e18, "Bob untouched");

        // Fee recipient gets USDC (not shares) ≈ 15% of Alice's 5k gain = 750.
        uint256 feeUsdcGained = usdc.balanceOf(feeWallet) - feeUsdcBefore;
        assertApproxEqRel(feeUsdcGained, 750 * 1e6, 0.005e18, "fee = 15% of Alice's gain");
        assertEq(vault.balanceOf(feeWallet), 0, "no fee SHARES minted");

        console2.log("=== C-3 mitigated ===");
        console2.log("Alice payout (USDC, 6dp):", aliceOut);
        console2.log("Bob before   (USDC, 6dp):", bobValueBefore);
        console2.log("Bob after    (USDC, 6dp):", bobValueAfter);
        // Bob may move by 1 wei in either direction due to floor rounding in
        // the single-pass fee estimate; that's the entire "dilution" budget.
        console2.log("Fee recipient USDC gained:", feeUsdcGained);
    }

    // -------------------------------------------------------------------------
    // H-1 — strict NAV reads (opt-in) revert on precompile failure
    // -------------------------------------------------------------------------
    function test_H1_strictNavReads_revertOnPrecompileFailure() public {
        _depositAs(alice, 1_000 * 1e6);
        MockPrecompiles.setSpotBalance(vm, address(vault), Constants.USDC_CORE_INDEX, 100_000 * 1e8, 0);
        assertApproxEqRel(vault.totalAssets(), 101_000 * 1e6, 0.001e18, "NAV ~ 101k");

        // Admin enables strict mode (after the vault's Core account is initialised).
        vm.prank(admin);
        vault.setStrictNavReads(true);
        assertTrue(vault.strictNavReads(), "strict mode enabled");

        // Force the precompile to revert.
        vm.mockCallRevert(
            Constants.SPOT_BALANCE_PRECOMPILE,
            abi.encode(address(vault), Constants.USDC_CORE_INDEX),
            "precompile down"
        );

        // NAV reads now revert instead of silently zeroing.
        vm.expectRevert(
            abi.encodeWithSelector(PrecompileLib.PrecompileRevert.selector, Constants.SPOT_BALANCE_PRECOMPILE)
        );
        vault.coreSpotUsdc();

        vm.expectRevert(
            abi.encodeWithSelector(PrecompileLib.PrecompileRevert.selector, Constants.SPOT_BALANCE_PRECOMPILE)
        );
        vault.totalAssets();

        // Bob's deposit would otherwise mint inflated shares against a phantom-zero NAV;
        // under strict mode it reverts (forcing a real-time fix instead of silent loss).
        vm.startPrank(bob);
        usdc.approve(address(vault), 1_000 * 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(PrecompileLib.PrecompileRevert.selector, Constants.SPOT_BALANCE_PRECOMPILE)
        );
        vault.deposit(1_000 * 1e6, bob);
        vm.stopPrank();

        console2.log("=== H-1 mitigated: strict mode fails NAV reads loudly ===");
    }

    // Documents the residual risk: with strict mode OFF (default), the
    // original silent-fallback behaviour is preserved for fresh-vault
    // compatibility. Admin MUST enable strict mode post-first-activity.
    function test_H1_strictNavReads_defaultIsLenient() public view {
        assertFalse(vault.strictNavReads(), "default is lenient (opt-in)");
    }

    // -------------------------------------------------------------------------
    // H-2 — leverage cap uses strict markPx (no silent skip)
    // -------------------------------------------------------------------------
    function test_H2_leverageCap_failsClosedOnStaleMarkPx() public {
        _depositAs(alice, 1_000 * 1e6);
        _whitelistPerp(0);
        _whitelistPerp(1);
        MockPrecompiles.setOraclePx(vm, 0, 1);
        MockPrecompiles.setMarkPx(vm, 0, 1);
        MockPrecompiles.setOraclePx(vm, 1, 1);
        MockPrecompiles.setMarkPx(vm, 1, 1);
        MockPrecompiles.setPosition(vm, address(vault), 0, int64(2_900_000_000), 0);
        MockPrecompiles.setPosition(vm, address(vault), 1, int64(0), 0);

        // Original exploit: with BTC markPx reverting, the cap would silently
        // skip BTC and let ETH stack 4.9× leverage. Under the fix, the trade
        // reverts because markPxStrict propagates the failure.
        vm.mockCallRevert(
            Constants.MARK_PX_PRECOMPILE,
            abi.encode(uint32(0)),
            "mark down"
        );

        uint256 actionsBefore = _coreWriter().actionCount();
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(PrecompileLib.PrecompileRevert.selector, Constants.MARK_PX_PRECOMPILE)
        );
        vault.placeLimitOrder(1, true, 100, 2_000_000_000, false, Constants.TIF_GTC);
        assertEq(_coreWriter().actionCount(), actionsBefore, "no action dispatched");

        console2.log("=== H-2 mitigated: leverage cap reverts on missing markPx ===");
    }

    function test_H2_leverageCap_failsClosedOnZeroMarkPx() public {
        _depositAs(alice, 1_000 * 1e6);
        _whitelistPerp(0);
        MockPrecompiles.setOraclePx(vm, 0, 1);
        MockPrecompiles.setMarkPx(vm, 0, 0); // zero — should be rejected as invalid
        MockPrecompiles.setPosition(vm, address(vault), 0, int64(100), 0);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(PrecompileLib.PrecompileZero.selector, Constants.MARK_PX_PRECOMPILE)
        );
        vault.placeLimitOrder(0, true, 100, 1, false, Constants.TIF_GTC);
    }

    // -------------------------------------------------------------------------
    // H-3 — per-spot-asset slippage band (opt-in) blocks far-off-price spot orders
    // -------------------------------------------------------------------------
    function test_H3_spotSlippageBand_blocksFarOffPrice() public {
        _depositAs(alice, 1_000 * 1e6);
        uint32 spotAsset = 10_000; // AssetId.spot(0)

        vm.prank(admin);
        vault.setWhitelistSpot(spotAsset, true);

        // Default state: spotSlippageBandBps[spotAsset] = 0 — no band.
        // Admin opts in by setting a tight band (1%).
        vm.prank(admin);
        vault.setSpotSlippageBand(spotAsset, 100); // 100 bps = 1%
        assertEq(vault.spotSlippageBandBps(spotAsset), 100);

        // Provide a sane spotPx (e.g. 1_000 in the precompile's scale).
        MockPrecompiles.setSpotBalance(vm, address(vault), Constants.USDC_CORE_INDEX, 0, 0);
        vm.mockCall(
            Constants.SPOT_PX_PRECOMPILE,
            abi.encode(uint32(0)), // AssetId.indexOf(spotAsset)
            abi.encode(uint64(1_000))
        );

        // Original exploit: spot order at MAX UINT64 price. Now rejected.
        vm.prank(operator);
        vm.expectRevert(); // SlippageBandExceeded
        vault.placeLimitOrder(spotAsset, true, type(uint64).max, 1, false, Constants.TIF_GTC);

        // On-band order at the same scale succeeds.
        uint256 actionsBefore = _coreWriter().actionCount();
        vm.prank(operator);
        vault.placeLimitOrder(spotAsset, true, 1_005, 1, false, Constants.TIF_GTC); // +0.5% off mid
        assertEq(_coreWriter().actionCount(), actionsBefore + 1, "on-band spot order accepted");

        console2.log("=== H-3 mitigated: per-spot-asset slippage band enforces price sanity ===");
    }

    function test_H3_spotSlippageBand_defaultIsDisabled() public view {
        assertEq(vault.spotSlippageBandBps(10_000), 0, "default off (opt-in)");
    }

    // -------------------------------------------------------------------------
    // H-4 — perp slippage check uses strict oraclePx (no silent skip)
    // -------------------------------------------------------------------------
    function test_H4_slippageBand_failsClosedOnOracleRevert() public {
        _depositAs(alice, 1_000 * 1e6);
        _whitelistPerp(0);
        MockPrecompiles.setPosition(vm, address(vault), 0, int64(0), 0);
        MockPrecompiles.setMarkPx(vm, 0, 1);

        vm.mockCallRevert(
            Constants.ORACLE_PX_PRECOMPILE,
            abi.encode(uint32(0)),
            "oracle down"
        );

        // Under the fix, the slippage check itself reverts (PrecompileRevert)
        // instead of silently skipping.
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(PrecompileLib.PrecompileRevert.selector, Constants.ORACLE_PX_PRECOMPILE)
        );
        vault.placeLimitOrder(0, true, 200, 1, false, Constants.TIF_GTC);

        console2.log("=== H-4 mitigated: slippage check reverts on missing oracle ===");
    }

    function test_H4_slippageBand_failsClosedOnZeroOracle() public {
        _depositAs(alice, 1_000 * 1e6);
        _whitelistPerp(0);
        MockPrecompiles.setPosition(vm, address(vault), 0, int64(0), 0);
        MockPrecompiles.setMarkPx(vm, 0, 1);
        MockPrecompiles.setOraclePx(vm, 0, 0); // zero — invalid live price

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(PrecompileLib.PrecompileZero.selector, Constants.ORACLE_PX_PRECOMPILE)
        );
        vault.placeLimitOrder(0, true, 200, 1, false, Constants.TIF_GTC);
    }
}
