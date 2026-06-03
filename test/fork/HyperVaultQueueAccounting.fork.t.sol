// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HyperVaultBaseForkTest} from "./HyperVaultBase.fork.t.sol";
import {IHyperCoreVault} from "../../src/interfaces/IHyperCoreVault.sol";

/// @title  Withdrawal-queue accounting proofs (forked HyperEVM mainnet, real USDC)
/// @notice These are deterministic unit tests of the bespoke escrow queue
///         (requestWithdraw / fulfillWithdraw / cancelWithdrawRequest). They run on
///         the fork against the real USDC token (no mocks). Expected share/asset
///         amounts are read from the contract's own preview functions so OZ's
///         Ceil/Floor rounding is honoured exactly rather than hand-rolled.
///
///         NOTE on coverage: the PARTIAL-fill cases (idle < claim) require NAV > idle,
///         i.e. capital genuinely deployed on Core. A plain forge fork cannot represent
///         that (revm does not serve the HyperCore precompiles, so totalAssets() ==
///         idleUsdc()), and the no-mocks rule forbids faking it — so the partial split
///         is proven on the live spike (scripts/python/e2e_runner.py). Everything that
///         does not need a NAV>idle gap is proven here.
contract HyperVaultQueueAccountingForkTest is HyperVaultBaseForkTest {
    // ── Q1 — request escrows exactly the shares, zeros free balance, emits ─────
    function test_Q1_requestEscrowsExactlyAndEmits() public {
        _skipIfNoFork();
        uint256 shares = _deposit(alice, 100e6);

        vm.expectEmit(true, false, false, true, address(vault));
        emit WithdrawalRequested(alice, shares);
        vm.prank(alice);
        vault.requestWithdraw(shares);

        assertEq(vault.balanceOf(alice), 0, "free balance zeroed");
        assertEq(vault.balanceOf(address(vault)), shares, "escrow holds exactly the requested shares");
        assertEq(vault.pendingWithdrawalShares(alice), shares, "pending == requested");
        console2.log("Q1 PASS - requestWithdraw escrows exactly the shares and emits WithdrawalRequested");
    }

    // ── Q2 — one open request per LP (guard isolated with a partial request) ───
    function test_Q2_oneOpenRequestPerLp() public {
        _skipIfNoFork();
        uint256 shares = _deposit(alice, 100e6);

        vm.prank(alice);
        vault.requestWithdraw(shares / 2); // partial -> alice keeps shares/2 free balance

        // A second request, well within remaining free balance, must still hit the
        // one-open-request-per-LP guard (reported as (requested, 0)).
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IHyperCoreVault.WithdrawExceedsIdleBalance.selector, uint256(1), uint256(0))
        );
        vault.requestWithdraw(1);
        console2.log("Q2 PASS - one open request per LP (second reverts even with free balance)");
    }

    // ── Q2b — over-balance reverts; zero request is a clean no-op ──────────────
    function test_Q2_overBalanceAndZeroGuards() public {
        _skipIfNoFork();
        uint256 shares = _deposit(alice, 100e6);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IHyperCoreVault.WithdrawExceedsIdleBalance.selector, shares + 1, shares)
        );
        vault.requestWithdraw(shares + 1);

        vm.prank(alice);
        vault.requestWithdraw(0); // silent no-op
        assertEq(vault.pendingWithdrawalShares(alice), 0, "zero request escrows nothing");
        assertEq(vault.balanceOf(alice), shares, "balance untouched by a zero request");
        console2.log("Q2 PASS - over-balance reverts (req,bal); zero request is a no-op");
    }

    // ── Q3 — cancel restores exactly the escrowed shares AND preserves cost basis ─
    function test_Q3_cancelRestoresSharesAndPreservesCostBasis() public {
        _skipIfNoFork();
        vault = _deployVault(0, 1500); // 15% perf fee makes cost basis observable

        uint256 aShares = _deposit(alice, 100e6);
        _deposit(carol, 100e6);
        _fundIdle(100e6); // NAV 300 over 200 deposited -> PPS 1.5; alice & carol each +50 gain

        // Alice queues then cancels; carol (the control twin) never queues.
        vm.prank(alice);
        vault.requestWithdraw(aShares);
        vm.prank(alice);
        vault.cancelWithdrawRequest();
        assertEq(vault.balanceOf(alice), aShares, "cancel restored exactly the escrowed shares");
        assertEq(vault.pendingWithdrawalShares(alice), 0, "no pending after cancel");

        // Both redeem fully; the perf fee each pays must match -> cost basis survived the round-trip.
        // NB: read balances into vars BEFORE pranking — a nested vault.balanceOf(...) in
        // the redeem args would otherwise consume the prank and run redeem as the test contract.
        uint256 aliceBal = vault.balanceOf(alice);
        uint256 f0 = IERC20(USDC).balanceOf(feeRecipient);
        vm.prank(alice);
        vault.redeem(aliceBal, alice, alice);
        uint256 aliceFee = IERC20(USDC).balanceOf(feeRecipient) - f0;

        uint256 carolBal = vault.balanceOf(carol);
        f0 = IERC20(USDC).balanceOf(feeRecipient);
        vm.prank(carol);
        vault.redeem(carolBal, carol, carol);
        uint256 carolFee = IERC20(USDC).balanceOf(feeRecipient) - f0;

        assertGt(aliceFee, 0, "perf fee actually charged on the gain");
        assertApproxEqAbs(aliceFee, carolFee, 0.05e6, "cancel preserved cost basis (fee == control twin)");
        console2.log("Q3 PASS - cancel restores shares and preserves cost basis (matches control twin)");
    }

    // ── Q4 — partial fulfill math (idle < claim) → proven on the live spike ────
    function test_Q4_partialFulfillMath_provenInLiveSpike() public {
        _skipIfNoFork();
        console2.log("Q4: partial fulfill (idle < claim) needs NAV > idle (capital on Core), which a");
        console2.log("    plain fork cannot represent without mocking the precompile. Live-spike proof.");
        vm.skip(true);
    }

    // ── Q5 — perf fee at fulfill uses the request-time cost-basis SNAPSHOT ─────
    function test_Q5_perfFeeAtFulfillUsesRequestSnapshot() public {
        _skipIfNoFork();
        vault = _deployVault(0, 1500); // 15% perf

        // Alice enters at PPS 1.0, then a gain lifts PPS to 2.0 (alice's basis stays 1.0).
        uint256 aShares = _deposit(alice, 100e6);
        _fundIdle(100e6); // sole LP: NAV 200, PPS 2.0, alice unrealised gain 100e6

        // Request snapshots costBasisAtRequest == alice's basis (1.0).
        vm.prank(alice);
        vault.requestWithdraw(aShares);

        // Perturb alice's LIVE cost basis upward: carol enters at PPS 2.0 (basis 2.0)
        // and transfers her shares to alice -> alice's free-share basis becomes 2.0,
        // while the request's snapshot stays 1.0.
        _deposit(carol, 100e6);
        uint256 cShares = vault.balanceOf(carol);
        vm.prank(carol);
        vault.transfer(alice, cShares);

        // Fulfill the escrowed request. If it (wrongly) used alice's LIVE basis (2.0 == PPS),
        // the fee would be ZERO. A positive fee proves the request-time snapshot (1.0) governs.
        uint256 f0 = IERC20(USDC).balanceOf(feeRecipient);
        vm.prank(keeper);
        vault.fulfillWithdraw(alice);
        uint256 fee = IERC20(USDC).balanceOf(feeRecipient) - f0;

        assertGt(fee, 1e6, "fee positive -> snapshot basis (1.0) used, not live basis (2.0 -> 0)");
        console2.log("Q5 PASS - perf fee at fulfill uses the request-time cost-basis snapshot");
    }

    // ── Q6 — a stuck request fully clears and pays once idle is refunded ───────
    function test_Q6_fulfillPaysOutAfterIdleRefunded() public {
        _skipIfNoFork();
        uint256 shares = _deposit(alice, 100e6);
        vm.prank(alice);
        vault.requestWithdraw(shares);

        // Drain idle out of the vault: fulfill is a no-op (Finding E).
        _drainIdle(100e6);
        vm.prank(keeper);
        vault.fulfillWithdraw(alice);
        assertEq(vault.pendingWithdrawalShares(alice), shares, "still stuck while value is off-idle");

        // Refund idle (deal == fork stand-in for a completed operator pullFromCore; the
        // contract reads only idleUsdc() and cannot tell how idle was funded). The partial
        // remainder split is a live-spike proof; this is the full-refund path.
        deal(USDC, address(vault), 100e6);
        uint256 expected = vault.previewRedeem(vault.pendingWithdrawalShares(alice));
        uint256 before = IERC20(USDC).balanceOf(alice);

        vm.prank(keeper);
        vault.fulfillWithdraw(alice);

        assertEq(vault.pendingWithdrawalShares(alice), 0, "request cleared after refund");
        assertEq(vault.balanceOf(address(vault)), 0, "escrow fully burned");
        assertEq(IERC20(USDC).balanceOf(alice) - before, expected, "paid exactly previewRedeem(pending)");
        console2.log("Q6 PASS - a stuck request fully clears and pays once idle is refunded");
    }

    // ── Q7 — fulfill on an LP with no request is a clean no-op ─────────────────
    function test_Q7_fulfillNoRequestIsCleanNoOp() public {
        _skipIfNoFork();
        _deposit(alice, 100e6); // give the vault some idle so "no-op" is non-trivial
        uint256 idleBefore = _idle();

        vm.prank(keeper);
        vault.fulfillWithdraw(bob); // bob never requested -> early return

        assertEq(_idle(), idleBefore, "no idle moved");
        assertEq(vault.pendingWithdrawalShares(bob), 0, "no request created");
        console2.log("Q7 PASS - fulfillWithdraw on an LP with no request is a clean no-op");
    }
}
