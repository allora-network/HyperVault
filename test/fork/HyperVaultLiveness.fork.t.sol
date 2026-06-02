// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {HyperVaultBaseForkTest} from "./HyperVaultBase.fork.t.sol";
import {PrecompileLib} from "../../src/libraries/PrecompileLib.sol";
import {Constants} from "../../src/libraries/Constants.sol";

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
    function test_A_pauseFreezesRefillPath() public {
        _skipIfNoFork();

        // Allow-list a recover destination BEFORE pausing, to prove pause dominates
        // even the otherwise-permitted operatorRecoverSpot path.
        address treasury = makeAddr("treasury");
        vault.setSpotRecoverDest(treasury, true); // admin == address(this)

        vm.prank(emergency);
        vault.pause();

        vm.startPrank(operator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.pullFromCore(1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.usdPerpToSpot(1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.usdSpotToPerp(1);
        vm.expectRevert(Pausable.EnforcedPause.selector); // pause dominates the allow-listed dest
        vault.operatorRecoverSpot(treasury, 0, 1);
        vm.stopPrank();

        console2.log("A PASS - paused: every operator Core<->EVM mover reverts EnforcedPause");
    }

    function test_A_emergencyRoleCannotRepatriate() public {
        _skipIfNoFork();

        // The emergency admin can pause and close positions, but has NO function that
        // moves USDC from Core back to EVM idle. Prove it: the movers reject it on the
        // missing OPERATOR_ROLE (even while the vault is unpaused).
        bytes32 opRole = vault.OPERATOR_ROLE();
        vm.startPrank(emergency);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, emergency, opRole)
        );
        vault.pullFromCore(1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, emergency, opRole)
        );
        vault.usdPerpToSpot(1);
        vm.stopPrank();

        console2.log("A PASS - EMERGENCY_ROLE has no repatriation path (lacks OPERATOR_ROLE)");
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
    function test_G_pushToCoreRevertsOnBlacklistedBridge() public {
        _skipIfNoFork();

        _deposit(alice, 100e6); // vault holds 100e6 idle to push

        vm.prank(operator);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        vault.pushToCore(100e6);

        console2.log("G PASS - pushToCore reverts: configured USDC blacklists the Core bridge 0x2000..0000");
        console2.log("         => canonical EVM<->Core USDC bridge is non-functional for the shipped asset");
    }

    // ───────────────────────────────────────────────────────────────────────
    // Finding H — Strict NAV reads ship OFF; OFF fails OPEN (silent 0), ON fails CLOSED.
    //   Contract: HyperCoreVault.sol:111 (default false), :351-365, :698 (toggle);
    //             PrecompileLib.sol:108-112,132-138 (strict reverts PrecompileRevert).
    //   Fork-provable: FULL for the vault's wrapper logic. NOTE: on a forge fork the
    //            precompile read fails because revm does not implement HyperCore
    //            precompiles — mechanically identical to a fresh Core account with no
    //            row. Self-guarded so it never false-greens if the substrate returns data.
    // ───────────────────────────────────────────────────────────────────────
    function test_H_strictNavReadsDefaultOffFailsOpen() public {
        _skipIfNoFork();

        assertFalse(vault.strictNavReads(), "strictNavReads must default OFF");

        // Self-guard: the proof needs the spot-balance precompile to FAIL for the vault's
        // (uninitialised) Core account. If the substrate returns a populated struct we
        // cannot demonstrate fail-closed -> skip rather than emit a false proof.
        (bool ok, bytes memory ret) =
            Constants.SPOT_BALANCE_PRECOMPILE.staticcall(abi.encode(address(vault), Constants.USDC_CORE_INDEX));
        if (ok && ret.length > 0) {
            console2.log("spot-balance precompile returned data here; cannot prove fail-closed on this substrate");
            vm.skip(true);
        }

        // OFF (default): a failing precompile read is swallowed -> NAV silently reads 0.
        assertEq(vault.coreSpotUsdc(), 0, "lenient read silently returns 0");
        assertEq(vault.perpWithdrawable(), 0, "lenient read silently returns 0");

        // ON: the same failing read now fails CLOSED (revert) instead of zeroing NAV.
        vault.setStrictNavReads(true); // admin == address(this)
        vm.expectRevert(
            abi.encodeWithSelector(PrecompileLib.PrecompileRevert.selector, Constants.SPOT_BALANCE_PRECOMPILE)
        );
        vault.coreSpotUsdc();

        console2.log("H PASS - default OFF silently zeros a failed NAV read; ON fails closed (revert)");
    }
}
