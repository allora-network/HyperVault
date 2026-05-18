// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {VaultBaseTest} from "./Base.t.sol";
import {Test, console2} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {HyperCoreVault} from "../../src/HyperCoreVault.sol";
import {IHyperCoreVault} from "../../src/interfaces/IHyperCoreVault.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {MockPrecompiles} from "../mocks/MockPrecompiles.sol";

contract HyperCoreVaultTest is VaultBaseTest {
    // -------------------------------------------------------------------------
    // ERC4626 basics
    // -------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(vault.name(), "Test Strategy");
        assertEq(vault.symbol(), "tSTR");
        assertEq(vault.asset(), address(usdc));
        // 6dp asset + 6dp offset = 12dp shares
        assertEq(vault.decimals(), 12);
    }

    function test_initialDeposit_setsCostBasis() public {
        uint256 shares = _depositAs(alice, 1_000 * 1e6);
        assertEq(vault.balanceOf(alice), shares);
        // First depositor: NAV = 1000 USDC (6dp = 1e9). With offset 6, shares
        // are 12dp. Conversion: 1e9 USDC → 1e9 * 1e6 = 1e15 shares.
        assertEq(vault.totalAssets(), 1_000 * 1e6);
        assertApproxEqRel(shares, 1e15, 0.001e18);
        // pps in WAD = nav * WAD / supply = 1e9 * 1e18 / 1e15 = 1e12.
        // This reflects the 6-decimal offset (1 share = 1e-6 USDC).
        uint256 pps = vault.pricePerShare();
        assertApproxEqRel(pps, 1e12, 0.001e18);
    }

    function test_secondDeposit_diluteToCorrectShares() public {
        _depositAs(alice, 1_000 * 1e6);
        uint256 sharesBob = _depositAs(bob, 1_000 * 1e6);
        // Both should have ~equal shares
        assertApproxEqRel(vault.balanceOf(alice), sharesBob, 0.001e18);
    }

    function test_withdraw_returnsAssets() public {
        _depositAs(alice, 1_000 * 1e6);
        vm.startPrank(alice);
        uint256 sharesBefore = vault.balanceOf(alice);
        uint256 assetsOut = vault.redeem(sharesBefore, alice, alice);
        vm.stopPrank();
        assertApproxEqRel(assetsOut, 1_000 * 1e6, 0.001e18);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_maxWithdraw_boundedByIdle() public {
        // Alice deposits 100 USDC
        _depositAs(alice, 100 * 1e6);
        // Simulate operator pushed 80 USDC to core (vault's idle drops to 20)
        vm.prank(address(vault));
        usdc.transfer(makeAddr("hl_bridge"), 80 * 1e6);
        // Now idle = 20; alice's shares are worth 100 USDC nominally
        // but maxWithdraw should be capped at 20 USDC
        uint256 maxW = vault.maxWithdraw(alice);
        assertEq(maxW, 20 * 1e6);
    }

    function test_deposit_revertsWhenPaused() public {
        vm.prank(emergency);
        vault.pause();
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000 * 1e6);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.deposit(1_000 * 1e6, alice);
        vm.stopPrank();
    }

    function test_redeem_allowedWhenPaused() public {
        _depositAs(alice, 1_000 * 1e6);
        vm.prank(emergency);
        vault.pause();
        vm.startPrank(alice);
        uint256 sharesBefore = vault.balanceOf(alice);
        // Should NOT revert — redeems must stay open even when paused
        vault.redeem(sharesBefore, alice, alice);
        vm.stopPrank();
    }

    function test_emergencyShutdown_blocksDeposits() public {
        _depositAs(alice, 1_000 * 1e6);
        vm.prank(emergency);
        vault.emergencyShutdown();
        vm.startPrank(bob);
        usdc.approve(address(vault), 1_000 * 1e6);
        vm.expectRevert(IHyperCoreVault.EmergencyShutdownActive.selector);
        vault.deposit(1_000 * 1e6, bob);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // NAV decomposition
    // -------------------------------------------------------------------------

    function test_totalAssets_sumsAllBuckets() public {
        // 1000 USDC idle on EVM, 500 USDC equivalent on core spot (8dp), 250 USDC in perp
        usdc.mint(address(vault), 1_000 * 1e6);
        MockPrecompiles.setSpotBalance(vm, address(vault), Constants.USDC_CORE_INDEX, 500 * 1e8, 0);
        MockPrecompiles.setWithdrawable(vm, address(vault), 250 * 1e6);

        uint256 expected = (1_000 + 500 + 250) * 1e6;
        assertEq(vault.totalAssets(), expected);
        assertEq(vault.idleUsdc(), 1_000 * 1e6);
        assertEq(vault.coreSpotUsdc(), 500 * 1e6);
        assertEq(vault.perpWithdrawable(), 250 * 1e6);
    }

    function test_coreSpot_decimalNormalization() public {
        // 1 USDC at 8dp Core = 1e8; should normalize to 1e6 at EVM 6dp
        MockPrecompiles.setSpotBalance(vm, address(vault), Constants.USDC_CORE_INDEX, 1e8, 0);
        assertEq(vault.coreSpotUsdc(), 1e6);
    }

    // -------------------------------------------------------------------------
    // Role gating
    // -------------------------------------------------------------------------

    function test_placeLimitOrder_revertsForNonOperator() public {
        _whitelistPerp(0);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, vault.OPERATOR_ROLE())
        );
        vm.prank(alice);
        vault.placeLimitOrder(0, true, 50_000_00000000, 100, false, Constants.TIF_GTC);
    }

    function test_setWhitelist_revertsForNonAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, vault.DEFAULT_ADMIN_ROLE())
        );
        vm.prank(operator);
        vault.setWhitelistPerp(0, true);
    }

    // -------------------------------------------------------------------------
    // Operator: trade gating
    // -------------------------------------------------------------------------

    function test_placeLimitOrder_assetMustBeWhitelisted() public {
        _depositAs(alice, 1_000 * 1e6);
        MockPrecompiles.setOraclePx(vm, 0, 50_000_00000000);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.AssetNotWhitelisted.selector, uint32(0)));
        vault.placeLimitOrder(0, true, 50_000_00000000, 100, false, Constants.TIF_GTC);
    }

    function test_placeLimitOrder_slippageBand() public {
        _depositAs(alice, 1_000 * 1e6);
        _whitelistPerp(0);
        MockPrecompiles.setPosition(vm, address(vault), 0, 0, 0);
        // Oracle precompile returns 6-dec-scale value; limit_order action uses
        // 8-dec scale. Ratio is 100×, so oracleNorm = oraclePxRaw * 100.
        // Set oraclePxRaw = 100 → oracleNorm = 10_000.
        MockPrecompiles.setOraclePx(vm, 0, 100);
        MockPrecompiles.setMarkPx(vm, 0, 100);

        // 2% off oracle (limitPx=10_200 vs oracleNorm=10_000) — at exactly the 1% band, should pass
        // Move farther: 2% off = limitPx=10_200 → diff=200, maxDiff=10_000*100/10000=100. 200>100 → revert
        vm.expectRevert();
        vm.prank(operator);
        vault.placeLimitOrder(0, true, 10_200, 1, false, Constants.TIF_GTC);

        // Within band (limitPx=10_000 = exactly on oracle) → OK
        vm.prank(operator);
        uint128 cloid = vault.placeLimitOrder(0, true, 10_000, 1, false, Constants.TIF_GTC);
        assertEq(cloid, 1);
    }

    function test_placeLimitOrder_leverageCap() public {
        _depositAs(alice, 1_000 * 1e6); // 1000 USDC NAV
        _whitelistPerp(0);
        // Oracle in 6dec scale = 1; limit in 8dec scale = 100 (1.0 px), on-band
        MockPrecompiles.setOraclePx(vm, 0, 1);
        MockPrecompiles.setMarkPx(vm, 0, 1);
        MockPrecompiles.setPosition(vm, address(vault), 0, 0, 0);

        // 3x cap → max notional = 3000 USDC = 3e9 (6dp).
        // new order notional6dp = sz * limitPx / 100. To exceed 3e9 with limitPx=100: sz > 3e9.
        vm.expectRevert();
        vm.prank(operator);
        vault.placeLimitOrder(0, true, 100, 3_000_000_001, false, Constants.TIF_GTC);

        // Within cap: sz = 1 → notional = 1 (6dp) → fits easily
        vm.prank(operator);
        uint128 cloid = vault.placeLimitOrder(0, true, 100, 1, false, Constants.TIF_GTC);
        assertEq(cloid, 1);
    }

    function test_placeLimitOrder_reduceOnly_bypassesLeverageCheck() public {
        _depositAs(alice, 1_000 * 1e6);
        _whitelistPerp(0);
        // oracle (6dec scale) = 1 → oracleNorm = 100. limit price = 100 (on-band).
        MockPrecompiles.setOraclePx(vm, 0, 1);
        MockPrecompiles.setMarkPx(vm, 0, 1);
        MockPrecompiles.setPosition(vm, address(vault), 0, 0, 0);

        // Big order with reduceOnly=true — should bypass leverage check
        vm.prank(operator);
        uint128 cloid = vault.placeLimitOrder(0, false, 100, 1_000_000_000_000, true, Constants.TIF_GTC);
        assertEq(cloid, 1);
    }

    function test_placeLimitOrder_writesToCoreWriter() public {
        _depositAs(alice, 1_000 * 1e6);
        _whitelistPerp(0);
        MockPrecompiles.setOraclePx(vm, 0, 1);
        MockPrecompiles.setMarkPx(vm, 0, 1);
        MockPrecompiles.setPosition(vm, address(vault), 0, 0, 0);

        vm.prank(operator);
        uint128 cloid = vault.placeLimitOrder(0, true, 100, 1, false, Constants.TIF_GTC);
        assertEq(cloid, 1);
        assertEq(_coreWriter().actionCount(), 1);
    }

    // -------------------------------------------------------------------------
    // Bridge ops
    // -------------------------------------------------------------------------

    function test_pushToCore_transfersToBridge() public {
        _depositAs(alice, 1_000 * 1e6);
        uint256 before = usdc.balanceOf(address(vault));
        vm.prank(operator);
        vault.pushToCore(100 * 1e6);
        assertEq(usdc.balanceOf(address(vault)), before - 100 * 1e6);
    }

    function test_pullFromCore_emitsSpotSendAction() public {
        vm.prank(operator);
        vault.pullFromCore(100 * 1e8); // 100 USDC at 8dp core wei
        assertEq(_coreWriter().actionCount(), 1);
    }

    function test_usdSpotToPerp_emitsClassTransfer() public {
        vm.prank(operator);
        vault.usdSpotToPerp(50 * 1e6);
        assertEq(_coreWriter().actionCount(), 1);
    }

    // -------------------------------------------------------------------------
    // Emergency
    // -------------------------------------------------------------------------

    function test_emergencyCancelByOid_callable() public {
        vm.prank(emergency);
        vault.emergencyCancelByOid(0, 12345);
        assertEq(_coreWriter().actionCount(), 1);
    }

    function test_emergencyCancelByOid_revertsForNonEmergency() public {
        vm.prank(operator);
        vm.expectRevert();
        vault.emergencyCancelByOid(0, 12345);
    }

    function test_emergencyClosePositions_iteratesOverPerps() public {
        _whitelistPerp(0);
        _whitelistPerp(1);
        // Mock positions: long 100 on perp 0, short 50 on perp 1
        MockPrecompiles.setPosition(vm, address(vault), 0, 100, 0);
        MockPrecompiles.setPosition(vm, address(vault), 1, -50, 0);

        uint32[] memory assets = new uint32[](2);
        assets[0] = 0;
        assets[1] = 1;
        uint64[] memory pxs = new uint64[](2);
        pxs[0] = 100;
        pxs[1] = 200;

        vm.prank(emergency);
        vault.emergencyClosePositions(assets, pxs);
        // Two orders submitted (one per perp with non-zero position)
        assertEq(_coreWriter().actionCount(), 2);
    }

    // -------------------------------------------------------------------------
    // Sweep
    // -------------------------------------------------------------------------

    function test_sweep_cannotSweepAsset() public {
        vm.prank(admin);
        vm.expectRevert(IHyperCoreVault.SweepingAsset.selector);
        vault.sweep(usdc, admin);
    }

    function test_operatorSweepStranded_recoversWhenSupplyZero() public {
        // donate 100 USDC to the empty vault (no LPs yet)
        usdc.mint(address(vault), 100 * 1e6);
        uint256 deployerBefore = usdc.balanceOf(address(0xBEEF));
        vm.prank(operator);
        vault.operatorSweepStranded(address(0xBEEF));
        assertEq(usdc.balanceOf(address(0xBEEF)) - deployerBefore, 100 * 1e6);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_operatorSweepStranded_revertsWhenSupplyNonZero() public {
        _depositAs(alice, 100 * 1e6);
        // donate extra
        usdc.mint(address(vault), 50 * 1e6);
        vm.prank(operator);
        vm.expectRevert(IHyperCoreVault.StrandedSweepRequiresZeroSupply.selector);
        vault.operatorSweepStranded(address(0xBEEF));
    }
}
