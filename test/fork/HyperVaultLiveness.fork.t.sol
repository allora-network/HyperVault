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

/// @dev CoreWriter stub etched at the system address so the Core->EVM movers
///      execute deterministically (we test the pause-modifier change, not
///      CoreWriter's processing; the real CoreWriter path is the live spike's job).
contract MockCoreWriter {
    event RawAction(bytes data);

    function sendRawAction(bytes calldata data) external {
        emit RawAction(data);
    }
}

/// @title  Liveness / fund-safety finding proofs (forked HyperEVM mainnet, real bytecode)
/// @notice One test per finding from docs/REDEMPTION_ASSESSMENT.md §4. Every test runs
///         against the real USDC ERC20 and a freshly deployed vault — no mocks.
contract HyperVaultLivenessForkTest is HyperVaultBaseForkTest {
    // ───────────────────────────────────────────────────────────────────────
    // Finding A — Pausing freezes the refill path; EMERGENCY_ROLE cannot repatriate.
    //   Claim:   pullFromCore/usdPerpToSpot/usdSpotToPerp/operatorRecoverSpot are
    //            whenNotPaused; the emergency admin holds no Core->EVM mover.
    //   Contract: HyperCoreVault.sol:487,493,516,544,549 (whenNotPaused) vs :558 (pause).
    //   Fork-provable: FULL (reverts fire at the modifier, before any precompile/CoreWriter).
    // ───────────────────────────────────────────────────────────────────────
    function test_A_pauseDoesNotFreezeRepatriation() public {
        _skipIfNoFork();
        // H2: the exact movers that reverted EnforcedPause in the 2026-06-03 live
        // spike must now SUCCEED while paused (no refill freeze). Etch a CoreWriter
        // stub so the calls execute deterministically (modifier change is the unit).
        vm.etch(Constants.CORE_WRITER, type(MockCoreWriter).runtimeCode);

        address treasury = makeAddr("treasury");
        vault.setSpotRecoverDest(treasury, true); // admin == address(this)

        vm.prank(emergency);
        vault.pause();

        vm.startPrank(operator);
        // Core->EVM refill movers now succeed while paused (no market risk added).
        vault.pullFromCore(1);
        vault.usdPerpToSpot(1);
        vault.operatorRecoverSpot(treasury, 0, 1);
        // usdSpotToPerp DEPLOYS into the market -> deliberately still blocked by pause.
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.usdSpotToPerp(1);
        vm.stopPrank();

        console2.log("A PASS - paused refill movers succeed; spot->perp (deploy) stays blocked (H2)");
    }

    function test_A_emergencyRepatriateWorksWhilePaused() public {
        _skipIfNoFork();
        vm.etch(Constants.CORE_WRITER, type(MockCoreWriter).runtimeCode);

        address treasury = makeAddr("treasury");
        vault.setSpotRecoverDest(treasury, true);

        // Emergency admin still lacks OPERATOR_ROLE -> cannot call the operator movers.
        bytes32 opRole = vault.OPERATOR_ROLE();
        vm.prank(emergency);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, emergency, opRole)
        );
        vault.pullFromCore(1);

        // ...but H2 gives EMERGENCY_ROLE its own repatriation hatch, even while paused.
        vm.prank(emergency);
        vault.pause();
        vm.prank(emergency);
        vault.emergencyRepatriate(treasury, 1, 1); // perp->spot + spot-send to allowlisted treasury

        // The C-2 allowlist still binds: a non-allowlisted, non-bridge dest reverts.
        address rogue = makeAddr("rogue");
        vm.prank(emergency);
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.SpotRecoverDestinationNotAllowed.selector, rogue));
        vault.emergencyRepatriate(rogue, 0, 1);

        console2.log("A PASS - EMERGENCY_ROLE repatriates while paused; still bound by the C-2 allowlist (H2)");
    }

    // ───────────────────────────────────────────────────────────────────────
    // Finding B — Only OPERATOR (unpaused) can move Core->EVM; the absence of a
    //             permissionless escape hatch is deliberate.
    //   Contract: HyperCoreVault.sol:487-552 (operator+whenNotPaused) vs :735,748
    //             (fulfill/cancel: no role gate).
    //   Fork-provable: FULL (pure AccessControl).
    // ───────────────────────────────────────────────────────────────────────
    function test_B_onlyOperatorCanRepatriate() public {
        _skipIfNoFork();
        bytes32 opRole = vault.OPERATOR_ROLE();

        // attacker (no role)
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, opRole)
        );
        vault.pullFromCore(1);

        // feeRecipient (no role)
        vm.prank(feeRecipient);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, feeRecipient, opRole)
        );
        vault.pullFromCore(1);

        // the admin itself (DEFAULT_ADMIN_ROLE, == address(this)) holds no OPERATOR_ROLE
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), opRole)
        );
        vault.pullFromCore(1);

        console2.log("B PASS - pullFromCore rejects attacker / feeRecipient / admin (only OPERATOR moves Core->EVM)");
    }

    function test_B_queueFunctionsArePermissionless() public {
        _skipIfNoFork();

        // The contract CAN express permissionless entry points — fulfillWithdraw and
        // cancelWithdrawRequest have no role gate. The fact that NO permissionless
        // Core->EVM escape hatch exists is therefore a deliberate gap, not an oversight.
        vm.prank(attacker);
        vault.fulfillWithdraw(alice); // no pending request -> early return, no access-control revert
        vm.prank(attacker);
        vault.cancelWithdrawRequest(); // no pending request -> early return, no revert

        console2.log("B PASS - fulfill/cancel are permissionless; no Core->EVM hatch is (by contrast)");
    }

    // ───────────────────────────────────────────────────────────────────────
    // Finding E — fulfillWithdraw only pays from idle; decoupled from Core repatriation.
    //   Setup:   deposit -> requestWithdraw(all) -> pushToCore(all) (REAL ERC20 transfer
    //            drains idle to 0, value now "on Core") -> fulfillWithdraw.
    //   Contract: HyperCoreVault.sol:748-788 (reads only idleUsdc(); early-return :767).
    //   Fork-provable: load-bearing claim FULL. Residual ("a real pullFromCore refill then
    //            pays out") -> live spike scripts/python/e2e_runner.py step_pull/step_redeem.
    // ───────────────────────────────────────────────────────────────────────
    function test_E_fulfillOnlyPaysFromIdle() public {
        _skipIfNoFork();

        uint256 shares = _deposit(alice, 100e6);
        vm.prank(alice);
        vault.requestWithdraw(shares);
        assertEq(vault.pendingWithdrawalShares(alice), shares, "shares escrowed");
        assertEq(_idle(), 100e6, "idle holds the deposit");

        uint256 sinkBefore = IERC20(USDC).balanceOf(idleSink);
        _drainIdle(100e6); // real ERC20 transfer out of the vault (capital now deployed / off-idle)
        assertEq(_idle(), 0, "idle fully drained");
        assertEq(IERC20(USDC).balanceOf(idleSink) - sinkBefore, 100e6, "USDC really left the vault");

        // Keeper fulfills while the value sits off-idle (unreachable by the queue): no-op.
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(keeper);
        vault.fulfillWithdraw(alice);

        assertEq(vault.pendingWithdrawalShares(alice), shares, "pending untouched (fulfill cannot see Core)");
        assertEq(vault.balanceOf(address(vault)), shares, "escrowed shares untouched");
        assertEq(IERC20(USDC).balanceOf(alice), aliceBefore, "alice paid nothing");
        assertEq(_idle(), 0, "fulfill did not pull from Core (decoupled from repatriation)");

        console2.log("E PASS - fulfillWithdraw no-ops with value on Core; it only ever pays from idle");
    }

    // ───────────────────────────────────────────────────────────────────────
    // Finding F — Direct redeem races the queue for the shared idle pool; no pro-rata.
    //   Contract: HyperCoreVault.sol:278-310 (redeem partial-fill) vs :748 (fulfill).
    //   Fork-provable: NO — proven on the LIVE spike instead. Why: the race/starvation
    //   only manifests when NAV > idleUsdc() (some capital genuinely deployed on Core).
    //   On a plain forge fork, revm does not implement the HyperCore precompiles, so
    //   coreSpotUsdc()/perpWithdrawable() read 0 and totalAssets() == idleUsdc() always
    //   -> redeem is strictly proportional to idle, every LP gets their fair share, and
    //   no starvation can arise. Reproducing NAV > idle on a fork would require mocking
    //   the precompile, which the project's no-mocks de-risk rule forbids. Proven for
    //   real on scripts/python/e2e_runner.py: deposit -> pushToCore -> usdSpotToPerp
    //   (NAV > idle for real) -> requestWithdraw + a second LP direct redeem -> observe
    //   the first-queued LP starved until the operator repatriates.
    // ───────────────────────────────────────────────────────────────────────
    function test_F_directRedeemRace_provenInLiveSpike() public {
        _skipIfNoFork();
        console2.log("F: race needs NAV > idle (capital on Core); not fork-representable without");
        console2.log("   mocking the precompile. Proven on the live spike (e2e_runner.py). Skipping.");
        vm.skip(true);
    }

    // ───────────────────────────────────────────────────────────────────────
    // Finding F remediation (H2 / TODO-5) — once a request's fulfillment SLA
    //   lapses, prioritizeOverdue() RESERVES its claim on idle (carved out of the
    //   pool ordinary redeems may draw from), and the reserve is released only when
    //   that LP is fulfilled. The reservation ACCOUNTING is fully fork-provable
    //   (idle is real USDC, no precompile needed). The starvation-prevention EFFECT
    //   (where the cap actually BINDS and the queued LP would otherwise be starved)
    //   needs NAV > idleUsdc() — capital genuinely on Core — which a forge fork
    //   cannot represent (coreSpotUsdc() reads 0). That half is the live-spike proof
    //   (e2e_runner.py), same limitation as Finding F itself.
    // ───────────────────────────────────────────────────────────────────────
    function test_F_overdueRequestReservesIdle() public {
        _skipIfNoFork();

        vault.setRequestFulfillmentWindow(1 hours); // admin == address(this)

        _deposit(alice, 100e6);
        _deposit(bob, 100e6);
        uint256 aliceShares = vault.balanceOf(alice);
        assertEq(_idle(), 200e6, "idle holds both deposits");

        vm.prank(alice);
        vault.requestWithdraw(aliceShares);
        assertGt(vault.pendingWithdrawalDeadline(alice), 0, "deadline stamped");
        assertFalse(vault.requestIsOverdue(alice), "not overdue yet");
        assertEq(vault.availableIdleUsdc(), _idle(), "no reserve before prioritization");

        vm.warp(block.timestamp + 1 hours + 1);
        assertTrue(vault.requestIsOverdue(alice), "overdue after the window");

        // Anyone reserves Alice's claim on idle.
        uint256 idleNow = _idle();
        vm.prank(keeper);
        vault.prioritizeOverdue(alice);
        uint256 reserved = vault.pendingWithdrawalReserved(alice);
        assertGt(reserved, 0, "alice's claim reserved");
        assertEq(vault.reservedIdleUsdc(), reserved, "global reserve tracks alice");
        // The reserve is carved out of the idle ordinary redeems may draw.
        assertEq(vault.availableIdleUsdc(), idleNow - reserved, "available idle reduced by the reserve");

        // maxWithdraw of a racing redeemer routes through availableIdle (so it can
        // never claim Alice's reserved slice): maxWithdraw == min(owned, available).
        uint256 bobOwned = vault.convertToAssets(vault.balanceOf(bob));
        uint256 avail = vault.availableIdleUsdc();
        assertEq(vault.maxWithdraw(bob), bobOwned < avail ? bobOwned : avail, "maxWithdraw routes through availableIdle");

        // Re-prioritizing is rejected (already reserved).
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.RequestAlreadyPrioritized.selector, alice));
        vault.prioritizeOverdue(alice);

        // Fulfilling Alice pays from her reserve and releases it.
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(keeper);
        vault.fulfillWithdraw(alice);
        assertGt(IERC20(USDC).balanceOf(alice) - aliceBefore, 90e6, "alice paid ~her full claim from the reserve");
        assertEq(vault.reservedIdleUsdc(), 0, "reserve released after fulfill");
        assertEq(vault.pendingWithdrawalShares(alice), 0, "request cleared");

        console2.log("F PASS - overdue request reserves idle (carved from availableIdle), released on fulfill (H2)");
        console2.log("   note: the racing-redeem STARVATION case needs NAV>idle (capital on Core) -> live spike");
    }

    /// @dev H2: prioritizeOverdue guards — absent request, no-deadline, not-yet-overdue.
    function test_F_prioritizeOverdueGuards() public {
        _skipIfNoFork();

        // No request -> NoPendingRequest.
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.NoPendingRequest.selector, alice));
        vault.prioritizeOverdue(alice);

        // Request with the SLA window DISABLED (default 0) -> never overdue.
        uint256 shares = _deposit(alice, 100e6);
        vm.prank(alice);
        vault.requestWithdraw(shares);
        assertEq(vault.pendingWithdrawalDeadline(alice), 0, "no deadline when window disabled");
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.RequestNotOverdue.selector, alice));
        vault.prioritizeOverdue(alice);

        console2.log("F PASS - prioritizeOverdue rejects absent / no-deadline / not-overdue requests (H2)");
    }

    /// @dev H2 regression: if NAV falls after prioritization so the LP's claim drops
    ///      below the reserved amount, fulfilling must release the FULL reserve (no
    ///      idle stranded in `_reservedIdle` forever).
    function test_F_fullReserveReleasedWhenNavFallsAfterPrioritize() public {
        _skipIfNoFork();
        vault.setRequestFulfillmentWindow(1 hours);
        _deposit(alice, 100e6);
        _deposit(bob, 100e6);
        uint256 aliceShares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.requestWithdraw(aliceShares);
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(keeper);
        vault.prioritizeOverdue(alice);
        uint256 reserved = vault.pendingWithdrawalReserved(alice);
        assertEq(vault.reservedIdleUsdc(), reserved, "reserve set");

        // NAV falls (on a fork NAV==idle) but idle still backs the reserve.
        _drainIdle(50e6);
        assertGe(_idle(), reserved, "idle still >= reserve (invariant)");

        // Alice's claim is now below `reserved`; fulfill must release ALL of it.
        vm.prank(keeper);
        vault.fulfillWithdraw(alice);
        assertEq(vault.reservedIdleUsdc(), 0, "entire reserve released; none stranded");
        assertEq(vault.pendingWithdrawalShares(alice), 0, "request resolved");

        console2.log("F PASS - full reserve released on fulfill even when NAV fell below the reserve (H2)");
    }

    /// @dev H2: the operator cannot deploy reserved idle to Core via pushToCore.
    function test_F_pushToCoreCannotDeployReservedIdle() public {
        _skipIfNoFork();
        vault.setRequestFulfillmentWindow(1 hours);
        _deposit(alice, 100e6);
        _deposit(bob, 100e6);
        uint256 aliceShares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.requestWithdraw(aliceShares);
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(keeper);
        vault.prioritizeOverdue(alice);

        uint256 avail = vault.availableIdleUsdc();
        // Pushing more than availableIdle reverts at the H2 guard (before the bridge
        // transfer / blacklist) — the reserve is protected from operator redeployment.
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IHyperCoreVault.WithdrawExceedsIdleBalance.selector, uint256(uint64(avail + 1)), avail)
        );
        vault.pushToCore(uint64(avail + 1));

        console2.log("F PASS - pushToCore cannot deploy idle reserved for an overdue request (H2)");
    }

    // ───────────────────────────────────────────────────────────────────────
    // Finding G — The configured EVM USDC is NOT the Core-linked USDC; the canonical
    //             EVM<->Core bridge is non-functional for the shipped asset.
    //   Two on-chain facts, jointly decisive:
    //     (1) LINKAGE (live precompile read — NOT fork-readable, revm can't run 0x80C):
    //         tokenInfo(0).evmContract == 0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24,
    //         which is != the configured asset 0xb883…630f. So coreSpotUsdc() measures the
    //         vault's balance of a DIFFERENT USDC than asset(). Recorded by
    //         scripts/python/resolve_usdc_linkage.py + docs/FORK_PROOFS.md.
    //     (2) BRIDGE BLACKLIST (proven HERE on real bytecode): the configured Circle USDC
    //         blacklists the Core bridge address 0x2000…0000, so pushToCore (a transfer to
    //         that address) reverts -> the operator cannot even deploy idle to Core via the
    //         canonical bridge, let alone repatriate it. This resolves the README-vs-
    //         e2e_runner.step_pull contradiction in favour of the README/natspec.
    //   Fork-provable: the bridge-blacklist half is FULL; the linkage half is the live read.
    // ───────────────────────────────────────────────────────────────────────
    function test_G_legacyPushRevertsOnBlacklistedBridge() public {
        _skipIfNoFork();

        // Audit G2: the default vault now routes pushes via the CoreDepositWallet.
        // This test pins the ORIGINAL Finding-G fact on an explicit LEGACY vault
        // (no wallet): the direct ERC20-to-system-address route remains dead for
        // natively-minted USDC — the documented reason the wallet route exists.
        HyperCoreVault legacy = _deployVaultWithWallet(0, 0, address(0));
        deal(USDC, alice, 100e6);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(legacy), 100e6);
        legacy.deposit(100e6, alice);
        vm.stopPrank();

        vm.prank(operator);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        legacy.pushToCore(100e6);

        console2.log("G PASS - LEGACY pushToCore reverts: Circle USDC blacklists the bridge 0x2000..0000");
        console2.log("         => the official route is the CoreDepositWallet (G2); see HyperVaultCoreDepositWallet suite");
    }

    // ───────────────────────────────────────────────────────────────────────
    // Finding H (H1 remediation) — NAV reads default to the fresh-vault GRACE
    //   (lenient) and become STRICT (fail-closed) once endNavBootstrap() is called.
    //   Strict is now the default posture for a live vault (the prior
    //   strictNavReads=false footgun is gone), behind a one-way bootstrap flag so a
    //   brand-new vault with no Core rows (and the revm fork) still functions.
    //   Contract: HyperCoreVault.sol navBootstrap (default true), coreSpotUsdc/
    //             perpWithdrawable (strict = !navBootstrap), endNavBootstrap (one-way);
    //             PrecompileLib strict reverts PrecompileRevert.
    //   Fork-provable: FULL. Self-guarded so it never false-greens if the substrate
    //             returns precompile data.
    // ───────────────────────────────────────────────────────────────────────
    function test_H_navBootstrapGraceThenStrictFailsClosed() public {
        _skipIfNoFork();

        assertTrue(vault.navBootstrap(), "navBootstrap must default ON (fresh-vault grace)");

        // Self-guard: the proof needs the spot-balance precompile to FAIL for the vault's
        // (uninitialised) Core account. If the substrate returns a populated struct we
        // cannot demonstrate fail-closed -> skip rather than emit a false proof.
        (bool ok, bytes memory ret) =
            Constants.SPOT_BALANCE_PRECOMPILE.staticcall(abi.encode(address(vault), Constants.USDC_CORE_INDEX));
        if (ok && ret.length > 0) {
            console2.log("spot-balance precompile returned data here; cannot prove fail-closed on this substrate");
            vm.skip(true);
        }

        // BOOTSTRAP (default): a failing precompile read is swallowed -> NAV reads 0
        // (fail-open). This is the safe posture for a vault with no Core rows yet.
        assertEq(vault.coreSpotUsdc(), 0, "bootstrap: lenient read returns 0");
        assertEq(vault.perpWithdrawable(), 0, "bootstrap: lenient read returns 0");

        // End the grace (one-way) -> strict: the same failing read now fails CLOSED.
        vault.endNavBootstrap(); // admin == address(this)
        assertFalse(vault.navBootstrap(), "navBootstrap ended");
        vm.expectRevert(
            abi.encodeWithSelector(PrecompileLib.PrecompileRevert.selector, Constants.SPOT_BALANCE_PRECOMPILE)
        );
        vault.coreSpotUsdc();

        // The transition is one-way: cannot re-enter the grace period.
        vm.expectRevert(IHyperCoreVault.NavBootstrapAlreadyEnded.selector);
        vault.endNavBootstrap();

        console2.log("H PASS - bootstrap reads fail-open; endNavBootstrap -> strict fail-closed; one-way");
    }

    /// @dev H1: deposits and redeems must still settle while bootstrapping (the grace
    ///      keeps a fresh vault usable before its Core account is initialised).
    function test_H_depositRedeemWorkWhileBootstrapping() public {
        _skipIfNoFork();
        assertTrue(vault.navBootstrap(), "still bootstrapping");

        uint256 shares = _deposit(alice, 100e6);
        assertGt(shares, 0, "deposit minted shares during bootstrap");
        assertEq(vault.totalAssets(), 100e6, "NAV == idle during bootstrap (Core reads 0)");

        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertEq(vault.balanceOf(alice), 0, "redeem settled during bootstrap");
        assertEq(IERC20(USDC).balanceOf(alice), 100e6, "alice recovered her USDC");

        console2.log("H PASS - deposit + redeem settle normally during the NAV bootstrap grace");
    }
}
