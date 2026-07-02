// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HyperCoreVault} from "../src/HyperCoreVault.sol";
import {IHyperCoreVault} from "../src/interfaces/IHyperCoreVault.sol";
import {PrecompileLib} from "../src/libraries/PrecompileLib.sol";
import {Constants} from "../src/libraries/Constants.sol";

/// @title Audit-remediation regression tests (self-contained; no fork/precompiles needed).
/// @notice Proves the fixes for the two HIGH findings CLOSE their PoCs:
///         H-1 — exitEscape can no longer be disarmed by an outsider (armedFor anchor).
///         H-2 — the escrow round-trip no longer resets cost basis (perf fee is charged).
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) {return 6;}
    function mint(address to, uint256 amt) external {_mint(to, amt);}
}

contract MockCoreWriter {
    function sendRawAction(bytes calldata) external {}
}

abstract contract Base is Test {
    HyperCoreVault vault;
    MockUSDC usdc;
    address admin        = address(this);
    address operator     = makeAddr("operator");
    address emergency    = makeAddr("emergency");
    address feeRecipient = makeAddr("feeRecipient");
    address keeper       = makeAddr("keeper");
    address alice        = makeAddr("alice");
    address bob          = makeAddr("bob");
    address attacker     = makeAddr("attacker");

    function _deploy(uint16 perfBps) internal {
        usdc = new MockUSDC();
        HyperCoreVault.Config memory cfg = HyperCoreVault.Config({
            asset: IERC20(address(usdc)), coreUsdcIndex: 0, coreUsdcDecimals: 8, coreDepositWallet: address(0),
            name: "Remediation Vault", symbol: "rem",
            admin: admin, operator: operator, emergencyAdmin: emergency, feeRecipient: feeRecipient,
            leverageCapBps: 0, slippageBandBps: 0, emergencyCloseBandBps: 0,
            mgmtFeeAnnualBps: 0, perfFeeBps: perfBps, depositCap: type(uint256).max, maxDepositPerAddress: 0
        });
        vault = new HyperCoreVault(cfg);
        vm.etch(Constants.CORE_WRITER, type(MockCoreWriter).runtimeCode);
    }

    function _dep(address who, uint256 a) internal returns (uint256 s) {
        usdc.mint(who, a);
        vm.startPrank(who);
        usdc.approve(address(vault), a);
        s = vault.deposit(a, who);
        vm.stopPrank();
    }

    /// @dev Give the vault phantom Core NAV (6dp) so claims exceed idle without needing
    ///      the reserve trick — lets multiple requests be overdue-unfillable at once.
    function _mockCore(uint256 usdc6dp) internal {
        vm.mockCall(
            Constants.SPOT_BALANCE_PRECOMPILE,
            abi.encode(address(vault), uint64(0)),
            abi.encode(PrecompileLib.SpotBalance({total: uint64(usdc6dp * 100), hold: 0, entryNtl: 0}))
        );
    }

    function _request(address who) internal {
        uint256 sh = vault.balanceOf(who); // compute BEFORE prank (arg eval would consume it)
        vm.prank(who);
        vault.requestWithdraw(sh);
    }

    /// @dev Arm the brake on a sole depositor (mock large Core NAV -> claim > idle), using
    ///      the M-3 default non-zero window.
    function _armSole(address who) internal {
        _dep(who, 100e6);
        _mockCore(100_000e6);
        _request(who);
        vm.warp(block.timestamp + vault.requestFulfillmentWindow() + vault.escapeGraceSeconds() + 1);
        vault.triggerEscape(who);
        require(vault.escapeActive(), "armed");
    }
}

contract M1_FlattenBand is Base {
    uint32 constant PERP = 0;

    function setUp() public {_deploy(0);}

    function _mockPosition(int64 szi) internal {
        vm.mockCall(
            Constants.POSITION_PRECOMPILE, abi.encode(address(vault), PERP),
            abi.encode(PrecompileLib.Position({szi: szi, entryNtl: 0, isolatedRawUsd: 0, leverage: 10, isIsolated: false}))
        );
        vm.mockCall(
            Constants.PERP_ASSET_INFO_PRECOMPILE, abi.encode(PERP),
            abi.encode(PrecompileLib.PerpAssetInfo({coin: "X", marginTableId: 0, szDecimals: 2, maxLeverage: 10, onlyIsolated: false}))
        );
        vm.mockCall(Constants.MARK_PX_PRECOMPILE, abi.encode(PERP), abi.encode(uint64(1e4))); // markNorm = 1e4*1e4 = 1e8
    }

    function _flatten(uint64 px) internal {
        uint32[] memory perps = new uint32[](1); perps[0] = PERP;
        uint64[] memory pxs = new uint64[](1); pxs[0] = px;
        vault.escapeFlattenPerps(perps, pxs);
    }

    // Default band 0 + a HELD position -> the permissionless flatten fails closed.
    function test_M1_flatten_reverts_on_band_zero_when_placing() public {
        assertEq(vault.emergencyCloseBandBps(), 0, "band defaults off");
        _armSole(alice);
        _mockPosition(100);
        vm.expectRevert(IHyperCoreVault.EmergencyCloseBandRequired.selector);
        _flatten(1e8);
    }

    // Surgical: a flat position (nothing to place) is a no-op even with band 0.
    function test_M1_flatten_noop_when_flat_even_with_band_zero() public {
        _armSole(alice);
        _mockPosition(0);
        _flatten(1e8); // no revert
    }

    function test_M1_setEmergencyCloseBand_rejects_zero() public {
        vm.expectRevert(IHyperCoreVault.EmergencyCloseBandRequired.selector);
        vault.setEmergencyCloseBand(0);
        vault.setEmergencyCloseBand(1000);
        assertEq(vault.emergencyCloseBandBps(), 1000);
    }

    // With a band configured, an in-band close still places (no regression).
    function test_M1_flatten_places_within_band() public {
        vault.setEmergencyCloseBand(1000); // 10%
        _armSole(alice);
        _mockPosition(100);
        uint128 c0 = vault.nextCloid();
        _flatten(1e8); // == markNorm -> within band -> places
        assertEq(vault.nextCloid(), c0 + 1, "order placed within band");
    }
}

contract M3_Window is Base {
    function setUp() public {_deploy(0);}

    function test_M3_window_nonzero_by_default() public view {
        assertEq(vault.requestFulfillmentWindow(), 24 hours, "armable brake + FCFS reserve on by default");
    }

    function test_M3_optout_still_allowed() public {
        vault.setRequestFulfillmentWindow(0); // documented no-SLA opt-out preserved
        assertEq(vault.requestFulfillmentWindow(), 0);
    }
}

contract H1_EscapeBrake is Base {
    uint256 constant BIG = 100_000e6; // large phantom Core NAV so even small claims exceed idle

    function setUp() public {
        _deploy(0);
        vault.setRequestFulfillmentWindow(1 hours);
    }

    // Arm the brake on `who` (sole/among depositors), with Core NAV making the claim unfillable.
    function _armOn(address who) internal {
        vm.warp(block.timestamp + 1 hours + vault.escapeGraceSeconds() + 1);
        vault.triggerEscape(who);
        assertTrue(vault.escapeActive(), "armed");
    }

    function test_H1_emptyList_and_nonBlocker_cannot_disarm() public {
        _dep(alice, 100e6);
        _mockCore(BIG);          // claim_alice >> idle -> overdue-unfillable
        _request(alice);
        _armOn(alice);

        // The exploit: an outsider tries to clear with an empty / irrelevant list.
        address[] memory empty = new address[](0);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.EscapeBacklogRemains.selector, alice));
        vault.exitEscape(empty);
        assertTrue(vault.escapeActive(), "brake survived exitEscape([])");

        address[] memory bogus = new address[](1);
        bogus[0] = bob; // no request
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.EscapeBacklogRemains.selector, alice));
        vault.exitEscape(bogus);
        assertTrue(vault.escapeActive(), "brake survived exitEscape([nonBlocker])");

        // Cranks still run (brake stayed armed).
        vault.escapeCancelOrders(1, new uint128[](0)); // reverts EscapeModeNotActive if not armed
    }

    function test_H1_legit_clear_via_cancel() public {
        _dep(alice, 100e6);
        _mockCore(BIG);
        _request(alice);
        _armOn(alice);
        // Alice cancels her own request -> the arming anchor is gone -> exit clears.
        vm.prank(alice);
        vault.cancelWithdrawRequest();
        vault.exitEscape(new address[](0));
        assertFalse(vault.escapeActive(), "cleared once the arming request was cancelled");
    }

    function test_H1_legit_clear_via_repatriation() public {
        _dep(alice, 100e6);
        _mockCore(BIG);
        _request(alice);
        _armOn(alice);
        // Simulate the escape pull: Core repatriated to idle, so alice's claim (now backed
        // by idle) is fillable -> the anchor is honorable -> exit clears.
        _mockCore(0);
        vault.exitEscape(new address[](0));
        assertFalse(vault.escapeActive(), "cleared once the arming request became fillable");
    }

    function test_H1_capture_resistant_reArm_does_not_move_anchor() public {
        _dep(alice, 100e6);
        _dep(attacker, 1e6);        // attacker holds a small position
        _mockCore(BIG);          // everyone's claim > idle
        _request(alice);
        _request(attacker);
        _armOn(alice);              // armedFor = alice

        // Attacker re-triggers on THEIR own qualifying request; idempotent -> anchor stays alice.
        vm.prank(attacker);
        vault.triggerEscape(attacker);
        // Attacker resolves their own request, then tries to clear.
        vm.prank(attacker);
        vault.cancelWithdrawRequest();
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.EscapeBacklogRemains.selector, alice));
        vault.exitEscape(new address[](0));
        assertTrue(vault.escapeActive(), "anchor stayed on alice; capture failed");
    }

    function test_H1_momentary_clear_then_rearm_on_other_backlog() public {
        _dep(alice, 100e6);
        _dep(bob, 100e6);
        _mockCore(BIG);          // both claims > idle, independent of each other
        _request(alice);
        _request(bob);
        _armOn(alice);              // armedFor = alice

        // Resolve A; bob still qualifies (idle unchanged) but the anchor was alice -> clears.
        vm.prank(alice);
        vault.cancelWithdrawRequest();
        vault.exitEscape(new address[](0));
        assertFalse(vault.escapeActive(), "cleared when the anchor resolved");

        // Anyone re-arms on the remaining backlog.
        vault.triggerEscape(bob);
        assertTrue(vault.escapeActive(), "re-armed on bob");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.EscapeBacklogRemains.selector, bob));
        vault.exitEscape(new address[](0));
    }
}

contract H2_PerfFee is Base {
    uint16 constant PERF = 2000; // 20%

    function setUp() public {
        _deploy(PERF);
    }

    // Alice enters at PPS 1.0; the vault doubles -> ~100 USDC gain -> honest fee ~20 USDC.
    function _seedGain() internal returns (uint256 aliceShares) {
        aliceShares = _dep(alice, 100e6);
        _dep(bob, 1e6);                    // a second holder (source of the dust transfer)
        usdc.mint(address(vault), 101e6);  // idle gain -> PPS ~doubles
    }

    function test_H2_escrow_roundtrip_now_charges_fee() public {
        uint256 s = _seedGain();
        // The exploit sequence (was: 0 fee).
        vm.prank(alice);
        vault.requestWithdraw(s);
        vm.prank(bob);
        vault.transfer(alice, 1);          // dust transfer-in (balBefore==0 overwrite)
        vm.prank(alice);
        vault.cancelWithdrawRequest();     // FIX: re-absorbs at snapshot basis
        uint256 bal = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(bal, alice, alice);
        assertGt(usdc.balanceOf(feeRecipient), 15e6, "perf fee is now charged (~20 USDC), not evaded");
    }

    function test_H2_honest_cancel_is_a_noop() public {
        // Honest LP: request all, cancel (no transfer-in), redeem -> fee identical to baseline.
        uint256 s = _seedGain();
        vm.prank(alice);
        vault.requestWithdraw(s);
        vm.prank(alice);
        vault.cancelWithdrawRequest();
        uint256 bal = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(bal, alice, alice);
        assertApproxEqAbs(usdc.balanceOf(feeRecipient), 20e6, 1e6, "honest cancel unchanged (~20 USDC fee)");
    }

    function test_H2_cancel_mints_no_shares_C3() public {
        uint256 s = _seedGain();
        vm.prank(alice);
        vault.requestWithdraw(s);
        uint256 supplyBefore = vault.totalSupply();
        vm.prank(alice);
        vault.cancelWithdrawRequest();
        assertEq(vault.totalSupply(), supplyBefore, "cancel mints no fee shares (audit C-3)");
    }
}
