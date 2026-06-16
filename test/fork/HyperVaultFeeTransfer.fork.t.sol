// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HyperVaultBaseForkTest} from "./HyperVaultBase.fork.t.sol";
import {HyperCoreVault} from "../../src/HyperCoreVault.sol";

/// @title  Phase M1 — transfer-as-realization perf fee (close loss-netting)
/// @notice An inter-LP share transfer now crystallizes the transferor's perf fee
///         on the transferred shares by DIVERTING fee-equivalent shares to
///         feeRecipient (no mint → no dilution → preserves C-3). This closes the
///         loss-netting evasion: routing a gaining LP's shares into an underwater
///         LP used to net the gain away (the receiver inherited a blended basis
///         and was never taxed). All pure-EVM share math — fully fork-provable.
contract HyperVaultFeeTransferForkTest is HyperVaultBaseForkTest {
    // ── M1 core: a gaining LP's transfer diverts the perf fee to feeRecipient ──
    function test_M1_transferRealizesTransferorGain() public {
        _skipIfNoFork();
        vault = _deployVault(0, 1500); // 15% perf

        // Alice enters at PPS 1.0; a gain lifts PPS to 2.0 (alice basis stays 1.0).
        uint256 aShares = _deposit(alice, 100e6);
        _fundIdle(100e6); // sole LP -> NAV 200, PPS 2.0, alice unrealised gain 100e6

        uint256 supplyBefore = vault.totalSupply();
        uint256 feeRecipBefore = vault.balanceOf(feeRecipient);
        uint256 carolStakeBefore = vault.balanceOf(carol); // 0 — sanity baseline

        // Alice transfers her ENTIRE position to bob (the all-shares edge).
        vm.prank(alice);
        vault.transfer(bob, aShares);

        uint256 feeShares = vault.balanceOf(feeRecipient) - feeRecipBefore;
        uint256 bobShares = vault.balanceOf(bob);

        // (1) The transferor's gain is realized: feeRecipient received fee shares.
        assertGt(feeShares, 0, "M1: perf fee diverted to feeRecipient on the gaining transfer");
        // (2) No mint -> total supply unchanged -> stayers not diluted (C-3).
        assertEq(vault.totalSupply(), supplyBefore, "M1: totalSupply unchanged (redirect, not mint)");
        // (3) Receiver got value - feeShares (the haircut funds the fee).
        assertEq(bobShares, aShares - feeShares, "M1: receiver gets value - feeShares");
        // (4) Alice fully exited her position.
        assertEq(vault.balanceOf(alice), 0, "M1: transferor sent her entire balance");
        carolStakeBefore; // silence unused

        // (5) The gain was taxed AT TRANSFER, not deferred: bob redeeming now pays
        //     ~no further perf fee (his shares entered at the realized PPS basis),
        //     so an underwater LP can no longer absorb alice's gain.
        uint256 f0 = IERC20(USDC).balanceOf(feeRecipient);
        vm.prank(bob);
        vault.redeem(bobShares, bob, bob);
        uint256 bobRedeemFee = IERC20(USDC).balanceOf(feeRecipient) - f0;
        assertLt(bobRedeemFee, 0.5e6, "M1: bob's received shares carry no untaxed gain (realized at transfer)");

        console2.log("M1 PASS - transfer realizes the transferor's gain; no dilution; loss-netting closed");
    }

    // ── M1 control: gain taxed equally whether realized by transfer or by redeem ──
    function test_M1_transferFeeMatchesDirectRedeem() public {
        _skipIfNoFork();

        // Setup A: alice gains, then redeems DIRECTLY -> fee_A.
        vault = _deployVault(0, 1500);
        uint256 aShares = _deposit(alice, 100e6);
        _fundIdle(100e6); // PPS 2.0
        uint256 fa0 = IERC20(USDC).balanceOf(feeRecipient);
        vm.prank(alice);
        vault.redeem(aShares, alice, alice);
        uint256 feeDirect = IERC20(USDC).balanceOf(feeRecipient) - fa0;

        // Setup B (fresh vault): alice gains identically, TRANSFERS all to bob, then
        // bob redeems. Total fee should equal the direct-redeem fee (taxed once).
        vault = _deployVault(0, 1500);
        uint256 feeRecipB0 = vault.balanceOf(feeRecipient);
        uint256 aShares2 = _deposit(alice, 100e6);
        _fundIdle(100e6); // PPS 2.0
        vm.prank(alice);
        vault.transfer(bob, aShares2);
        uint256 transferFeeShares = vault.balanceOf(feeRecipient) - feeRecipB0;

        // feeRecipient redeems its diverted shares + bob redeems his.
        uint256 fb0 = IERC20(USDC).balanceOf(feeRecipient);
        vm.prank(feeRecipient);
        vault.redeem(transferFeeShares, feeRecipient, feeRecipient);
        uint256 bobBal = vault.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(bobBal, bob, bob);
        uint256 feeViaTransfer = IERC20(USDC).balanceOf(feeRecipient) - fb0;

        assertGt(feeDirect, 0, "control: direct redeem charges a fee");
        assertApproxEqRel(feeViaTransfer, feeDirect, 0.02e18, "M1: transfer realizes ~the same fee as a direct redeem");
        console2.log("M1 PASS - transfer-realized fee matches the direct-redeem fee (gain taxed once)");
    }

    // ── M1: escrow moves (request/cancel) are exempt — vault is the counterparty ──
    function test_M1_escrowTransfersAreFeeFree() public {
        _skipIfNoFork();
        vault = _deployVault(0, 1500);
        uint256 aShares = _deposit(alice, 100e6);
        _fundIdle(100e6); // PPS 2.0, alice has a gain

        uint256 feeRecipBefore = vault.balanceOf(feeRecipient);

        vm.prank(alice);
        vault.requestWithdraw(aShares); // escrow to the vault (from=alice, to=vault) -> exempt
        assertEq(vault.balanceOf(feeRecipient), feeRecipBefore, "M1: escrow-in diverts no fee");

        vm.prank(alice);
        vault.cancelWithdrawRequest(); // vault -> alice -> exempt
        assertEq(vault.balanceOf(feeRecipient), feeRecipBefore, "M1: escrow-out diverts no fee");
        assertEq(vault.balanceOf(alice), aShares, "M1: cancel restored exactly the escrowed shares");

        console2.log("M1 PASS - request/cancel escrow moves are fee-free (vault-as-counterparty exempt)");
    }

    // ── M1: a zero-gain transfer takes no haircut ──────────────────────────────
    function test_M1_zeroGainTransferNoHaircut() public {
        _skipIfNoFork();
        vault = _deployVault(0, 1500);
        // Carol enters at PPS 1.0 with no subsequent gain (PPS stays 1.0).
        uint256 cShares = _deposit(carol, 100e6);
        uint256 feeRecipBefore = vault.balanceOf(feeRecipient);

        vm.prank(carol);
        vault.transfer(bob, cShares);

        assertEq(vault.balanceOf(feeRecipient), feeRecipBefore, "M1: no gain -> no fee diverted");
        assertEq(vault.balanceOf(bob), cShares, "M1: recipient gets the FULL value when there's no gain");
        console2.log("M1 PASS - zero-gain transfer takes no haircut (recipient gets full value)");
    }

    // ── M1: stayers are not diluted by a realizing transfer ────────────────────
    function test_M1_noDilutionOfStayers() public {
        _skipIfNoFork();
        vault = _deployVault(0, 1500);

        _deposit(carol, 100e6); // the STAYER
        uint256 aShares = _deposit(alice, 100e6);
        _fundIdle(100e6); // both gain; PPS up

        uint256 carolAssetsBefore = vault.convertToAssets(vault.balanceOf(carol));
        uint256 supplyBefore = vault.totalSupply();

        vm.prank(alice);
        vault.transfer(bob, aShares); // realizing transfer diverts fee shares

        // Carol neither transacted nor was diluted: her claim and the supply hold.
        assertEq(vault.totalSupply(), supplyBefore, "M1: supply unchanged");
        assertApproxEqAbs(
            vault.convertToAssets(vault.balanceOf(carol)), carolAssetsBefore, 1, "M1: stayer's claim unchanged"
        );
        console2.log("M1 PASS - a realizing transfer does not dilute non-transacting LPs (C-3 preserved)");
    }
}
