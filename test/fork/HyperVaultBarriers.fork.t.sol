// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HyperVaultBaseForkTest} from "./HyperVaultBase.fork.t.sol";
import {IHyperCoreVault} from "../../src/interfaces/IHyperCoreVault.sol";

/// @title  Soft-redemption-barrier proofs (forked HyperEVM mainnet, real USDC)
/// @notice M4 (SOLU-3366 / assessment TODO-7). Proves the three admin-configurable
///         soft barriers (lockup / cooldown / per-tx gate) as require-checks on the
///         SYNCHRONOUS exit paths, and — the load-bearing invariant — that the
///         {requestWithdraw} queue + the emergency surface are NEVER barrier-gated
///         (assessment Findings A/B: redemption liveness is preserved; the queue is
///         the always-available escape). All barriers default to 0/OFF; the no-op
///         regression confirms a vault that never opts in is unchanged.
///
///         Substrate note: a forge fork cannot serve the HyperCore precompiles, so
///         totalAssets() == idleUsdc() here (Core/perp NAV read as 0). That is fine
///         for these proofs — the barriers are pure-EVM accounting/timing checks and
///         the gate's NAV denominator is simply the idle pool on this substrate. The
///         barrier LOGIC is identical regardless of where NAV sits.
contract HyperVaultBarriersForkTest is HyperVaultBaseForkTest {
    // Mirror the M4 event for vm.expectEmit (matched by signature + data).
    event RedemptionBarriersUpdated(uint64 lockup, uint64 cooldown, uint16 gateBps);

    uint64 internal constant LOCKUP = 7 days;
    uint64 internal constant COOLDOWN = 1 days;

    // M4 (SOLU-3366) / EIP-170: the vault's barrier-state VIEW GETTERS
    // (redemptionBarriers / lastDepositAt / lastRedeemAt) were dropped to fit the
    // 24576-byte runtime limit (see the vault + docs/INTEGRATION.md). The state is
    // unchanged — it lives in the {VaultBarrierLib} ERC-7201 namespaced slot — so
    // these tests read it directly with `vm.load` exactly as an off-chain integrator
    // would via `eth_getStorageAt`, and the behavioural assertions are identical to
    // the dropped-getter version. SLOT mirrors {VaultBarrierLib.SLOT}.
    bytes32 internal constant BARRIER_SLOT = 0x77baf71947acbe45a89d2c84006fb2f1cbe1654c8023f6853f43b8e463ccc600;

    /// @dev Read the packed config word (= the dropped `redemptionBarriers()`).
    function _barriers() internal view returns (uint64 lockup, uint64 cooldown, uint16 gateBps) {
        uint256 word = uint256(vm.load(address(vault), BARRIER_SLOT));
        lockup = uint64(word);
        cooldown = uint64(word >> 64);
        gateBps = uint16(word >> 128);
    }

    /// @dev Read `lp`'s lockup clock (= the dropped `lastDepositAt(lp)`): mapping at
    ///      struct member 1 (SLOT+1), element = keccak256(key, base).
    function _lastDepositAt(address lp) internal view returns (uint64) {
        bytes32 base = bytes32(uint256(BARRIER_SLOT) + 1);
        bytes32 elem = keccak256(abi.encode(lp, base));
        return uint64(uint256(vm.load(address(vault), elem)));
    }

    /// @dev Read `lp`'s cooldown clock (= the dropped `lastRedeemAt(lp)`): mapping at
    ///      struct member 2 (SLOT+2).
    function _lastRedeemAt(address lp) internal view returns (uint64) {
        bytes32 base = bytes32(uint256(BARRIER_SLOT) + 2);
        bytes32 elem = keccak256(abi.encode(lp, base));
        return uint64(uint256(vm.load(address(vault), elem)));
    }

    // ── B0 — default OFF is a true no-op: withdraw/redeem behave as before ─────
    function test_B0_defaultOffIsNoOp() public {
        _skipIfNoFork();
        // Sanity: the three knobs read 0 at deploy.
        (uint64 lk, uint64 cd, uint16 gb) = _barriers();
        assertEq(lk, 0, "lockup default 0");
        assertEq(cd, 0, "cooldown default 0");
        assertEq(gb, 0, "gate default 0");

        uint256 shares = _deposit(alice, 100e6);
        // An immediate, full redeem in the same block succeeds exactly as on main —
        // no lockup, no cooldown, no gate, full idle available.
        uint256 before = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        uint256 got = vault.redeem(shares, alice, alice);
        assertEq(got, 100e6, "default-OFF redeem returns full assets (unchanged behaviour)");
        assertEq(IERC20(USDC).balanceOf(alice) - before, 100e6, "alice received the full payout");
        assertEq(vault.balanceOf(alice), 0, "all shares burned");
        // lastRedeemAt is NOT stamped on the all-OFF fast path (no barrier active).
        assertEq(_lastRedeemAt(alice), 0, "no cooldown stamp while all barriers OFF");
        console2.log("B0 PASS - all barriers 0 -> withdraw/redeem identical to pre-M4");
    }

    // ── B1 — setter: admin-only, validates, emits, and is reflected by getters ─
    function test_B1_setterAuthEmitAndGetters() public {
        _skipIfNoFork();
        // Non-admin cannot set (AccessControl revert).
        vm.prank(attacker);
        vm.expectRevert();
        vault.setRedemptionBarriers(LOCKUP, COOLDOWN, 5000);

        // gateBps > BPS (100% of NAV) is rejected.
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.RedeemGateBpsTooHigh.selector, uint16(10001)));
        vault.setRedemptionBarriers(0, 0, 10001);

        // Admin (== address(this)) sets all three; one event; getters reflect it.
        vm.expectEmit(false, false, false, true, address(vault));
        emit RedemptionBarriersUpdated(LOCKUP, COOLDOWN, 5000);
        vault.setRedemptionBarriers(LOCKUP, COOLDOWN, 5000);

        (uint64 lk, uint64 cd, uint16 gb) = _barriers();
        assertEq(lk, LOCKUP, "lockup stored");
        assertEq(cd, COOLDOWN, "cooldown stored");
        assertEq(gb, 5000, "gate stored");
        console2.log("B1 PASS - setRedemptionBarriers: admin-only, bps-capped, emits, getters reflect");
    }

    // ── B2 — LOCKUP gates the sync path; warp past it clears it ────────────────
    function test_B2_lockupBlocksThenAllowsSyncExit() public {
        _skipIfNoFork();
        uint256 shares = _deposit(alice, 100e6);
        uint64 depositTs = uint64(block.timestamp);
        assertEq(_lastDepositAt(alice), depositTs, "deposit stamped the lockup clock");

        vault.setRedemptionBarriers(LOCKUP, 0, 0); // lockup only

        // Inside the lockup -> sync redeem reverts with the unlock timestamp.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.LockupNotElapsed.selector, depositTs + LOCKUP));
        vault.redeem(shares, alice, alice);

        // withdraw is gated identically.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.LockupNotElapsed.selector, depositTs + LOCKUP));
        vault.withdraw(10e6, alice, alice);

        // At exactly unlock (>=) the sync exit succeeds.
        vm.warp(depositTs + LOCKUP);
        vm.prank(alice);
        uint256 got = vault.redeem(shares, alice, alice);
        assertEq(got, 100e6, "redeem succeeds at/after unlock");
        console2.log("B2 PASS - lockup blocks the sync exit inside the window, allows it at unlock");
    }

    // ── B3 — a re-deposit REFRESHES the lockup (most-recent deposit governs) ───
    function test_B3_reDepositRefreshesLockup() public {
        _skipIfNoFork();
        uint256 s1 = _deposit(alice, 100e6);
        uint64 t0 = uint64(block.timestamp);
        vault.setRedemptionBarriers(LOCKUP, 0, 0);

        // Warp ALMOST to the first unlock, then top up: the clock resets to now.
        vm.warp(t0 + LOCKUP - 1);
        uint256 s2 = _deposit(alice, 50e6);
        uint64 t1 = uint64(block.timestamp);
        assertEq(_lastDepositAt(alice), t1, "re-deposit refreshed the lockup clock");

        // The OLD unlock has now passed, but the refreshed lockup still blocks.
        vm.warp(t0 + LOCKUP + 1); // past the original unlock...
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.LockupNotElapsed.selector, t1 + LOCKUP));
        vault.redeem(s1 + s2, alice, alice); // ...still locked by the refreshed clock

        // Only after the REFRESHED unlock does it clear.
        vm.warp(t1 + LOCKUP);
        vm.prank(alice);
        uint256 got = vault.redeem(s1 + s2, alice, alice);
        assertEq(got, 150e6, "redeem clears only after the refreshed lockup");
        console2.log("B3 PASS - a re-deposit refreshes the lockup from the most-recent deposit");
    }

    // ── B4 — COOLDOWN: a second sync redeem inside the window reverts ──────────
    function test_B4_cooldownBlocksSecondRedeem() public {
        _skipIfNoFork();
        uint256 shares = _deposit(alice, 100e6);
        vault.setRedemptionBarriers(0, COOLDOWN, 0); // cooldown only

        // First redeem (half) succeeds and stamps the cooldown clock.
        vm.prank(alice);
        vault.redeem(shares / 2, alice, alice);
        uint64 firstTs = uint64(block.timestamp);
        assertEq(_lastRedeemAt(alice), firstTs, "first sync redeem stamped the cooldown clock");

        // A second redeem inside the cooldown reverts with the ready timestamp.
        vm.warp(firstTs + COOLDOWN - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.RedeemCooldownActive.selector, firstTs + COOLDOWN));
        vault.redeem(shares / 4, alice, alice);

        // After the cooldown lapses it succeeds (and re-stamps).
        vm.warp(firstTs + COOLDOWN);
        vm.prank(alice);
        uint256 got = vault.redeem(shares / 4, alice, alice);
        assertGt(got, 0, "second redeem succeeds after cooldown");
        assertEq(_lastRedeemAt(alice), firstTs + COOLDOWN, "cooldown clock re-stamped");
        console2.log("B4 PASS - cooldown blocks a second sync redeem until it lapses");
    }

    // ── B5 — GATE: a direct exit above gate%·NAV reverts; within-gate succeeds ─
    function test_B5_gateBoundsDirectExitSize() public {
        _skipIfNoFork();
        uint256 shares = _deposit(alice, 100e6); // NAV == idle == 100e6 on a fork
        vault.setRedemptionBarriers(0, 0, 5000); // 50% per-tx gate -> cap 50e6

        uint256 nav = vault.totalAssets();
        assertEq(nav, 100e6, "fork NAV == idle");
        uint256 cap = (nav * 5000) / 10_000;

        // A full redeem (gross 100e6 > cap 50e6) reverts with (requested, cap).
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.RedeemGateExceeded.selector, uint256(100e6), cap));
        vault.redeem(shares, alice, alice);

        // withdraw of >cap assets is gated identically.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.RedeemGateExceeded.selector, uint256(60e6), cap));
        vault.withdraw(60e6, alice, alice);

        // A within-gate redeem (gross == cap == 50e6) succeeds.
        vm.prank(alice);
        uint256 got = vault.redeem(shares / 2, alice, alice);
        assertEq(got, 50e6, "within-gate exit (== cap) succeeds");
        console2.log("B5 PASS - the gate bounds a single direct exit to gateBps of NAV");
    }

    // ── B6 — the over-gate remainder exits via the UNGATED requestWithdraw queue ─
    function test_B6_overGateExitGoesThroughUngatedQueue() public {
        _skipIfNoFork();
        uint256 shares = _deposit(alice, 100e6);
        vault.setRedemptionBarriers(0, 0, 2000); // 20% gate -> a full exit is over-gate

        // Direct full redeem is gated...
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IHyperCoreVault.RedeemGateExceeded.selector, uint256(100e6), uint256(20e6))
        );
        vault.redeem(shares, alice, alice);

        // ...but the queue is NOT gated: requestWithdraw(all) escrows fine, and a
        // keeper fulfillWithdraw pays the full claim (queue ignores every barrier).
        vm.prank(alice);
        vault.requestWithdraw(shares);
        assertEq(vault.pendingWithdrawalShares(alice), shares, "full request escrowed despite the gate");

        uint256 before = IERC20(USDC).balanceOf(alice);
        vm.prank(keeper);
        vault.fulfillWithdraw(alice);
        assertEq(IERC20(USDC).balanceOf(alice) - before, 100e6, "queue paid the full over-gate amount");
        assertEq(vault.pendingWithdrawalShares(alice), 0, "request cleared");
        console2.log("B6 PASS - over-gate exits route through the ungated requestWithdraw queue");
    }

    // ── B7 — the queue + cancel are NOT gated while lockup AND cooldown block sync ─
    function test_B7_queueAndCancelUngatedWhileBarriersBlockSync() public {
        _skipIfNoFork();
        uint256 shares = _deposit(alice, 100e6);
        uint64 depositTs = uint64(block.timestamp);
        // Maximal friction on the sync path: lockup + cooldown + tight gate.
        vault.setRedemptionBarriers(LOCKUP, COOLDOWN, 1000);

        // Sync redeem is blocked (lockup is checked first).
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.LockupNotElapsed.selector, depositTs + LOCKUP));
        vault.redeem(shares, alice, alice);

        // requestWithdraw works regardless of the active barriers...
        vm.prank(alice);
        vault.requestWithdraw(shares);
        assertEq(vault.pendingWithdrawalShares(alice), shares, "request escrowed under full barriers");

        // ...cancel works too (returns the escrowed shares)...
        vm.prank(alice);
        vault.cancelWithdrawRequest();
        assertEq(vault.balanceOf(alice), shares, "cancel restored shares under full barriers");

        // ...and a keeper can fulfill a fresh request while the sync path stays blocked.
        vm.prank(alice);
        vault.requestWithdraw(shares);
        uint256 before = IERC20(USDC).balanceOf(alice);
        vm.prank(keeper);
        vault.fulfillWithdraw(alice);
        assertEq(IERC20(USDC).balanceOf(alice) - before, 100e6, "fulfill paid while barriers blocked sync");
        console2.log("B7 PASS - requestWithdraw/cancel/fulfill are never barrier-gated (Findings A/B liveness)");
    }

    // ── B8 — prioritizeOverdue (the permissionless fairness crank) is NOT gated ─
    function test_B8_prioritizeOverdueUngatedUnderBarriers() public {
        _skipIfNoFork();
        // A short SLA window so the request goes overdue; full barriers on the sync path.
        vault.setRequestFulfillmentWindow(1 hours);
        uint256 shares = _deposit(alice, 100e6);
        vault.setRedemptionBarriers(LOCKUP, COOLDOWN, 1000);

        vm.prank(alice);
        vault.requestWithdraw(shares);
        uint64 deadline = vault.pendingWithdrawalDeadline(alice);
        assertGt(deadline, 0, "SLA deadline stamped");

        // Past the deadline, anyone may prioritize — barriers do not touch this path.
        vm.warp(uint256(deadline) + 1);
        vm.prank(keeper);
        vault.prioritizeOverdue(alice);
        assertEq(vault.pendingWithdrawalReserved(alice), 100e6, "overdue claim reserved despite barriers");
        assertEq(vault.reservedIdleUsdc(), 100e6, "idle reserved for the overdue LP");
        console2.log("B8 PASS - prioritizeOverdue is never barrier-gated");
    }

    // ── B9 — emergency repatriation movers are NOT barrier-gated ───────────────
    function test_B9_emergencyPathsUngatedUnderBarriers() public {
        _skipIfNoFork();
        _deposit(alice, 100e6);
        vault.setRedemptionBarriers(LOCKUP, COOLDOWN, 1000); // full friction on sync

        // pause + the emergency repatriate path are about LIVENESS — they must not be
        // gated by the soft barriers (nor by pause). usdPerpToSpot (perp->spot, Core
        // side) submits a CoreWriter action; on a fork it does not revert at any
        // barrier (the movers never call the barrier library). A pure-EVM check:
        vm.prank(emergency);
        vault.pause();

        // emergencyRepatriate (perp->spot only; spotSendWei==0) submits and emits,
        // independent of the barriers and of pause (Finding A).
        vm.prank(emergency);
        vault.emergencyRepatriate(USDC_BRIDGE, 1, 0);
        console2.log("B9 PASS - emergency repatriation submits while sync barriers + pause are active");
    }
}
