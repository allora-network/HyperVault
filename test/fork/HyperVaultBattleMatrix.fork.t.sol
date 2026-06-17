// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HyperVaultBaseForkTest} from "./HyperVaultBase.fork.t.sol";
import {HyperCoreVault} from "../../src/HyperCoreVault.sol";
import {IHyperCoreVault} from "../../src/interfaces/IHyperCoreVault.sol";
import {PrecompileLib} from "../../src/libraries/PrecompileLib.sol";
import {Constants} from "../../src/libraries/Constants.sol";

/// @dev CoreWriter stub etched at the system address so the escape cranks execute
///      deterministically and emit their CoreWriter actions/events. We assert the
///      EMITTED actions + the latch/gate/cooldown/exit STATE MACHINE, NOT Core
///      settlement (a forge fork cannot run the HyperCore precompiles nor process
///      CoreWriter — the real fills/settlement are the live spike's job). Mirrors the
///      stub in HyperVaultEscape.fork.t.sol verbatim.
contract MockCoreWriter {
    event RawAction(bytes data);

    function sendRawAction(bytes calldata data) external {
        emit RawAction(data);
    }
}

/// @title  Battle-matrix coverage proofs (forked HyperEVM mainnet, real bytecode)
/// @notice Closes two audit-flagged coverage gaps on top of the existing fork suite,
///         reusing its EXACT conventions (real USDC ERC20, `deal` funding, the
///         spot-balance-precompile mock for NAV>idle, the permissionless staleness arm,
///         and the MockCoreWriter stub for the escape cranks):
///           (1) MULTI-LP concurrent withdrawal requests with overlapping deadlines +
///               partial fills (escrow independence, the per-LP one-open-request guard,
///               re-prioritizable partial remainders, and the fairness reserve scaled
///               past a single LP — the >1-LP generalisation of Liveness Finding F);
///           (2) the FULL permissionless-escape end-to-end path (trigger -> the 4 legs
///               -> fulfill -> exitEscape) under a mocked NAV>idle state, asserting the
///               latch/gating/cooldown/exit STATE MACHINE (not real Core settlement).
///
///         FORK FIDELITY (identical to the rest of the suite): revm serves no HyperCore
///         precompiles, so totalAssets()==idleUsdc() unless we mock the spot-balance
///         precompile (0x801) to manufacture NAV>idle — a pure-EVM accounting injection
///         exactly as test_M3 / HyperVaultKeeperEdge do, NOT economic settlement. The
///         escape cranks dispatch CoreWriter actions we observe via the etched stub; the
///         real fills/Core debit are the suite's `_provenInLiveSpike` stubs.
contract HyperVaultBattleMatrixForkTest is HyperVaultBaseForkTest {
    // Event mirrors for vm.expectEmit (matched by signature + data).
    event WithdrawalPrioritized(address indexed lp, uint256 reservedAssets, uint64 deadline);
    event EscapeActivated(address indexed by, address indexed lp);
    event EscapeDeactivated(address indexed by);
    event EscapeCrankRun(address indexed by, uint8 indexed leg);

    /// @dev Mock the vault's Core spot USDC balance (8dp Core wei) so coreSpotUsdc()
    ///      reports `humanUsdc` and totalAssets() = idle + that. Verbatim the
    ///      HyperVaultKeeperEdge `_mockCoreSpot` helper (same NAV>idle manufacture as
    ///      test_M3): a control-flow injection, not a fund.
    function _mockCoreSpot(uint256 humanUsdc) internal {
        PrecompileLib.SpotBalance memory bal =
            PrecompileLib.SpotBalance({total: uint64(humanUsdc * 100), hold: 0, entryNtl: 0});
        vm.mockCall(
            Constants.SPOT_BALANCE_PRECOMPILE, abi.encode(address(vault), uint64(0)), abi.encode(bal)
        );
    }

    /// @dev The journal-style idle invariant: idle splits exactly into available +
    ///      reserved at all times. Asserted at every interesting step (cheap).
    function _assertIdleInvariant(string memory at) internal view {
        assertEq(
            vault.idleUsdc(),
            vault.availableIdleUsdc() + vault.reservedIdleUsdc(),
            string.concat("idle == available + reserved @ ", at)
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // BM-1 — MULTI-LP CONCURRENT REQUESTS (escrow independence + per-LP guard).
    //   3 LPs deposit; NAV>idle is mocked so idle covers only some claims; each LP
    //   requestWithdraw; assert the one-open-request-per-LP guard, that escrow
    //   accounting is correct across all of them, and that pendingWithdrawalShares /
    //   pendingWithdrawalDeadline are INDEPENDENT per LP.
    //   Fork-provable: FULL — pure-EVM queue accounting; NAV>idle via the mock as M3.
    // ═════════════════════════════════════════════════════════════════════════
    function test_BM_multiLP_concurrent_requests() public {
        _skipIfNoFork();
        vault = _deployVault(0, 0); // no fees: escrow == shares exactly; clean accounting

        // Three LPs of different size enter at PPS 1.0. idle == 600e6.
        uint256 aShares = _deposit(alice, 100e6);
        uint256 bShares = _deposit(bob, 200e6);
        uint256 cShares = _deposit(carol, 300e6);
        assertEq(_idle(), 600e6, "idle holds all three deposits");

        // Mock Core spot = 600 USDC -> NAV 1200e6 > idle 600e6 (idle covers only half
        // the aggregate claim) — the concurrent-pressure precondition.
        _mockCoreSpot(600e6);
        assertEq(vault.totalAssets(), 1200e6, "NAV > idle (capital parked on Core)");
        assertEq(_idle(), 600e6, "idle is half of NAV");

        // Stamp an SLA so deadlines exist (independence is observable on the deadlines).
        vault.setRequestFulfillmentWindow(1 hours);

        // Each LP queues its full position. The vault escrow accumulates every request.
        vm.prank(alice);
        vault.requestWithdraw(aShares);
        vm.prank(bob);
        vault.requestWithdraw(bShares);
        vm.prank(carol);
        vault.requestWithdraw(cShares);

        // Escrow accounting: the vault now custodies EXACTLY the sum of all three.
        assertEq(vault.pendingWithdrawalShares(alice), aShares, "alice escrow == her shares");
        assertEq(vault.pendingWithdrawalShares(bob), bShares, "bob escrow == his shares");
        assertEq(vault.pendingWithdrawalShares(carol), cShares, "carol escrow == her shares");
        assertEq(
            vault.balanceOf(address(vault)),
            aShares + bShares + cShares,
            "vault escrows exactly the sum of all three requests"
        );
        assertEq(vault.balanceOf(alice), 0, "alice free balance zeroed");
        assertEq(vault.balanceOf(bob), 0, "bob free balance zeroed");
        assertEq(vault.balanceOf(carol), 0, "carol free balance zeroed");

        // Independence: each LP carries its OWN deadline (all stamped, all equal here as
        // they requested in the same block — but independently tracked, not shared).
        uint64 aDeadline = vault.pendingWithdrawalDeadline(alice);
        uint64 bDeadline = vault.pendingWithdrawalDeadline(bob);
        uint64 cDeadline = vault.pendingWithdrawalDeadline(carol);
        assertGt(aDeadline, 0, "alice deadline stamped");
        assertGt(bDeadline, 0, "bob deadline stamped");
        assertGt(cDeadline, 0, "carol deadline stamped");

        // One-open-request-per-LP guard: a SECOND request from any LP reverts even
        // though they hold no free balance (reported as (requested, 0)). Independence
        // means this binds per-LP and does not touch the others.
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IHyperCoreVault.WithdrawExceedsIdleBalance.selector, uint256(1), uint256(0))
        );
        vault.requestWithdraw(1);
        assertEq(vault.pendingWithdrawalShares(alice), aShares, "alice request untouched by bob's reverted second");
        assertEq(vault.pendingWithdrawalShares(carol), cShares, "carol request untouched by bob's reverted second");

        // Independence under cancel: alice cancels; her escrow returns; bob + carol are
        // wholly unaffected (own shares + own deadlines intact).
        vm.prank(alice);
        vault.cancelWithdrawRequest();
        assertEq(vault.pendingWithdrawalShares(alice), 0, "alice request cleared by cancel");
        assertEq(vault.balanceOf(alice), aShares, "alice escrow restored to her on cancel");
        assertEq(vault.pendingWithdrawalShares(bob), bShares, "bob request untouched by alice cancel");
        assertEq(vault.pendingWithdrawalShares(carol), cShares, "carol request untouched by alice cancel");
        assertEq(vault.pendingWithdrawalDeadline(bob), bDeadline, "bob deadline independent of alice cancel");
        assertEq(vault.pendingWithdrawalDeadline(carol), cDeadline, "carol deadline independent of alice cancel");
        assertEq(
            vault.balanceOf(address(vault)),
            bShares + cShares,
            "escrow now exactly bob + carol (alice's slice returned)"
        );

        _assertIdleInvariant("BM-1 end");
        vm.clearMockedCalls();
        console2.log("BM-1 PASS - multi-LP escrow is independent + additive; one-open-request guard binds per-LP");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // BM-2 — OVERLAPPING DEADLINES + PARTIAL FILLS (remainder keeps its deadline,
    //   stays re-prioritizable). Multiple LPs request at DIFFERENT warped times so
    //   their deadlines overlap; fulfill partially (idle short); assert each partial
    //   leaves the remainder pending with its deadline INTACT and re-prioritizable —
    //   mirroring the HyperVaultKeeperEdge K1 re-prioritize assertion, generalised to
    //   two concurrent overlapping LPs.
    //   Fork-provable: pure-EVM queue/reserve accounting; NAV>idle via the mock.
    // ═════════════════════════════════════════════════════════════════════════
    function test_BM_overlapping_deadlines_partial() public {
        _skipIfNoFork();
        vault = _deployVault(0, 0); // no fees: payout == previewRedeem exactly

        // Short SLA so a single warp makes a request overdue.
        vault.setRequestFulfillmentWindow(1 hours);

        // Alice enters and requests at t0 -> her deadline = t0 + 1h.
        uint256 aShares = _deposit(alice, 100e6);
        vm.prank(alice);
        vault.requestWithdraw(aShares);
        uint64 aDeadline = vault.pendingWithdrawalDeadline(alice);

        // Advance 30 min, then bob enters and requests -> his deadline = t0 + 30m + 1h.
        // The windows OVERLAP: bob's deadline is later than alice's, but alice is still
        // un-fulfilled when bob's clock is running.
        vm.warp(block.timestamp + 30 minutes);
        uint256 bShares = _deposit(bob, 100e6);
        vm.prank(bob);
        vault.requestWithdraw(bShares);
        uint64 bDeadline = vault.pendingWithdrawalDeadline(bob);
        assertGt(bDeadline, aDeadline, "bob's deadline is strictly later (overlapping windows)");

        // Mock Core spot AFTER both deposits so NAV>idle by a wide margin: idle 200e6,
        // Core 400e6 -> NAV 600e6, PPS 3.0. Each LP's claim (~300e6) STRICTLY exceeds the
        // whole idle pool (200e6), so a single fulfill can only PARTIAL-fill against idle
        // and a genuine remainder always survives (robust to OZ's 1-wei round-down).
        _mockCoreSpot(400e6);
        assertEq(vault.totalAssets(), 600e6, "NAV > idle (capital parked on Core)");
        assertEq(_idle(), 200e6, "idle is a third of NAV");

        // Warp PAST alice's deadline (but bob may or may not be overdue yet — irrelevant,
        // we prioritize alice). Alice is overdue first (earlier deadline).
        vm.warp(aDeadline + 1);
        assertTrue(vault.requestIsOverdue(alice), "alice overdue after her window");

        // Prioritize alice: reserve her claim, capped at idle. Her claim (~300e6) exceeds
        // idle (200e6) so the reserve caps at the full idle.
        uint256 aliceClaim = vault.previewRedeem(aShares); // ~300e6
        uint256 reserveCap = aliceClaim > _idle() ? _idle() : aliceClaim;
        assertGt(aliceClaim, _idle(), "alice's claim strictly exceeds idle (true partial guaranteed)");
        assertEq(reserveCap, _idle(), "alice's reserve caps at the full idle (claim exceeds it)");

        vm.expectEmit(true, false, false, true, address(vault));
        emit WithdrawalPrioritized(alice, reserveCap, aDeadline);
        vm.prank(keeper);
        vault.prioritizeOverdue(alice);
        assertEq(vault.pendingWithdrawalReserved(alice), reserveCap, "alice reserve recorded");
        assertEq(vault.reservedIdleUsdc(), reserveCap, "global reserve == alice reserve");
        assertEq(vault.availableIdleUsdc(), 0, "all idle reserved for alice");
        _assertIdleInvariant("BM-2 after prioritize alice");

        // PARTIAL fulfill alice: grossPossible (~300e6 claim) > drawable (200e6 idle ==
        // her reserve), so this fills only the 200e6 of idle and leaves a real remainder
        // (the Core two-thirds is unreachable by the queue).
        uint256 idleForFill = vault.availableIdleUsdc() + vault.pendingWithdrawalReserved(alice); // 0 + 200e6
        uint256 filledShares = vault.previewWithdraw(idleForFill);
        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);

        vm.prank(keeper);
        vault.fulfillWithdraw(alice);

        uint256 aRemainder = vault.pendingWithdrawalShares(alice);
        assertEq(aRemainder, aShares - filledShares, "alice remainder == original - filled");
        assertGt(aRemainder, 0, "a genuine remainder exists (partial fill, idle short)");
        assertEq(vault.pendingWithdrawalReserved(alice), 0, "partial fulfill RESET alice's reserve to 0");
        assertEq(vault.reservedIdleUsdc(), 0, "global reserve fully released (no stranded idle)");
        assertEq(vault.pendingWithdrawalDeadline(alice), aDeadline, "alice remainder PRESERVES her ORIGINAL deadline");
        assertTrue(vault.requestIsOverdue(alice), "alice remainder STILL overdue (deadline preserved & lapsed)");
        assertEq(IERC20(USDC).balanceOf(alice) - aliceUsdcBefore, idleForFill, "alice paid exactly the idle drawn");
        assertEq(_idle(), 0, "idle fully drained by alice's partial fill");

        // Bob's request is wholly untouched by alice's partial flow — its deadline is
        // intact and independent (overlapping windows do not couple the two requests).
        assertEq(vault.pendingWithdrawalShares(bob), bShares, "bob request untouched by alice's partial");
        assertEq(vault.pendingWithdrawalDeadline(bob), bDeadline, "bob deadline intact (independent)");

        // Keeper repatriates idle (stand-in for a completed pullFromCore; the contract
        // reads only idleUsdc() and cannot tell HOW idle was funded — same device as Q6/K1).
        _fundIdle(80e6);
        assertEq(_idle(), 80e6, "idle refilled by keeper repatriation");

        // The headline claim: alice's PARTIAL remainder is immediately RE-PRIORITIZABLE
        // (reservedAssets was reset to 0) — NOT locked out by RequestAlreadyPrioritized.
        uint256 aRemainderClaim = vault.previewRedeem(aRemainder);
        uint256 secondReserve = aRemainderClaim > _idle() ? _idle() : aRemainderClaim;
        assertGt(secondReserve, 0, "remainder has a positive claim against refilled idle");

        vm.expectEmit(true, false, false, true, address(vault));
        emit WithdrawalPrioritized(alice, secondReserve, aDeadline);
        vm.prank(keeper);
        vault.prioritizeOverdue(alice); // would revert RequestAlreadyPrioritized if locked out
        assertEq(vault.pendingWithdrawalReserved(alice), secondReserve, "remainder re-reserved its new claim");
        assertEq(vault.reservedIdleUsdc(), secondReserve, "global reserve reflects the re-prioritized remainder");
        _assertIdleInvariant("BM-2 after re-prioritize remainder");

        // Now warp PAST bob's LATER deadline too (overlapping windows: bob lapses after
        // alice). His remainder-independent overdue state must come up on its OWN clock.
        vm.warp(bDeadline + 1);
        assertTrue(vault.requestIsOverdue(bob), "bob now overdue (his later window lapsed)");
        assertEq(vault.pendingWithdrawalDeadline(alice), aDeadline, "alice remainder STILL on her original deadline");

        // Fund fresh idle headroom above alice's existing remainder reserve so bob has
        // un-reserved idle to reserve against — proving bob reserves INDEPENDENTLY of
        // alice (overlapping windows resolve as two separate requests, not one queue).
        _fundIdle(50e6);
        uint256 availForBob = vault.availableIdleUsdc();
        assertGt(availForBob, 0, "un-reserved idle available for bob (independent of alice's reserve)");
        uint256 aliceReservedBeforeBob = vault.pendingWithdrawalReserved(alice);

        vm.prank(keeper);
        vault.prioritizeOverdue(bob); // independent reservation, no coupling to alice
        assertGt(vault.pendingWithdrawalReserved(bob), 0, "bob independently reserved against remaining idle");
        assertEq(
            vault.pendingWithdrawalReserved(alice),
            aliceReservedBeforeBob,
            "alice's reserve untouched by bob's independent prioritization"
        );
        _assertIdleInvariant("BM-2 after prioritize bob");

        vm.clearMockedCalls();
        console2.log("BM-2 PASS - overlapping deadlines resolve independently; partial remainder keeps its");
        console2.log("            deadline and is re-prioritizable; concurrent LPs do not couple");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // BM-3 — FAIRNESS RESERVE SCALED PAST ONE LP (>1-LP generalisation of Finding F).
    //   An overdue LP's prioritizeOverdue reserves idle so a SECOND LP's direct redeem
    //   cannot drain the reserve. Extends the Liveness test_F_overdueRequestReserves-
    //   Idle assertion (maxWithdraw routes through availableIdle) to MORE than one
    //   racing redeemer + verifies the reserve actually BINDS the redeem partial-fill.
    //   Fork-provable: FULL — the reservation accounting + the availableIdle routing
    //   are pure-EVM. (The starvation EFFECT where the cap saves a queued LP from a
    //   total drain needs NAV>idle for the racing redeems to be sub-proportional, which
    //   we manufacture with the spot-balance mock, same as M3/K1.)
    // ═════════════════════════════════════════════════════════════════════════
    function test_BM_fairness_reserve_multiLP() public {
        _skipIfNoFork();
        vault = _deployVault(0, 0); // no fees: clean redeem == previewRedeem
        vault.setRequestFulfillmentWindow(1 hours);

        // Alice (the queued/overdue LP) + two racing redeemers bob & carol enter at 1.0.
        uint256 aShares = _deposit(alice, 100e6);
        _deposit(bob, 100e6);
        _deposit(carol, 100e6);
        assertEq(_idle(), 300e6, "idle holds all three deposits");

        // Mock Core spot = 300 USDC -> NAV 600e6 > idle 300e6 (PPS 2.0). Now each LP's
        // claim (~200e6) exceeds its proportional idle slice, so a direct redeem is
        // capped to availableIdle — the race is real (Finding F precondition).
        _mockCoreSpot(300e6);
        assertEq(vault.totalAssets(), 600e6, "NAV > idle (capital parked on Core)");
        assertEq(_idle(), 300e6, "idle is half of NAV");

        // Alice queues, lapses, and her overdue claim is reserved against idle.
        vm.prank(alice);
        vault.requestWithdraw(aShares);
        uint64 aDeadline = vault.pendingWithdrawalDeadline(alice);
        vm.warp(aDeadline + 1);
        assertTrue(vault.requestIsOverdue(alice), "alice overdue");

        uint256 idleBefore = _idle();
        vm.prank(keeper);
        vault.prioritizeOverdue(alice);
        uint256 reserved = vault.pendingWithdrawalReserved(alice);
        assertGt(reserved, 0, "alice's claim reserved");
        assertEq(vault.reservedIdleUsdc(), reserved, "global reserve tracks alice");
        assertEq(vault.availableIdleUsdc(), idleBefore - reserved, "available idle reduced by the reserve");
        _assertIdleInvariant("BM-3 after prioritize alice");

        // The crux, scaled to >1 racer: BOTH bob and carol route their maxWithdraw
        // through availableIdle, so NEITHER can claim alice's reserved slice.
        uint256 avail = vault.availableIdleUsdc();
        uint256 bobOwned = vault.convertToAssets(vault.balanceOf(bob));
        uint256 carolOwned = vault.convertToAssets(vault.balanceOf(carol));
        assertEq(vault.maxWithdraw(bob), bobOwned < avail ? bobOwned : avail, "bob maxWithdraw routes through availableIdle");
        assertEq(
            vault.maxWithdraw(carol), carolOwned < avail ? carolOwned : avail, "carol maxWithdraw routes through availableIdle"
        );

        // Bob races first: he redeems as much as he can. Even a maximal drain by bob can
        // never reach below the reserve floor — availableIdle stays >= 0 and the reserve
        // is preserved for alice (idle never drops below `reserved`).
        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(bobShares, bob, bob);
        assertGe(_idle(), reserved, "idle still >= alice's reserve after bob's maximal redeem");
        assertEq(vault.reservedIdleUsdc(), reserved, "alice's reserve untouched by bob's race");
        _assertIdleInvariant("BM-3 after bob race");

        // Carol races second (the SECOND racer — the >1-LP point): she likewise cannot
        // breach the reserve floor. After both racers, the reserve still fully backs alice.
        uint256 carolShares = vault.balanceOf(carol);
        vm.prank(carol);
        vault.redeem(carolShares, carol, carol);
        assertGe(_idle(), reserved, "idle STILL >= alice's reserve after BOTH racers drained");
        assertEq(vault.reservedIdleUsdc(), reserved, "alice's reserve survives a second racer (multi-LP fairness)");
        _assertIdleInvariant("BM-3 after carol race");

        // And alice can still be fulfilled from her protected reserve — she was not
        // starved by either racer.
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(keeper);
        vault.fulfillWithdraw(alice);
        assertGt(IERC20(USDC).balanceOf(alice) - aliceBefore, 0, "alice paid from her protected reserve");
        assertEq(vault.reservedIdleUsdc(), 0, "reserve released after alice's fulfill");
        _assertIdleInvariant("BM-3 end");

        vm.clearMockedCalls();
        console2.log("BM-3 PASS - the overdue reserve survives TWO racing redeemers; the queued LP is not");
        console2.log("            starved (Finding F fairness generalised past a single LP)");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // BM-4 — FULL PERMISSIONLESS ESCAPE END-TO-END (trigger -> 4 legs -> fulfill ->
    //   exitEscape) under a mocked NAV>idle state.
    //   Drive the whole machine: set the SLA window + escapeGraceSeconds (4h floor),
    //   one LP requests with claim > availableIdle, warp past deadline + grace, an
    //   UNPRIVILEGED address (not operator/admin) calls triggerEscape, then runs the
    //   4 legs (warping >= 60s between each for the crank cooldown), then fulfillWithdraw,
    //   then exitEscape. Assert escapeActive() flips true at trigger / false after exit,
    //   and that deposits revert EscapeModeActive() while latched.
    //   Mocking mirrors the existing escape tests EXACTLY (MockCoreWriter etched; the
    //   legs assert the latch/gate/cooldown/event STATE MACHINE, not Core settlement).
    // ═════════════════════════════════════════════════════════════════════════
    function test_BM_escape_end_to_end() public {
        _skipIfNoFork();
        vm.etch(Constants.CORE_WRITER, type(MockCoreWriter).runtimeCode);
        vault = _deployVault(0, 0);
        // Re-etch is unnecessary (CORE_WRITER is an address constant, persists across
        // the redeploy), but the mock stays etched for the whole test.

        // (a) Governance: set the SLA window + escapeGraceSeconds to the 4h FLOOR.
        vault.setRequestFulfillmentWindow(1 hours);
        vault.setEscapeGraceSeconds(4 hours);
        uint64 window = vault.requestFulfillmentWindow();
        uint64 grace = vault.escapeGraceSeconds();
        assertEq(grace, 4 hours, "grace set to the 4h floor");

        // Deposits are open before arming; sanity the latch starts off.
        assertFalse(vault.escapeActive(), "escape inactive at start");
        assertGt(vault.maxDeposit(bob), 0, "deposits open before arming");

        // One LP (alice) deposits + requests her full position. Mock NAV>idle so her
        // claim genuinely exceeds idle once reserved (the fork-faithful "unfillable"
        // state) — though the arming inequality is on availableIdle, which the reserve
        // zeroes; the Core mock keeps NAV intact so previewRedeem stays at the full claim.
        uint256 aShares = _deposit(alice, 100e6);
        _mockCoreSpot(100e6); // NAV 200e6 > idle 100e6
        assertEq(vault.totalAssets(), 200e6, "NAV > idle (claim > idle for real)");

        vm.prank(alice);
        vault.requestWithdraw(aShares);

        // Warp PAST deadline + grace (the SOLU-3371 staleness condition leg (a)).
        vm.warp(block.timestamp + window + grace + 1);
        assertTrue(vault.requestIsOverdue(alice), "alice overdue past deadline + grace");

        // Reserve alice's claim so availableIdle drops to 0 < claim (leg (b): claim >
        // availableIdle). prioritizeOverdue is permissionless.
        vm.prank(keeper);
        vault.prioritizeOverdue(alice);
        assertEq(vault.availableIdleUsdc(), 0, "reserve zeroed availableIdle (claim now > available)");
        assertGt(vault.previewRedeem(aShares), vault.availableIdleUsdc(), "claim > availableIdle (unfillable)");
        _assertIdleInvariant("BM-4 after prioritize");

        // ── TRIGGER: an UNPRIVILEGED caller (attacker holds no role) arms the brake. ──
        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
        bytes32 opRole = vault.OPERATOR_ROLE();
        assertFalse(vault.hasRole(adminRole, attacker), "attacker holds no admin role");
        assertFalse(vault.hasRole(opRole, attacker), "attacker holds no operator role");

        vm.expectEmit(true, true, false, true, address(vault));
        emit EscapeActivated(attacker, alice); // armed BY the arbitrary caller
        vm.prank(attacker);
        vault.triggerEscape(alice);
        assertTrue(vault.escapeActive(), "escapeActive() flipped TRUE at trigger (permissionless)");

        // While latched: deposits revert EscapeModeActive().
        deal(USDC, bob, 100e6);
        vm.startPrank(bob);
        IERC20(USDC).approve(address(vault), 100e6);
        vm.expectRevert(IHyperCoreVault.EscapeModeActive.selector);
        vault.deposit(100e6, bob);
        vm.stopPrank();
        assertEq(vault.maxDeposit(bob), 0, "maxDeposit==0 while latched");

        // ── THE 4 LEGS, each by an UNPRIVILEGED caller, warping >= 60s between for the
        //    crank cooldown. On a fork the cranks run their gate + emit their event; the
        //    CoreWriter actions are observed via the etched stub (settlement is live-only). ──
        uint64 interval = vault.escapeCrankInterval();
        assertEq(interval, 60, "crank interval is the fixed 60s envelope");

        // Leg 1 — escapeCancelOrders (empty cloid list: passes the gate, stamps the
        // cooldown, emits EscapeCrankRun(.,1)). First crank runs immediately.
        uint128[] memory noCloids = new uint128[](0);
        vm.expectEmit(true, true, false, true, address(vault));
        emit EscapeCrankRun(attacker, 1);
        vm.prank(attacker);
        vault.escapeCancelOrders(0, noCloids);

        // Leg 2 — escapeFlattenPerps (empty arrays: nothing to flatten, but the gate +
        // cooldown + event run). Warp past the cooldown first.
        vm.warp(block.timestamp + interval);
        uint32[] memory noPerps = new uint32[](0);
        uint64[] memory noPxs = new uint64[](0);
        vm.expectEmit(true, true, false, true, address(vault));
        emit EscapeCrankRun(attacker, 2);
        vm.prank(attacker);
        vault.escapeFlattenPerps(noPerps, noPxs);

        // Leg 3 — escapeConsolidateToSpot (withdrawable reads 0 on the fork -> no
        // perp->spot action, but the gate runs + EscapeCrankRun(.,3) fires).
        vm.warp(block.timestamp + interval);
        vm.expectEmit(true, true, false, true, address(vault));
        emit EscapeCrankRun(attacker, 3);
        vm.prank(attacker);
        vault.escapeConsolidateToSpot();

        // Leg 4 — escapePullToEvm (the Core balance reads 0 on the fork -> the fee-aware
        // amount is 0 -> no send_asset, but the gate runs + EscapeCrankRun(.,4) fires).
        // We pass type(uint64).max as the chunk cap (the fee guard / balance bound it).
        vm.warp(block.timestamp + interval);
        vm.expectEmit(true, true, false, true, address(vault));
        emit EscapeCrankRun(attacker, 4);
        vm.prank(attacker);
        vault.escapePullToEvm(type(uint64).max);

        assertTrue(vault.escapeActive(), "still latched through all 4 legs");

        // ── FULFILL: resolve alice's overdue-unfillable request, so no backlog remains
        //    (exitEscape uses the same overdue-unfillable predicate). The fulfill is
        //    permissionless + ungated by ESCAPE mode. ──
        // The escape pull (leg 4a) would, live, land Core USDC as EVM idle — here we
        // model that completed repatriation the same way Q6/K1 do: drop the Core mock
        // (the capital moved Core->idle, so NAV is now all in idle) and `deal` idle to
        // cover alice's full claim. The contract reads only idleUsdc() and cannot tell
        // HOW idle was funded, so this is a faithful stand-in for leg-4a settlement.
        uint256 aliceClaim = vault.previewRedeem(vault.pendingWithdrawalShares(alice));
        vm.clearMockedCalls(); // Core capital now repatriated to idle -> NAV == idle
        deal(USDC, address(vault), aliceClaim); // idle now fully covers her claim
        _assertIdleInvariant("BM-4 after repatriation");

        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(keeper);
        vault.fulfillWithdraw(alice);
        assertGt(IERC20(USDC).balanceOf(alice) - aliceBefore, 0, "alice paid from idle while/after latched");
        assertEq(vault.pendingWithdrawalShares(alice), 0, "alice's request fully resolved (no backlog)");
        assertEq(vault.reservedIdleUsdc(), 0, "reserve fully released on fulfill");

        // ── EXIT: clears the latch now that no overdue-unfillable request remains. ──
        address[] memory lps = new address[](1);
        lps[0] = alice;
        vm.expectEmit(true, false, false, true, address(vault));
        emit EscapeDeactivated(address(this));
        vault.exitEscape(lps);
        assertFalse(vault.escapeActive(), "escapeActive() flipped FALSE after exit");

        // Post-exit: deposits are open again (the latch was the only gate).
        assertGt(vault.maxDeposit(bob), 0, "deposits reopen after exitEscape");
        uint256 bobShares = _deposit(bob, 50e6);
        assertGt(bobShares, 0, "deposit succeeds again after exit");

        console2.log("BM-4 PASS - full permissionless escape e2e: trigger (unprivileged) -> 4 legs (60s-spaced)");
        console2.log("            -> fulfill -> exitEscape; escapeActive true@trigger/false@exit; deposits gated while latched");
    }
}
