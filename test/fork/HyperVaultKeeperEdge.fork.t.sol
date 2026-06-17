// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HyperVaultBaseForkTest} from "./HyperVaultBase.fork.t.sol";
import {IHyperCoreVault} from "../../src/interfaces/IHyperCoreVault.sol";
import {PrecompileLib} from "../../src/libraries/PrecompileLib.sol";
import {Constants} from "../../src/libraries/Constants.sol";

/// @title  Keeper edge-case proofs — partial-fulfill reserve re-prioritization (SOLU-3368 / TODO-10)
/// @notice TODO-10 part 1: when a PARTIAL {fulfillWithdraw} releases the overdue reserve, the
///         remainder request must NOT be starved — it keeps its `fulfillmentDeadline`, has its
///         `reservedAssets` reset to 0, and is therefore immediately re-prioritizable by a keeper
///         (no {RequestAlreadyPrioritized} lock-out). This proves the keeper's
///         "re-prioritize-the-remainder" loop works against the SHIPPED contract, with NO Solidity
///         logic change (the behaviour is already correct — see the trace in the assertions below).
///
///         Substrate note (identical justification to Q-test M3): the partial-fill precondition is
///         `idle < claim`, which requires NAV > idle, i.e. capital deployed on Core. A plain forge
///         fork reads the HyperCore spot-balance precompile (0x801) as empty, so coreSpotUsdc() == 0
///         and totalAssets() == idleUsdc() (no gap). The claims under test here are PURE-EVM queue /
///         reserve accounting invariants (NOT Core-behaviour claims), so we manufacture the NAV>idle
///         gap by mocking the spotBalance precompile read — exactly as test_M3 does for its math.
///         The live-spike (scripts/python/e2e_runner.py) covers the Core-behaviour side.
contract HyperVaultKeeperEdgeForkTest is HyperVaultBaseForkTest {
    event WithdrawalPrioritized(address indexed lp, uint256 reservedAssets, uint64 deadline);

    /// @dev Mock the vault's Core spot USDC balance (8dp Core wei) so coreSpotUsdc() reports
    ///      `humanUsdc` and totalAssets() = idle + that. Mirrors test_M3's manufacture of NAV>idle.
    function _mockCoreSpot(uint256 humanUsdc) internal {
        PrecompileLib.SpotBalance memory bal =
            PrecompileLib.SpotBalance({total: uint64(humanUsdc * 100), hold: 0, entryNtl: 0});
        vm.mockCall(
            Constants.SPOT_BALANCE_PRECOMPILE, abi.encode(address(vault), uint64(0)), abi.encode(bal)
        );
    }

    // ── K1 — partial fulfill releases the reserve; the remainder is re-prioritizable ──────────────
    //
    //   Full keeper loop under test:
    //     deposit → (NAV>idle) → request → warp past deadline → prioritizeOverdue (reserve = idle)
    //       → fulfillWithdraw (PARTIAL: pays idle, releases the WHOLE reserve, remainder keeps deadline)
    //       → keeper refills idle → prioritizeOverdue AGAIN on the remainder (must NOT revert; reserves anew)
    function test_K1_partialFulfillRemainderIsReprioritizable() public {
        _skipIfNoFork();
        vault = _deployVault(0, 0); // no fees: payout == previewRedeem exactly; reserve math is clean

        // Alice is the sole LP: 100 USDC idle, all shares hers.
        uint256 aShares = _deposit(alice, 100e6);

        // Manufacture NAV > idle: Core spot = 100 USDC → NAV 200e6, idle 100e6, PPS 2.0.
        // Alice's full claim (~200e6) therefore exceeds idle (100e6) → fulfill can only PARTIAL-fill.
        _mockCoreSpot(100e6);
        assertEq(vault.coreSpotUsdc(), 100e6, "mocked Core spot");
        assertEq(vault.totalAssets(), 200e6, "NAV > idle (capital parked on Core)");
        assertEq(_idle(), 100e6, "idle is half of NAV");

        // Short SLA so we can make the request overdue with a single warp.
        vault.setRequestFulfillmentWindow(1 hours);

        // Alice queues her full position.
        vm.prank(alice);
        vault.requestWithdraw(aShares);
        uint64 deadline = vault.pendingWithdrawalDeadline(alice);
        assertGt(deadline, 0, "deadline stamped");
        assertEq(vault.pendingWithdrawalShares(alice), aShares, "full position escrowed");

        // Lapse the SLA → the request is overdue and prioritizable.
        vm.warp(deadline + 1);
        assertTrue(vault.requestIsOverdue(alice), "request overdue after warp");

        // ── prioritizeOverdue: reserve the request's CURRENT claim, capped at available idle ──
        uint256 fullClaim = vault.previewRedeem(aShares); // ~200e6
        uint256 firstReserve = fullClaim > _idle() ? _idle() : fullClaim; // capped at 100e6
        assertEq(firstReserve, 100e6, "first reserve capped at idle");

        vm.expectEmit(true, false, false, true, address(vault));
        emit WithdrawalPrioritized(alice, firstReserve, deadline);
        vm.prank(keeper);
        vault.prioritizeOverdue(alice);

        assertEq(vault.pendingWithdrawalReserved(alice), firstReserve, "reserve recorded on the request");
        assertEq(vault.reservedIdleUsdc(), firstReserve, "global reserve == request reserve");
        assertEq(vault.availableIdleUsdc(), 0, "all idle now reserved");

        // A SECOND prioritize before any fulfill must hit the already-prioritized guard.
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.RequestAlreadyPrioritized.selector, alice));
        vault.prioritizeOverdue(alice);

        // ── fulfillWithdraw: PARTIAL fill (grossPossible ~200e6 > drawable 100e6) ──
        uint256 idleForFill = vault.availableIdleUsdc() + vault.pendingWithdrawalReserved(alice); // 0 + 100e6
        uint256 expectedOutShares = vault.previewWithdraw(idleForFill); // shares burned for 100e6 out
        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);

        vm.prank(keeper);
        vault.fulfillWithdraw(alice);

        // ----- ASSERT the partial-fulfill post-state (the crux of TODO-10) -----
        uint256 remainder = vault.pendingWithdrawalShares(alice);
        assertEq(remainder, aShares - expectedOutShares, "remainder shares == original - filled");
        assertGt(remainder, 0, "a genuine remainder exists (partial, not full, fill)");
        assertEq(vault.pendingWithdrawalReserved(alice), 0, "PARTIAL fulfill RESET reservedAssets to 0");
        assertEq(vault.reservedIdleUsdc(), 0, "global _reservedIdle fully released (no stranded idle)");
        assertEq(vault.pendingWithdrawalDeadline(alice), deadline, "remainder PRESERVES the original deadline");
        assertTrue(vault.requestIsOverdue(alice), "remainder is STILL overdue (deadline preserved & lapsed)");
        assertEq(IERC20(USDC).balanceOf(alice) - aliceUsdcBefore, idleForFill, "LP paid exactly the idle drawn");
        assertEq(_idle(), 0, "idle fully drained by the partial fill");

        // ── keeper refills idle (stand-in for a completed operator pullFromCore: the contract reads
        //    only idleUsdc() and cannot tell HOW idle was funded — same device as Q6). Core spot mock
        //    stays at 100e6; releasing it to idle is the repatriation the keeper performs off-chain. ──
        _fundIdle(60e6);
        assertEq(_idle(), 60e6, "idle refilled by keeper repatriation");

        // ── prioritizeOverdue AGAIN on the remainder — the headline claim: this MUST NOT revert
        //    RequestAlreadyPrioritized (reservedAssets was reset to 0), and reserves the remainder's
        //    NEW claim, capped at the freshly-available idle. The remainder is NOT starved. ──
        uint256 remainderClaim = vault.previewRedeem(remainder);
        uint256 secondReserve = remainderClaim > _idle() ? _idle() : remainderClaim;
        assertGt(secondReserve, 0, "remainder has a positive claim to reserve against refilled idle");

        vm.expectEmit(true, false, false, true, address(vault));
        emit WithdrawalPrioritized(alice, secondReserve, deadline);
        vm.prank(keeper);
        vault.prioritizeOverdue(alice); // <-- would revert if the remainder were locked out

        assertEq(vault.pendingWithdrawalReserved(alice), secondReserve, "remainder re-reserved its new claim");
        assertEq(vault.reservedIdleUsdc(), secondReserve, "global reserve reflects the re-prioritized remainder");

        console2.log("K1 PASS - partial fulfill releases the reserve; remainder keeps its deadline and");
        console2.log("          is immediately re-prioritizable by a keeper (no RequestAlreadyPrioritized lock-out)");
    }

    // ── K2 — re-prioritized remainder fulfills cleanly to completion (loop terminates) ────────────
    //
    //   Continues K1's logic to its end: once idle covers the remainder's claim, the next fulfill
    //   fully clears the request and releases the second reserve — the keeper loop terminates, no
    //   reserve is left stranded. Proves the re-prioritize path is not just non-reverting but useful.
    function test_K2_reprioritizedRemainderFulfillsToCompletion() public {
        _skipIfNoFork();
        vault = _deployVault(0, 0);

        uint256 aShares = _deposit(alice, 100e6);
        _mockCoreSpot(100e6); // NAV 200e6 > idle 100e6
        vault.setRequestFulfillmentWindow(1 hours);

        vm.prank(alice);
        vault.requestWithdraw(aShares);
        uint64 deadline = vault.pendingWithdrawalDeadline(alice);
        vm.warp(deadline + 1);

        // First cycle: prioritize + PARTIAL fulfill (drains the 100e6 idle).
        vm.prank(keeper);
        vault.prioritizeOverdue(alice);
        vm.prank(keeper);
        vault.fulfillWithdraw(alice);
        uint256 remainder = vault.pendingWithdrawalShares(alice);
        assertGt(remainder, 0, "partial: remainder remains");

        // Keeper repatriates ENOUGH idle to clear the remainder's full claim, then re-prioritizes.
        // Drop the Core mock to 0 (it was moved to idle) so NAV == idle and the claim is fully covered.
        _mockCoreSpot(0);
        _fundIdle(vault.previewRedeem(remainder) + 1e6); // comfortably covers the remainder claim
        vm.prank(keeper);
        vault.prioritizeOverdue(alice); // re-prioritize the remainder — must not revert

        // Final fulfill: full clear.
        uint256 expectedPay = vault.previewRedeem(remainder);
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(keeper);
        vault.fulfillWithdraw(alice);

        assertEq(vault.pendingWithdrawalShares(alice), 0, "request fully cleared");
        assertEq(vault.pendingWithdrawalReserved(alice), 0, "no reserve left on the request");
        assertEq(vault.reservedIdleUsdc(), 0, "global reserve fully released (loop terminated, nothing stranded)");
        assertEq(vault.balanceOf(address(vault)), 0, "escrow fully burned");
        assertApproxEqAbs(IERC20(USDC).balanceOf(alice) - aliceBefore, expectedPay, 1, "remainder paid in full");

        console2.log("K2 PASS - re-prioritized remainder fulfills to completion; keeper loop terminates,");
        console2.log("          no reserve stranded");
    }
}
