// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {HyperVaultBaseForkTest} from "./HyperVaultBase.fork.t.sol";
import {IHyperCoreVault} from "../../src/interfaces/IHyperCoreVault.sol";
import {Constants} from "../../src/libraries/Constants.sol";

/// @title  M5 escape-hatch — escapeGraceSeconds governance + the PERMISSIONLESS
///         staleness trigger (SOLU-3371), on forked HyperEVM mainnet (real bytecode).
/// @notice Proves what SOLU-3371 widened over SOLU-3369's interim admin arm:
///           (1) governance — the 8h default, the [4h, 30d] hard-bound REVERT setter,
///               and the DEFAULT_ADMIN_ROLE gate on the setter;
///           (2) the trigger arms IFF BOTH legs hold — overdue by AT LEAST
///               escapeGraceSeconds BEYOND the SLA deadline AND claim > availableIdle —
///               and is PERMISSIONLESS (an arbitrary caller can arm when the condition
///               holds), with deadline==0 (no SLA window) NOT armable (§8 Q1);
///           (3) it composes with exitEscape (the symmetric overdue-unfillable check).
///
///         FORK FIDELITY (same constraint as the rest of the suite): revm serves no
///         HyperCore precompiles, so totalAssets()==idleUsdc() (Core/perp NAV read as
///         0). The fork-faithful way to manufacture "claim > availableIdle" is therefore
///         {prioritizeOverdue} — which RESERVES a request's claim, dropping
///         availableIdle WITHOUT collapsing NAV (so previewRedeem stays at the full
///         claim). Draining idle (_drainIdle) would also drop NAV here and collapse the
///         claim in lock-step, so it CANNOT produce the strict inequality on a fork (see
///         HyperVaultEscape.fork.t.sol::test_exit_holdsWhileOverdueUnfillableRemains for
///         the same reasoning). No CoreWriter action is exercised by the trigger itself,
///         so these are pure-EVM control-flow + revert-selector + event assertions.
contract HyperVaultEscapeTriggerForkTest is HyperVaultBaseForkTest {
    // Hard bounds (compile-time constants in VaultEscapeLib; mirrored here as literals
    // because they are deliberately NOT exposed as public getters — keeping the vault
    // inside its EIP-170 budget). [4h, 30d].
    uint64 internal constant GRACE_MIN = 4 hours; // 14_400
    uint64 internal constant GRACE_MAX = 30 days; // 2_592_000
    uint64 internal constant GRACE_DEFAULT = 8 hours; // 28_800

    // Event mirrors for vm.expectEmit (matched by signature + data).
    event EscapeActivated(address indexed by, address indexed lp);
    event EscapeGraceSecondsUpdated(uint64 newGrace);

    // ───────────────────────────────────────────────────────────────────────
    // Shared setup: a sole-depositor request that is overdue + reserved so its claim
    // exceeds availableIdle. Caller controls how far past the deadline we warp, so the
    // grace boundary can be probed from BOTH sides.
    //   - sets a short SLA window;
    //   - alice deposits `assets` (sole depositor: her claim == idle == NAV on a fork);
    //   - alice requests; warp to `deadline + extra`;
    //   - prioritizeOverdue reserves her claim -> availableIdle == 0 < claim.
    // Returns alice's escrowed shares.
    // ───────────────────────────────────────────────────────────────────────
    function _overdueReservedRequest(uint64 window, uint256 assets, uint256 extraPastDeadline)
        internal
        returns (uint256 shares)
    {
        vault.setRequestFulfillmentWindow(window);
        shares = _deposit(alice, assets);
        vm.prank(alice);
        vault.requestWithdraw(shares);
        // deadline = now + window; warp to deadline + extraPastDeadline.
        vm.warp(block.timestamp + window + extraPastDeadline);
        vm.prank(keeper);
        vault.prioritizeOverdue(alice); // reserve -> availableIdle drops to 0
        assertEq(vault.availableIdleUsdc(), 0, "reserve zeroed availableIdle (claim now > available)");
        assertGt(vault.previewRedeem(shares), vault.availableIdleUsdc(), "claim > availableIdle");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // (1) GOVERNANCE — default, bounds (REVERT, not clamp), and the admin gate.
    // ═════════════════════════════════════════════════════════════════════════

    function test_grace_defaultIs8Hours() public {
        _skipIfNoFork();
        assertEq(vault.escapeGraceSeconds(), GRACE_DEFAULT, "default escapeGraceSeconds == 8h (28800s)");
        assertEq(GRACE_DEFAULT, 28_800, "8h == 28800s");
        console2.log("SOLU-3371 PASS - escapeGraceSeconds defaults to 8h (28800s) at deploy");
    }

    function test_grace_setWithinBoundsWorksAndEmits() public {
        _skipIfNoFork();

        // At the floor.
        vm.expectEmit(false, false, false, true, address(vault));
        emit EscapeGraceSecondsUpdated(GRACE_MIN);
        vault.setEscapeGraceSeconds(GRACE_MIN);
        assertEq(vault.escapeGraceSeconds(), GRACE_MIN, "set to the floor (4h)");

        // A mid value.
        uint64 mid = 3 days;
        vm.expectEmit(false, false, false, true, address(vault));
        emit EscapeGraceSecondsUpdated(mid);
        vault.setEscapeGraceSeconds(mid);
        assertEq(vault.escapeGraceSeconds(), mid, "set to 3 days");

        // At the ceiling.
        vm.expectEmit(false, false, false, true, address(vault));
        emit EscapeGraceSecondsUpdated(GRACE_MAX);
        vault.setEscapeGraceSeconds(GRACE_MAX);
        assertEq(vault.escapeGraceSeconds(), GRACE_MAX, "set to the ceiling (30d)");

        console2.log("SOLU-3371 PASS - setEscapeGraceSeconds within [4h,30d] updates + emits");
    }

    function test_grace_belowFloorReverts() public {
        _skipIfNoFork();
        // One second under the floor.
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.EscapeGraceOutOfRange.selector, GRACE_MIN, GRACE_MAX));
        vault.setEscapeGraceSeconds(GRACE_MIN - 1);
        // And zero (the "disable the brake" attempt).
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.EscapeGraceOutOfRange.selector, GRACE_MIN, GRACE_MAX));
        vault.setEscapeGraceSeconds(0);
        assertEq(vault.escapeGraceSeconds(), GRACE_DEFAULT, "unchanged after reverts");
        console2.log("SOLU-3371 PASS - setEscapeGraceSeconds below 4h (and 0) reverts EscapeGraceOutOfRange");
    }

    function test_grace_aboveCeilingReverts() public {
        _skipIfNoFork();
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.EscapeGraceOutOfRange.selector, GRACE_MIN, GRACE_MAX));
        vault.setEscapeGraceSeconds(GRACE_MAX + 1);
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.EscapeGraceOutOfRange.selector, GRACE_MIN, GRACE_MAX));
        vault.setEscapeGraceSeconds(type(uint64).max);
        assertEq(vault.escapeGraceSeconds(), GRACE_DEFAULT, "unchanged after reverts");
        console2.log("SOLU-3371 PASS - setEscapeGraceSeconds above 30d reverts EscapeGraceOutOfRange");
    }

    function test_grace_setterIsAdminGated() public {
        _skipIfNoFork();
        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
        // A non-admin cannot retune the brake's grace.
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, adminRole)
        );
        vault.setEscapeGraceSeconds(GRACE_MIN);
        assertEq(vault.escapeGraceSeconds(), GRACE_DEFAULT, "non-admin cannot change the grace");
        console2.log("SOLU-3371 PASS - setEscapeGraceSeconds is DEFAULT_ADMIN_ROLE-gated");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // (2) TRIGGER — arms IFF BOTH legs hold; permissionless; deadline==0 not armable.
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev The GRACE boundary: with claim > availableIdle already true, the trigger
    ///      arms ONLY once `now > deadline + escapeGraceSeconds`. Past the deadline but
    ///      BEFORE deadline+grace -> revert; past deadline+grace -> success + event.
    function test_trigger_armsOnlyAfterDeadlinePlusGrace() public {
        _skipIfNoFork();
        uint64 window = 1 hours;
        uint64 grace = vault.escapeGraceSeconds(); // 8h default

        // Overdue (past deadline) and reserved (claim > availableIdle) — but only `1`
        // second past the deadline, i.e. WELL before deadline + grace.
        uint256 shares = _overdueReservedRequest(window, 100e6, 1);
        assertTrue(vault.requestIsOverdue(alice), "overdue past the SLA deadline");

        // Leg (a) not yet satisfied: grace has NOT elapsed -> trigger REVERTS.
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.EscapeConditionNotMet.selector, alice));
        vault.triggerEscape(alice);
        assertFalse(vault.escapeActive(), "not armed before deadline + grace");

        // Cross the grace boundary (we were at deadline+1; advance the rest of grace).
        vm.warp(block.timestamp + grace);
        assertGt(vault.previewRedeem(shares), vault.availableIdleUsdc(), "still unfillable (reserve intact)");

        // Now BOTH legs hold -> arms + emits EscapeActivated(caller, alice).
        vm.expectEmit(true, true, false, true, address(vault));
        emit EscapeActivated(address(this), alice);
        vault.triggerEscape(alice);
        assertTrue(vault.escapeActive(), "armed once past deadline + grace");

        console2.log("SOLU-3371 PASS - trigger arms ONLY after deadline + escapeGraceSeconds (grace stacks on SLA)");
    }

    /// @dev Leg (b): a FILLABLE request (claim <= availableIdle) cannot arm the brake,
    ///      even when fully overdue + grace-elapsed. Alice is the sole depositor and we
    ///      do NOT reserve, so idle fully backs her claim (and we _fundIdle extra to make
    ///      availableIdle strictly exceed it) -> honorable -> trigger reverts.
    function test_trigger_revertsWhenClaimFillableEvenIfOverdue() public {
        _skipIfNoFork();
        uint64 window = 1 hours;
        uint64 grace = vault.escapeGraceSeconds();

        vault.setRequestFulfillmentWindow(window);
        uint256 shares = _deposit(alice, 100e6);
        vm.prank(alice);
        vault.requestWithdraw(shares);
        // Fully overdue AND grace-elapsed.
        vm.warp(block.timestamp + window + grace + 1);
        assertTrue(vault.requestIsOverdue(alice), "overdue");

        // Fund extra idle so availableIdle strictly exceeds her claim (unambiguously
        // fillable). No reserve -> availableIdle == idle.
        _fundIdle(50e6);
        assertGt(vault.availableIdleUsdc(), vault.previewRedeem(shares), "claim <= availableIdle (fillable)");

        // Leg (b) fails -> trigger reverts, brake stays off.
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.EscapeConditionNotMet.selector, alice));
        vault.triggerEscape(alice);
        assertFalse(vault.escapeActive(), "a fillable request can never arm the brake");

        console2.log("SOLU-3371 PASS - trigger reverts when claim <= availableIdle (fillable), even if overdue+grace");
    }

    /// @dev PERMISSIONLESS: an arbitrary, unprivileged address arms the brake when the
    ///      condition holds — proving the SOLU-3369 onlyRole(DEFAULT_ADMIN_ROLE) gate
    ///      was removed. The `by` in EscapeActivated is the arbitrary caller.
    function test_trigger_isPermissionless() public {
        _skipIfNoFork();
        // attacker is just a random EOA holding no role.
        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
        assertFalse(vault.hasRole(adminRole, attacker), "caller holds no admin role");

        _overdueReservedRequest(1 hours, 100e6, vault.escapeGraceSeconds() + 1); // condition fully met

        vm.expectEmit(true, true, false, true, address(vault));
        emit EscapeActivated(attacker, alice); // armed BY the arbitrary caller
        vm.prank(attacker);
        vault.triggerEscape(alice);
        assertTrue(vault.escapeActive(), "armed by an arbitrary unprivileged caller");

        console2.log("SOLU-3371 PASS - triggerEscape is permissionless (arbitrary caller arms when condition holds)");
    }

    /// @dev DEADLINE == 0 (no SLA window) is NOT armable (§8 Q1, the documented choice):
    ///      with requestFulfillmentWindow unset, the request carries fulfillmentDeadline
    ///      == 0 and can never be overdue, so the brake can never arm — even if idle is
    ///      drained to zero. A vault with no SLA window has NO permissionless brake.
    function test_trigger_deadlineZeroNotArmable() public {
        _skipIfNoFork();
        // Opt into no-SLA (window == 0 disables deadlines) — the documented escape-brake
        // opt-out. M-3 now DEFAULTS the window non-zero, so no-SLA is an explicit choice.
        vault.setRequestFulfillmentWindow(0);
        assertEq(vault.requestFulfillmentWindow(), 0, "no SLA window configured (explicit opt-out)");
        uint256 shares = _deposit(alice, 100e6);
        vm.prank(alice);
        vault.requestWithdraw(shares);
        assertEq(vault.pendingWithdrawalDeadline(alice), 0, "no deadline stamped (window == 0)");
        assertFalse(vault.requestIsOverdue(alice), "a deadline-less request is never overdue");

        // Even far in the future, and even after draining ALL idle (claim would be
        // unfillable IF it could be overdue), the deadline==0 request cannot arm.
        vm.warp(block.timestamp + 365 days);
        _drainIdle(_idle());

        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.EscapeConditionNotMet.selector, alice));
        vault.triggerEscape(alice);
        assertFalse(vault.escapeActive(), "deadline==0 => not armable (no SLA window => no brake)");

        console2.log("SOLU-3371 PASS - deadline==0 (no SLA window) is NOT armable (admin must set a window)");
    }

    /// @dev An LP with NO request at all cannot arm (shares == 0 fails leg (a)).
    function test_trigger_noRequestNotArmable() public {
        _skipIfNoFork();
        vault.setRequestFulfillmentWindow(1 hours);
        assertEq(vault.pendingWithdrawalShares(bob), 0, "bob has no request");
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.EscapeConditionNotMet.selector, bob));
        vault.triggerEscape(bob);
        assertFalse(vault.escapeActive(), "no request => not armable");
        console2.log("SOLU-3371 PASS - an LP with no request cannot arm the brake");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // (3) COMPOSES WITH exitEscape — the symmetric overdue-unfillable condition.
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev After the permissionless arm, exitEscape([alice]) REVERTS EscapeBacklogRemains
    ///      while alice stays overdue-unfillable (the arming condition still holds), then
    ///      CLEARS once idle is funded enough to make her claim honorable — proving the
    ///      trigger and the exit gate use the EXACT SAME overdue-unfillable predicate.
    function test_trigger_composesWithExitEscape() public {
        _skipIfNoFork();
        vm.etch(Constants.CORE_WRITER, type(MockCoreWriter).runtimeCode);

        _overdueReservedRequest(1 hours, 100e6, vault.escapeGraceSeconds() + 1);
        vault.triggerEscape(alice);
        assertTrue(vault.escapeActive(), "armed on alice's overdue-unfillable request");

        // Still overdue-unfillable (reserve intact) -> exit HOLDS the latch.
        address[] memory lps = new address[](1);
        lps[0] = alice;
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.EscapeBacklogRemains.selector, alice));
        vault.exitEscape(lps);
        assertTrue(vault.escapeActive(), "latch held while alice remains overdue-unfillable");

        // Resolve the backlog: fulfill alice from her reserve so NO overdue request
        // remains. (On a fork alice is the sole holder, so her claim tracks NAV 1:1 —
        // a bare idle top-up can't outpace the claim; fulfilling clears it outright,
        // which is exactly what "the claim is now honorable" means for the exit gate.)
        vm.prank(keeper);
        vault.fulfillWithdraw(alice);
        assertEq(vault.pendingWithdrawalShares(alice), 0, "alice's request resolved (no backlog)");

        // The symmetric condition no longer holds -> exit CLEARS.
        vault.exitEscape(lps);
        assertFalse(vault.escapeActive(), "cleared once no overdue-unfillable request remains");

        console2.log("SOLU-3371 PASS - trigger composes with exitEscape (same overdue-unfillable predicate)");
    }
}

/// @dev Minimal CoreWriter stub (mirrors the one in HyperVaultEscape.fork.t.sol) so the
///      exitEscape compose-test can deploy with the latch machinery reachable. The
///      trigger itself dispatches no CoreWriter action; this is only etched for parity.
contract MockCoreWriter {
    event RawAction(bytes data);

    function sendRawAction(bytes calldata data) external {
        emit RawAction(data);
    }
}
