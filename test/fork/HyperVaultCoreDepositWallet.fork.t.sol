// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HyperVaultBaseForkTest} from "./HyperVaultBase.fork.t.sol";
import {IHyperCoreVault} from "../../src/interfaces/IHyperCoreVault.sol";
import {ICoreDepositWallet} from "../../src/interfaces/ICoreDepositWallet.sol";
import {Constants} from "../../src/libraries/Constants.sol";

/// @dev CoreWriter stub for the pull-encoding proof (same pattern as the
///      Liveness suite's MockCoreWriter — we assert the EXACT action bytes,
///      not CoreWriter processing, which is the live spike's job).
contract CoreWriterEcho {
    event RawAction(bytes data);

    function sendRawAction(bytes calldata data) external {
        emit RawAction(data);
    }
}

/// @title  Phase G2 — pushToCore via Circle's CoreDepositWallet (forked mainnet, real bytecode)
/// @notice The EVM half of the official USDC EVM->Core route, executed against the
///         REAL CoreDepositWallet bytecode (`tokenInfo(0).evmContract`, ~$4.9B
///         reserve): `approve + deposit(amount, CORE_SPOT_DEX_ID)` pulls the USDC
///         into the wallet, emits the wallet's Core-credit logs, and leaves no
///         residual allowance. What a fork CANNOT prove — the Core-side spot
///         credit appearing, and the wallet paying native USDC back out on a
///         Core-side system-address send — is stubbed `_provenInLiveSpike` and
///         executed by Scenario C in docs/REDEMPTION_LIVE_RUNBOOK.md.
contract HyperVaultCoreDepositWalletForkTest is HyperVaultBaseForkTest {
    event RawAction(bytes data);
    event BridgeWithdraw(uint64 amountWei);

    /// @dev Self-guard: the suite must never false-green (or false-red) because
    ///      Circle paused the wallet at the fork block.
    function _skipIfWalletPaused() internal {
        if (ICoreDepositWallet(CORE_DEPOSIT_WALLET).paused()) {
            console2.log("SKIP - CoreDepositWallet is paused at this fork block");
            vm.skip(true);
        }
    }

    // ───────────────────────────────────────────────────────────────────────
    // G2 (1) — push deposits via the REAL wallet: idle drops, the wallet's USDC
    //   reserve grows by exactly the pushed amount (Circle bytecode executed the
    //   transferFrom), BridgeDeposit fires, and no allowance is left standing.
    // ───────────────────────────────────────────────────────────────────────
    function test_G2_pushDepositsViaWallet() public {
        _skipIfNoFork();
        _skipIfWalletPaused();

        _deposit(alice, 100e6);
        uint256 walletBefore = IERC20(USDC).balanceOf(CORE_DEPOSIT_WALLET);

        vm.expectEmit(false, false, false, true, address(vault));
        emit BridgeDeposit(80e6);
        vm.prank(operator);
        vault.pushToCore(80e6);

        assertEq(vault.idleUsdc(), 20e6, "idle reduced by exactly the pushed amount");
        assertEq(
            IERC20(USDC).balanceOf(CORE_DEPOSIT_WALLET) - walletBefore,
            80e6,
            "the REAL CoreDepositWallet custodies the deposit"
        );
        assertEq(
            IERC20(USDC).allowance(address(vault), CORE_DEPOSIT_WALLET),
            0,
            "no residual allowance to a third-party upgradeable contract"
        );
        console2.log("G2 PASS - pushToCore deposits via Circle's CoreDepositWallet (real bytecode)");
    }

    // ───────────────────────────────────────────────────────────────────────
    // G2 (2) — the wallet emits its own logs during deposit (the synthetic
    //   Transfer HyperCore watches to credit Core spot). We assert the wallet
    //   emitted >= 1 log without coupling to Circle's event signatures.
    // ───────────────────────────────────────────────────────────────────────
    function test_G2_pushEmitsWalletLogs() public {
        _skipIfNoFork();
        _skipIfWalletPaused();

        _deposit(alice, 50e6);
        vm.recordLogs();
        vm.prank(operator);
        vault.pushToCore(50e6);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 walletLogs;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == CORE_DEPOSIT_WALLET) walletLogs++;
        }
        assertGt(walletLogs, 0, "wallet emitted its Core-credit log(s) during deposit");
    }

    // ───────────────────────────────────────────────────────────────────────
    // G2 (3) — a zero-amount push reverts inside the wallet (clean failure,
    //   no state change). Generic expectRevert: Circle's revert string is not
    //   our ABI to couple to.
    // ───────────────────────────────────────────────────────────────────────
    function test_G2_pushZeroAmountReverts() public {
        _skipIfNoFork();
        _skipIfWalletPaused();

        vm.prank(operator);
        vm.expectRevert();
        vault.pushToCore(0);
    }

    // ───────────────────────────────────────────────────────────────────────
    // G2 (4) — the H2 available-idle guard fires BEFORE any wallet interaction:
    //   the revert carries the vault's own selector (not a wallet error), and
    //   no allowance was ever granted.
    // ───────────────────────────────────────────────────────────────────────
    function test_G2_pushExceedingAvailableIdleReverts() public {
        _skipIfNoFork();

        _deposit(alice, 50e6);
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IHyperCoreVault.WithdrawExceedsIdleBalance.selector, uint256(60e6), uint256(50e6))
        );
        vault.pushToCore(60e6);
        assertEq(IERC20(USDC).allowance(address(vault), CORE_DEPOSIT_WALLET), 0, "guard fired pre-wallet");
    }

    // ───────────────────────────────────────────────────────────────────────
    // G2 (5) — pullFromCore emits a CoreWriter `send_asset` (action 13), NOT the
    //   legacy `spot_send` (action 6). Proven live 2026-06-15: unified HyperCore
    //   accounts silently drop spot_send (Core never debits), so the withdrawal
    //   MUST use send_asset. Payload mirrors Circle's CoreDepositWallet exactly:
    //   (recipient=token system address, subAccount=0, sourceDex=destDex=Core
    //   Spot, token=index, amount=8dp wei). The system then pays the CALLER (this
    //   vault) native USDC at amount/100. Encoding asserted against a CoreWriter
    //   echo stub (the fork cannot serve the Core side — see the live stubs below).
    // ───────────────────────────────────────────────────────────────────────
    function test_G2_pullUsesSendAssetNotSpotSend() public {
        _skipIfNoFork();
        vm.etch(Constants.CORE_WRITER, type(CoreWriterEcho).runtimeCode);

        bytes memory expected = abi.encodePacked(
            Constants.CORE_WRITER_VERSION,
            uint24(Constants.ACTION_SEND_ASSET),
            abi.encode(
                USDC_BRIDGE, // recipient = token system address (triggers the withdrawal)
                address(0), // subAccount unused
                Constants.CORE_SPOT_DEX_ID, // sourceDex = Core Spot
                Constants.CORE_SPOT_DEX_ID, // destinationDex = Core Spot
                uint64(0), // token index (USDC = 0)
                uint64(777) // amount in 8dp Core wei
            )
        );
        vm.expectEmit(false, false, false, true, Constants.CORE_WRITER);
        emit RawAction(expected);
        vm.expectEmit(false, false, false, true, address(vault));
        emit BridgeWithdraw(777);

        vm.prank(operator);
        vault.pullFromCore(777);
    }

    // ───────────────────────────────────────────────────────────────────────
    // Live-only stubs: a forge fork cannot serve the HyperCore side — the spot
    // credit after a push, and the wallet's system-guarded payout after a
    // Core-side send_asset. BOTH PROVEN LIVE 2026-06-15/16 on throwaway vault
    // 0xDE6A0c9371aCBC95fd3AC6B8A3598780013ec777 — see docs/FORK_PROOFS.md
    // "v1.5 G2 — live spike" for the full tx-hash record.
    // ───────────────────────────────────────────────────────────────────────

    /// @dev PROVEN LIVE: after `pushToCore(X)`, the HL API and the on-chain
    ///      `coreSpotUsdc()` precompile both show the vault's Core spot credited
    ///      (X minus the one-time 1.0 USDC first-account activation gas).
    function test_G2_coreSpotCreditAppears_provenInLiveSpike() public {
        vm.skip(true);
    }

    /// @dev PROVEN LIVE: the pull is a CoreWriter `send_asset` (action 13) to the
    ///      system address (NOT `spot_send` — unified accounts drop that). It
    ///      debits the vault's Core spot and the wallet pays native USDC to the
    ///      CALLER (this vault), idle += floor(amountWei/100). A ~0.00134 USDC
    ///      withdrawal fee is taken from Core on top of the amount, so the EXACT
    ///      full balance is dropped — pull under it. Settled txs:
    ///      0xc47db60e… ($1) and 0xa44b4fbf… ($2.79); full-balance drop: 0xb65397a0….
    function test_G2_walletPayoutOnPull_provenInLiveSpike() public {
        vm.skip(true);
    }
}
