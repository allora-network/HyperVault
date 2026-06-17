// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {HyperVaultBaseForkTest} from "./HyperVaultBase.fork.t.sol";
import {HyperCoreVault} from "../../src/HyperCoreVault.sol";
import {IHyperCoreVault} from "../../src/interfaces/IHyperCoreVault.sol";
import {PrecompileLib} from "../../src/libraries/PrecompileLib.sol";
import {Constants} from "../../src/libraries/Constants.sol";

/// @dev CoreWriter stub etched at the system address so the escape cranks execute
///      deterministically and emit their CoreWriter actions/events. We assert the
///      EMITTED actions, NOT Core settlement (a forge fork cannot run the HyperCore
///      precompiles nor process CoreWriter — the real fills/settlement are the live
///      spike's job; see the `_provenInLiveSpike` stubs at the bottom).
contract MockCoreWriter {
    event RawAction(bytes data);

    function sendRawAction(bytes calldata data) external {
        emit RawAction(data);
    }
}

/// @title  M5 escape-hatch Phase-1 proofs (forked HyperEVM mainnet, real bytecode)
/// @notice Proves the escape latch + ESCAPE-mode gating + the three named cranks
///         (cancel / flatten / consolidate) on a freshly deployed vault, against the
///         real USDC ERC20 — no economic mocks. The escape entry is the interim
///         admin {triggerEscape} (admin == address(this) on the fork harness;
///         SOLU-3371 widens it to the permissionless staleness trigger).
///
///         FORK LIMITATION (same as the rest of the suite): revm does not implement
///         the HyperCore precompiles (0x0800-0x0810) and does not process CoreWriter.
///         So: (1) every CoreWriter-dispatching crank runs with a {MockCoreWriter}
///         etched at the system address and we assert the EMITTED action/event, not a
///         fill; (2) leg-2's markPx band comparison and leg-3's `withdrawable` read
///         depend on precompile reads a fork cannot serve, so the band-REJECTION proof
///         drives the relevant precompiles with `vm.mockCall` SOLELY to reach the
///         pure-EVM band comparison (a control-flow / revert-selector assertion, not an
///         economic conclusion), and the real reduce-only IOC FILL + Core settlement of
///         every leg are `_provenInLiveSpike` stubs (the no-fake-settlement rule).
contract HyperVaultEscapeForkTest is HyperVaultBaseForkTest {
    // Event mirrors for vm.expectEmit (matched by signature + data).
    event EscapeActivated(address indexed by, address indexed lp);
    event EscapeDeactivated(address indexed by);
    event EscapeCrankRun(address indexed by, uint8 indexed leg);
    event OrderCancelByCloidSubmitted(uint32 indexed asset, uint128 indexed cloid);
    event UsdClassTransferSubmitted(uint64 ntl, bool toPerp);

    // ───────────────────────────────────────────────────────────────────────
    // Latch + the six ESCAPE-mode gates (M5 §4)
    //   Claim: while escapeActive, deposit/mint revert + maxDeposit==0, and the
    //          market-deploying movers (placeLimitOrder / pushToCore / usdSpotToPerp)
    //          revert EscapeModeActive; the risk-reducing / redemption surface
    //          (fulfillWithdraw / cancelWithdrawRequest / prioritizeOverdue /
    //          usdPerpToSpot) is NOT gated.
    //   Fork-provable: FULL — pure latch + AccessControl + the modifier reverts fire
    //          before any precompile/CoreWriter (the unit under test is the gate).
    // ───────────────────────────────────────────────────────────────────────
    function test_latchGatesDepositsAndDeployMovers() public {
        _skipIfNoFork();
        vm.etch(Constants.CORE_WRITER, type(MockCoreWriter).runtimeCode);

        // Seed one LP BEFORE arming (deposits are blocked once latched).
        uint256 shares = _deposit(alice, 100e6);
        assertGt(vault.maxDeposit(bob), 0, "deposits open before arming");

        // Arm the brake (interim admin entry; admin == address(this)).
        vm.expectEmit(true, true, false, true, address(vault));
        emit EscapeActivated(address(this), alice);
        vault.triggerEscape(alice);
        assertTrue(vault.escapeActive(), "latched into ESCAPE mode");

        // (1) maxDeposit / maxMint collapse to 0.
        assertEq(vault.maxDeposit(bob), 0, "maxDeposit==0 while latched");
        assertEq(vault.maxMint(bob), 0, "maxMint==0 while latched");

        // (2) deposit + (3) mint revert EscapeModeActive.
        deal(USDC, bob, 100e6);
        vm.startPrank(bob);
        IERC20(USDC).approve(address(vault), 100e6);
        vm.expectRevert(IHyperCoreVault.EscapeModeActive.selector);
        vault.deposit(100e6, bob);
        vm.expectRevert(IHyperCoreVault.EscapeModeActive.selector);
        vault.mint(1e12, bob);
        vm.stopPrank();

        // (4) placeLimitOrder, (5) pushToCore, (6) usdSpotToPerp revert EscapeModeActive.
        vm.startPrank(operator);
        vm.expectRevert(IHyperCoreVault.EscapeModeActive.selector);
        vault.placeLimitOrder(0, true, 1e8, 1e8, false, Constants.TIF_GTC);
        vm.expectRevert(IHyperCoreVault.EscapeModeActive.selector);
        vault.pushToCore(1);
        vm.expectRevert(IHyperCoreVault.EscapeModeActive.selector);
        vault.usdSpotToPerp(1);
        vm.stopPrank();

        console2.log("M5 PASS - all 6 ESCAPE gates fire (maxDeposit==0; deposit/mint/place/push/spot->perp revert)");

        // NOT gated while latched: the redemption + risk-reducing surface stays live.
        // usdPerpToSpot (perp->spot, risk-reducing) succeeds (MockCoreWriter etched).
        vm.prank(operator);
        vault.usdPerpToSpot(1);

        // fulfillWithdraw / cancelWithdrawRequest are permissionless and ungated:
        // with no pending request they early-return (no EscapeModeActive revert).
        vm.prank(keeper);
        vault.fulfillWithdraw(bob);
        vm.prank(bob);
        vault.cancelWithdrawRequest();

        // A real request can still be escrowed + prioritized while latched.
        vm.prank(alice);
        vault.requestWithdraw(shares);
        assertEq(vault.pendingWithdrawalShares(alice), shares, "request escrowed while latched");

        console2.log("M5 PASS - redemption + usdPerpToSpot are NOT gated by ESCAPE mode");
    }

    /// @dev Regression: arming does NOT touch the redemption queue's existing
    ///      accounting — a fulfill against idle still pays out while latched.
    function test_latchLeavesFulfillAgainstIdleWorking() public {
        _skipIfNoFork();
        vm.etch(Constants.CORE_WRITER, type(MockCoreWriter).runtimeCode);

        uint256 shares = _deposit(alice, 100e6);
        vm.prank(alice);
        vault.requestWithdraw(shares);

        vault.triggerEscape(alice);
        assertTrue(vault.escapeActive(), "latched");

        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(keeper);
        vault.fulfillWithdraw(alice); // idle fully backs the request -> full payout
        assertEq(IERC20(USDC).balanceOf(alice) - aliceBefore, 100e6, "fulfilled from idle while latched");
        assertEq(vault.pendingWithdrawalShares(alice), 0, "request cleared while latched");

        console2.log("M5 PASS - fulfillWithdraw against idle pays out normally while latched");
    }

    // ───────────────────────────────────────────────────────────────────────
    // triggerEscape access control (M5 §1, interim)
    // ───────────────────────────────────────────────────────────────────────
    function test_triggerEscapeIsAdminGatedInterim() public {
        _skipIfNoFork();
        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();

        // Non-admin cannot arm (the interim entry is admin-gated; SOLU-3371 widens it).
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, adminRole)
        );
        vault.triggerEscape(attacker);
        assertFalse(vault.escapeActive(), "not armed by a non-admin");

        // Idempotent: re-arming by the admin is a no-op (no spurious second event).
        vault.triggerEscape(alice);
        assertTrue(vault.escapeActive(), "armed");
        vault.triggerEscape(alice); // no revert, no state change
        assertTrue(vault.escapeActive(), "still armed (idempotent)");

        console2.log("M5 PASS - triggerEscape is admin-gated (interim) + idempotent");
    }

    // ───────────────────────────────────────────────────────────────────────
    // Leg 1 — escapeCancelOrders (M5 §2 leg 1)
    //   Claim: a cloid >= _cloidCounter is rejected (cannot name a vault order); a
    //          valid (issued) cloid emits the cancel action + the crank event.
    //   Fork-provable: FULL — cloid validation is pure arithmetic; the cancel is a
    //          CoreWriter dispatch we observe via the etched stub.
    // ───────────────────────────────────────────────────────────────────────
    function test_leg1_cancelRejectsOutOfRangeCloid() public {
        _skipIfNoFork();
        vm.etch(Constants.CORE_WRITER, type(MockCoreWriter).runtimeCode);
        vault.triggerEscape(alice);

        uint128 counter = vault.nextCloid(); // next free cloid; every issued id is < counter
        uint128[] memory bad = new uint128[](1);
        bad[0] = counter; // == counter -> out of range

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.EscapeCloidOutOfRange.selector, counter, counter));
        vault.escapeCancelOrders(0, bad);

        // counter + 1 is also out of range.
        bad[0] = counter + 1;
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.EscapeCloidOutOfRange.selector, counter + 1, counter));
        vault.escapeCancelOrders(0, bad);

        console2.log("M5 PASS - leg 1 rejects a cloid >= _cloidCounter (cannot name a vault-placed order)");
    }

    function test_leg1_cancelValidCloidEmitsAction() public {
        _skipIfNoFork();
        vm.etch(Constants.CORE_WRITER, type(MockCoreWriter).runtimeCode);

        // Issue a real cloid FIRST (the counter starts at 1, post-incremented): place
        // one order pre-escape so nextCloid advances to 2 and cloid 1 names a real
        // (now-resting) vault order. placeLimitOrder is blocked once latched, so this
        // must precede triggerEscape.
        uint32 asset_ = 0;
        vault.setWhitelistPerp(asset_, true); // admin == address(this)
        vm.prank(operator);
        uint128 cloid = vault.placeLimitOrder(asset_, true, 1e8, 1e8, false, Constants.TIF_GTC);
        assertEq(cloid, 1, "first issued cloid is 1");
        assertLt(cloid, vault.nextCloid(), "cloid 1 is now in range (< nextCloid==2)");

        vault.triggerEscape(alice);

        // CoreWriter is fire-and-forget so cancelling a (possibly already-gone) order
        // by an in-range cloid is a safe Core no-op.
        uint128[] memory ok = new uint128[](1);
        ok[0] = cloid;

        // Both the per-cloid cancel action and the leg-1 crank event must fire.
        vm.expectEmit(true, true, false, false, address(vault));
        emit OrderCancelByCloidSubmitted(asset_, cloid);
        vm.expectEmit(true, true, false, true, address(vault));
        emit EscapeCrankRun(keeper, 1);
        vm.prank(keeper);
        vault.escapeCancelOrders(asset_, ok);

        console2.log("M5 PASS - leg 1 valid cloid emits OrderCancelByCloidSubmitted + EscapeCrankRun(.,1)");
    }

    function test_leg1_cancelRevertsWhenNotLatched() public {
        _skipIfNoFork();
        vm.etch(Constants.CORE_WRITER, type(MockCoreWriter).runtimeCode);
        // Not armed: the shared crank gate rejects with EscapeModeNotActive.
        uint128[] memory ids = new uint128[](1);
        ids[0] = 1;
        vm.prank(keeper);
        vm.expectRevert(IHyperCoreVault.EscapeModeNotActive.selector);
        vault.escapeCancelOrders(0, ids);

        console2.log("M5 PASS - cranks revert EscapeModeNotActive when the brake is not armed");
    }

    // ───────────────────────────────────────────────────────────────────────
    // Leg 2 — escapeFlattenPerps (M5 §2 leg 2): the M4 markPx band is MANDATORY.
    //   Claim: there is NO band-free escape flatten (a force close stays
    //          EMERGENCY_ROLE, §5); an out-of-band limitPx reverts
    //          EmergencyCloseBandExceeded.
    //   Fork limitation: `_flattenOnePosition` reads the position precompile FIRST
    //          (a flat read short-circuits before the band check), and the band uses
    //          markPxStrict — both precompiles are unavailable on a forge fork. So to
    //          reach the pure-EVM band comparison we inject a non-flat position +
    //          szDecimals + markPx with vm.mockCall (control-flow only; we assert the
    //          REVERT SELECTOR, not any economic outcome). The real reduce-only IOC
    //          FILL is the live-spike's job (_provenInLiveSpike stub below).
    // ───────────────────────────────────────────────────────────────────────
    function test_leg2_bandIsMandatory_outOfBandReverts() public {
        _skipIfNoFork();
        vm.etch(Constants.CORE_WRITER, type(MockCoreWriter).runtimeCode);

        uint32 perp = 0;
        uint16 band = 1000; // 10% — set wide (admin == address(this))
        vault.setEmergencyCloseBand(band);
        vault.triggerEscape(alice);

        // Inject a non-flat position so the band branch is reached, plus szDecimals
        // and a markPx for the comparison. (Fork cannot serve these precompiles; this
        // is a pure control-flow injection to exercise the band math, not a fill.)
        uint8 szDec = 2;
        PrecompileLib.Position memory pos =
            PrecompileLib.Position({szi: 100, entryNtl: 0, isolatedRawUsd: 0, leverage: 10, isIsolated: false});
        vm.mockCall(Constants.POSITION_PRECOMPILE, abi.encode(address(vault), perp), abi.encode(pos));
        PrecompileLib.PerpAssetInfo memory info = PrecompileLib.PerpAssetInfo({
            coin: "X", marginTableId: 0, szDecimals: szDec, maxLeverage: 10, onlyIsolated: false
        });
        vm.mockCall(Constants.PERP_ASSET_INFO_PRECOMPILE, abi.encode(perp), abi.encode(info));
        // markPx precompile scale = human * 10^(6 - szDecimals); pick markRaw so the
        // normalized mark (markRaw * 10^(szDec+2)) is a clean 1e8 ($1.00 in action scale).
        uint64 markRaw = uint64(10 ** (6 - szDec)); // -> markNorm == 1e8
        vm.mockCall(Constants.MARK_PX_PRECOMPILE, abi.encode(perp), abi.encode(markRaw));

        uint256 markNorm = uint256(markRaw) * (10 ** (uint256(szDec) + 2));
        assertEq(markNorm, 1e8, "mark normalized to the 1e8 action scale");

        // A limitPx 50% above the mark is far outside the 10% band -> reject.
        uint64 absurdPx = uint64(markNorm + markNorm / 2);
        uint32[] memory perps = new uint32[](1);
        perps[0] = perp;
        uint64[] memory pxs = new uint64[](1);
        pxs[0] = absurdPx;

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(IHyperCoreVault.EmergencyCloseBandExceeded.selector, absurdPx, markRaw, band)
        );
        vault.escapeFlattenPerps(perps, pxs);

        vm.clearMockedCalls();
        console2.log("M5 PASS - leg 2 enforces the M4 markPx band (out-of-band limitPx reverts; no force variant)");
    }

    /// @dev Leg 2 has NO band-free variant on the escape surface: the only band-free
    ///      close is the EMERGENCY_ROLE {emergencyClosePositionsForce} (§5). Assert the
    ///      escape path requires the latch (gate) and that there is no permissionless
    ///      force flatten (the ABI exposes only the band-enforced escapeFlattenPerps).
    function test_leg2_revertsWhenNotLatched() public {
        _skipIfNoFork();
        vm.etch(Constants.CORE_WRITER, type(MockCoreWriter).runtimeCode);
        uint32[] memory perps = new uint32[](1);
        uint64[] memory pxs = new uint64[](1);
        vm.prank(keeper);
        vm.expectRevert(IHyperCoreVault.EscapeModeNotActive.selector);
        vault.escapeFlattenPerps(perps, pxs);

        console2.log("M5 PASS - leg 2 requires the latch; the only band-free close stays EMERGENCY_ROLE (force)");
    }

    // ───────────────────────────────────────────────────────────────────────
    // Cooldown (M5 §4) — the first crank after arming runs immediately; a second
    //   crank within escapeCrankInterval reverts EscapeCooldownActive.
    //   Fork-provable: FULL — the cooldown is block.timestamp arithmetic on the
    //          latch struct; we drive the clock with vm.warp.
    // ───────────────────────────────────────────────────────────────────────
    function test_cooldown_secondCrankWithinIntervalReverts() public {
        _skipIfNoFork();
        vm.etch(Constants.CORE_WRITER, type(MockCoreWriter).runtimeCode);
        vault.triggerEscape(alice);

        uint64 interval = vault.escapeCrankInterval();
        assertEq(interval, 60, "interval is the fixed 60s envelope");

        // First crank runs immediately (lastCrankTs == 0). Use leg 1 with an empty
        // cloid list: it passes the gate, stamps lastCrankTs, emits EscapeCrankRun.
        uint128[] memory none = new uint128[](0);
        vm.prank(keeper);
        vault.escapeCancelOrders(0, none);

        // A second crank within the interval is rejected.
        uint64 nextAllowed = uint64(block.timestamp) + interval;
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.EscapeCooldownActive.selector, nextAllowed));
        vault.escapeCancelOrders(0, none);

        // After the interval elapses, the next crank runs again.
        vm.warp(block.timestamp + interval);
        vm.prank(keeper);
        vault.escapeCancelOrders(0, none); // no revert

        console2.log("M5 PASS - cooldown: 1st crank immediate; 2nd within 60s reverts; runs again after the interval");
    }

    // ───────────────────────────────────────────────────────────────────────
    // exitEscape (M5 §1) — clears the latch ONLY when no overdue-unfillable request
    //   remains; reverts/holds otherwise.
    //   Fork-provable: FULL where the "unfillable" test is claim > availableIdle with
    //          NAV == idle (the fork case). An overdue request whose claim exceeds
    //          available idle (because idle was drained) holds the brake; once it is
    //          honorable again (idle restored) exit succeeds. previewRedeem is read via
    //          the vault self-call inside the library.
    // ───────────────────────────────────────────────────────────────────────
    function test_exit_clearsWhenNoBacklog() public {
        _skipIfNoFork();
        vm.etch(Constants.CORE_WRITER, type(MockCoreWriter).runtimeCode);

        // Admin arm with no overdue request at all -> exitEscape clears immediately.
        vault.triggerEscape(alice);
        assertTrue(vault.escapeActive(), "armed");

        address[] memory none = new address[](0);
        vm.expectEmit(true, false, false, true, address(vault));
        emit EscapeDeactivated(address(this));
        vault.exitEscape(none);
        assertFalse(vault.escapeActive(), "cleared (no backlog to clear)");

        console2.log("M5 PASS - exitEscape clears the latch when no overdue-unfillable request remains");
    }

    function test_exit_holdsWhileOverdueUnfillableRemains() public {
        _skipIfNoFork();
        vm.etch(Constants.CORE_WRITER, type(MockCoreWriter).runtimeCode);

        // Stamp an SLA, escrow a request, let it lapse, then RESERVE its claim via
        // prioritizeOverdue. The reserve carves the whole idle pool out of
        // availableIdle WITHOUT collapsing NAV (so previewRedeem stays at the full
        // claim) -> previewRedeem(shares) > availableIdle == "overdue-unfillable", the
        // exact arming condition. (Draining idle would also drop NAV on a fork — where
        // coreSpotUsdc reads 0 — collapsing the claim too; the reserve keeps NAV intact
        // and is the fork-faithful way to make claim > availableIdle.)
        vault.setRequestFulfillmentWindow(1 hours);
        uint256 shares = _deposit(alice, 100e6);
        vm.prank(alice);
        vault.requestWithdraw(shares);
        vm.warp(block.timestamp + 1 hours + 1);
        assertTrue(vault.requestIsOverdue(alice), "overdue");

        vault.triggerEscape(alice);

        vm.prank(keeper);
        vault.prioritizeOverdue(alice);
        assertGt(vault.pendingWithdrawalReserved(alice), 0, "alice's claim reserved");
        assertEq(vault.availableIdleUsdc(), 0, "reserve carves idle out of availableIdle");
        assertGt(vault.previewRedeem(shares), vault.availableIdleUsdc(), "claim > availableIdle (unfillable)");

        // exitEscape with Alice still overdue-unfillable -> reverts, latch held.
        address[] memory lps = new address[](1);
        lps[0] = alice;
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.EscapeBacklogRemains.selector, alice));
        vault.exitEscape(lps);
        assertTrue(vault.escapeActive(), "latch still held while the backlog remains");

        // Resolve the request (fulfill from her reserve) -> no overdue request remains
        // -> exit now succeeds and clears the latch.
        vm.prank(keeper);
        vault.fulfillWithdraw(alice);
        assertEq(vault.pendingWithdrawalShares(alice), 0, "request resolved");
        vault.exitEscape(lps);
        assertFalse(vault.escapeActive(), "cleared once no overdue-unfillable request remains");

        console2.log("M5 PASS - exitEscape holds while an overdue-unfillable request remains; clears when resolved");
    }

    // ───────────────────────────────────────────────────────────────────────
    // Regression — with escape INACTIVE, deposit/withdraw/redeem/place behave
    //   exactly as before (the gating is purely additive behind the latch).
    // ───────────────────────────────────────────────────────────────────────
    function test_regression_inactiveEscapeLeavesEverythingNormal() public {
        _skipIfNoFork();
        vm.etch(Constants.CORE_WRITER, type(MockCoreWriter).runtimeCode);
        assertFalse(vault.escapeActive(), "not latched");

        // deposit works; maxDeposit is the cap, not 0.
        uint256 shares = _deposit(alice, 100e6);
        assertGt(shares, 0, "deposit minted shares");
        assertGt(vault.maxDeposit(bob), 0, "maxDeposit open when not latched");

        // a synchronous withdraw against idle works.
        vm.prank(alice);
        vault.withdraw(40e6, alice, alice);
        assertEq(IERC20(USDC).balanceOf(alice), 40e6, "withdraw paid from idle");

        // redeem the remainder works. (Read the balance BEFORE the prank — vm.prank
        // is single-use and applies only to the immediately following call.)
        uint256 remaining = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(remaining, alice, alice);
        assertEq(vault.balanceOf(alice), 0, "redeemed remaining shares");

        // placeLimitOrder is NOT gated (it will revert later for whitelist/other
        // reasons, but NOT with EscapeModeActive). Whitelist asset 0 so it reaches
        // CoreWriter; with the stub etched the submit succeeds.
        vault.setWhitelistPerp(0, true); // admin == address(this)
        vm.prank(operator);
        vault.placeLimitOrder(0, true, 1e8, 1e8, false, Constants.TIF_GTC); // no EscapeModeActive revert

        console2.log("M5 PASS - with escape inactive, deposit/withdraw/redeem/place behave exactly as before");
    }

    // ───────────────────────────────────────────────────────────────────────
    // Live-only (no-fake-settlement): behaviors a forge fork cannot represent.
    // The pure-EVM control flow above is proven on the fork; the items below need
    // real HyperCore precompiles + CoreWriter processing and are proven on the live
    // funded spike (docs/FORK_PROOFS.md, scripts/python/e2e_runner.py).
    // ───────────────────────────────────────────────────────────────────────

    /// @dev _provenInLiveSpike: leg-2 reduce-only IOC actually REDUCES a real perp
    ///      position to flat (a fork cannot hold a live position nor process the IOC).
    function test_leg2_reduceOnlyIocFlattens_provenInLiveSpike() public {
        _skipIfNoFork();
        console2.log("leg 2 reduce-only IOC fill -> flat needs a live perp position + CoreWriter; live spike.");
        vm.skip(true);
    }

    /// @dev _provenInLiveSpike: leg-3 consolidate moves the REAL `withdrawable` perp
    ///      equity to Core spot (the withdrawable precompile + usd_class_transfer
    ///      settlement are not fork-representable; on a fork withdrawable reads 0 so
    ///      the crank no-ops the CoreWriter call while still running the gate + event).
    function test_leg3_consolidateMovesWithdrawable_provenInLiveSpike() public {
        _skipIfNoFork();
        console2.log("leg 3 perp->spot of real withdrawable equity needs the precompile + settlement; live spike.");
        vm.skip(true);
    }

    /// @dev leg-3 IS reachable on a fork in its no-op form: while latched, with
    ///      `withdrawable` reading 0 (no precompile), the crank passes the gate and
    ///      emits EscapeCrankRun(.,3) without dispatching a CoreWriter action. This
    ///      proves the gate + event wiring even though the move itself is live-only.
    function test_leg3_consolidateRunsGateAndEventWhenNothingWithdrawable() public {
        _skipIfNoFork();
        vm.etch(Constants.CORE_WRITER, type(MockCoreWriter).runtimeCode);
        vault.triggerEscape(alice);

        // withdrawable reads 0 on the fork (lenient, no precompile) -> no perp->spot
        // action, but the gate runs and the crank event fires.
        vm.expectEmit(true, true, false, true, address(vault));
        emit EscapeCrankRun(keeper, 3);
        vm.prank(keeper);
        vault.escapeConsolidateToSpot();

        console2.log("M5 PASS - leg 3 runs the gate + emits EscapeCrankRun(.,3); the actual move is live-only");
    }
}
