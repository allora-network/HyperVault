// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HyperVaultBaseForkTest} from "./HyperVaultBase.fork.t.sol";
import {HyperCoreVault} from "../../src/HyperCoreVault.sol";
import {IHyperCoreVault} from "../../src/interfaces/IHyperCoreVault.sol";
import {PrecompileLib} from "../../src/libraries/PrecompileLib.sol";
import {SystemAddress} from "../../src/libraries/SystemAddress.sol";
import {Constants} from "../../src/libraries/Constants.sol";

/// @dev CoreWriter stub etched at the system address so the leg-4a pull crank executes
///      deterministically and emits its `send_asset` action + {BridgeWithdraw}. We
///      capture the EMITTED raw action so the chunk/fee arithmetic in the resulting
///      send_asset payload can be decoded and asserted — NOT Core settlement (a forge
///      fork cannot run the HyperCore precompiles nor process CoreWriter; the real
///      Core debit + CoreDepositWallet EVM payout are the live spike's job, see the
///      `_provenInLiveSpike` stub at the bottom).
contract MockCoreWriterPull {
    event RawAction(bytes data);

    function sendRawAction(bytes calldata data) external {
        emit RawAction(data);
    }
}

/// @title  M5 escape-hatch Phase-2 leg-4a proofs (forked HyperEVM mainnet, real bytecode)
/// @notice Proves the permissionless, escape-gated, chunked + cooldown'd Core-spot-USDC
///         -> EVM-idle pull ({escapePullToEvm}, SOLU-3370) on a freshly deployed vault
///         against the real USDC ERC20 — no economic mocks. Leg 4a is the escape-mode
///         twin of {pullFromCore}: a `send_asset` (action 13, spot->spot) to the USDC
///         system address that has the linked CoreDepositWallet pay native USDC back to
///         the vault. docs/ESCAPE_HATCH_SCOPE.md §2 leg 4 / §3 option 4a / §7 Phase 2.
///
///         FORK LIMITATION (same as the rest of the suite): revm does not implement the
///         HyperCore precompiles (0x0800-0x0810) and does not process CoreWriter. So:
///         (1) the gate / cooldown / latch / permissionless / not-latched proofs are
///         FULL (pure EVM control flow on the latch struct, fires before any precompile/
///         CoreWriter); (2) the FEE + CHUNK arithmetic depends on the Core-balance
///         precompile read a fork cannot serve (it reads 0 ⇒ the send no-ops), so the
///         chunk-cap / fee-guard proof drives the {SPOT_BALANCE_PRECOMPILE} with
///         `vm.mockCall` SOLELY to reach the pure-EVM `min(balance*998/1000, maxChunk)`
///         math and decode the resulting send_asset payload (a code-logic assertion, not
///         economic settlement — mirroring how {HyperVaultEscapeForkTest}'s leg-2 band
///         test mockCalls precompiles to reach the pure-EVM band comparison); (3) the
///         real Core debit + the CoreDepositWallet EVM payout are a `_provenInLiveSpike`
///         stub (the no-fake-settlement rule).
contract HyperVaultEscapePullForkTest is HyperVaultBaseForkTest {
    // Event mirrors for vm.expectEmit (matched by signature + data).
    event EscapeCrankRun(address indexed by, uint8 indexed leg);
    event BridgeWithdraw(uint64 amountWei);

    /// @dev A dedicated, dominant arming LP — independent of alice/bob so it never
    ///      collides with a test's own actors (one open request per LP). Mirrors
    ///      {HyperVaultEscapeForkTest.escapeArmer}.
    address internal escapeArmer = makeAddr("escapeArmerPull");

    /// @dev Arm the brake via the SOLU-3371 PERMISSIONLESS staleness trigger (verbatim
    ///      the {HyperVaultEscapeForkTest._armEscape} recipe): a DOMINANT armer deposits
    ///      + requests, the clock warps PAST deadline + grace, {prioritizeOverdue}
    ///      reserves the armer's claim (zeroing availableIdle WITHOUT collapsing NAV —
    ///      the fork-faithful way to make claim > availableIdle, since draining idle
    ///      would also drop NAV as coreSpotUsdc reads 0 on a fork), and {triggerEscape}
    ///      arms (both legs of the condition hold). Returns the armer.
    function _armEscape() internal returns (address armer) {
        armer = escapeArmer;
        if (vault.requestFulfillmentWindow() == 0) vault.setRequestFulfillmentWindow(1 hours);
        uint64 window = vault.requestFulfillmentWindow();
        uint256 sh = _deposit(armer, 1_000_000e6); // dominant claim
        vm.prank(armer);
        vault.requestWithdraw(sh);
        vm.warp(block.timestamp + window + vault.escapeGraceSeconds() + 1);
        vm.prank(keeper);
        vault.prioritizeOverdue(armer); // reserve -> availableIdle drops below the claim
        vault.triggerEscape(armer); // permissionless: condition (a)+(b) hold
        require(vault.escapeActive(), "armed via the permissionless staleness trigger");
    }

    /// @dev Mock the Core USDC spot-balance precompile read (8dp Core wei) so the
    ///      leg-4a fee/chunk arithmetic is reachable on a fork. SOLELY a control-flow
    ///      injection to exercise the pure-EVM `min(balance*998/1000, maxChunk)` math
    ///      and let the etched MockCoreWriter capture the resulting send_asset — NOT a
    ///      fund or settlement (the no-fake-settlement rule; the real debit/payout is
    ///      the live spike's job). `navBootstrap` is true at deploy, so the vault takes
    ///      the lenient `spotBalance` branch (precompile 0x801).
    function _mockCoreUsdcBalance(uint64 total) internal {
        PrecompileLib.SpotBalance memory bal = PrecompileLib.SpotBalance({total: total, hold: 0, entryNtl: 0});
        vm.mockCall(
            Constants.SPOT_BALANCE_PRECOMPILE, abi.encode(address(vault), vault.coreUsdcIndex()), abi.encode(bal)
        );
    }

    /// @dev Decode the send_asset (action 13) amount from the etched MockCoreWriter's
    ///      captured raw action. Payload = CORE_WRITER_VERSION(1) ++ uint24(action) ++
    ///      abi.encode(recipient, address(0), srcDex, dstDex, token, amountWei). We strip
    ///      the 4-byte header and decode the tail; returns (recipient, token, amountWei).
    function _decodeSendAsset(bytes memory raw)
        internal
        pure
        returns (address recipient, uint64 token, uint64 amountWei)
    {
        // header: 1 version byte + 3 action bytes = 4 bytes.
        bytes memory tail = new bytes(raw.length - 4);
        for (uint256 i = 0; i < tail.length; ++i) {
            tail[i] = raw[i + 4];
        }
        address subAccount;
        uint32 srcDex;
        uint32 dstDex;
        (recipient, subAccount, srcDex, dstDex, token, amountWei) =
            abi.decode(tail, (address, address, uint32, uint32, uint64, uint64));
    }

    /// @dev Pull the most-recent `RawAction(bytes)` payload emitted by the etched
    ///      {MockCoreWriterPull} (at {Constants.CORE_WRITER}) out of the recorded logs.
    ///      Caller must {vm.recordLogs} before the crank. Reverts if none was emitted
    ///      (so a silent no-op send can never pass an arithmetic assertion).
    function _lastRawAction() internal returns (bytes memory data) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic0 = keccak256("RawAction(bytes)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == Constants.CORE_WRITER && logs[i].topics.length != 0 && logs[i].topics[0] == topic0) {
                data = abi.decode(logs[i].data, (bytes));
                found = true;
            }
        }
        require(found, "no send_asset RawAction emitted (the crank no-op'd the send)");
    }

    // ───────────────────────────────────────────────────────────────────────
    // Latch gate (M5 §4) — leg 4a runs ONLY while latched.
    //   Fork-provable: FULL — the shared crank gate fires before any precompile.
    // ───────────────────────────────────────────────────────────────────────
    function test_leg4a_revertsWhenNotLatched() public {
        _skipIfNoFork();
        vm.etch(Constants.CORE_WRITER, type(MockCoreWriterPull).runtimeCode);

        // Not armed: the shared crank gate rejects with EscapeModeNotActive.
        vm.prank(keeper);
        vm.expectRevert(IHyperCoreVault.EscapeModeNotActive.selector);
        vault.escapePullToEvm(type(uint64).max);

        console2.log("M5 PASS - leg 4a reverts EscapeModeNotActive when the brake is not armed");
    }

    /// @dev While latched with the Core balance reading 0 on the fork (no precompile),
    ///      leg 4a passes the gate and emits EscapeCrankRun(.,4) WITHOUT dispatching a
    ///      send_asset — the zero/dust no-op branch (mirrors leg 3's zero-withdrawable
    ///      proof). Proves the gate + event wiring; the actual pull is live-only.
    function test_leg4a_runsGateAndEventWhenBalanceZero() public {
        _skipIfNoFork();
        vm.etch(Constants.CORE_WRITER, type(MockCoreWriterPull).runtimeCode);
        _armEscape();

        // spotBalance reads 0 on the fork (lenient, no precompile) -> fee-aware amount
        // is 0 -> no send_asset, but the gate runs and the crank event fires.
        vm.expectEmit(true, true, false, true, address(vault));
        emit EscapeCrankRun(keeper, 4);
        vm.prank(keeper);
        vault.escapePullToEvm(type(uint64).max);

        console2.log("M5 PASS - leg 4a runs the gate + emits EscapeCrankRun(.,4); the actual pull is live-only");
    }

    // ───────────────────────────────────────────────────────────────────────
    // Permissionless (M5 §2/§4) — an arbitrary unprivileged caller can run it.
    //   Fork-provable: FULL — there is no role gate; only the latch + cooldown.
    // ───────────────────────────────────────────────────────────────────────
    function test_leg4a_isPermissionless() public {
        _skipIfNoFork();
        vm.etch(Constants.CORE_WRITER, type(MockCoreWriterPull).runtimeCode);
        _armEscape();

        // `attacker` holds NO role; the crank still runs while latched (the security is
        // the latch + the risk-reducing/repatriating nature, not the caller).
        vm.expectEmit(true, true, false, true, address(vault));
        emit EscapeCrankRun(attacker, 4);
        vm.prank(attacker);
        vault.escapePullToEvm(type(uint64).max);

        console2.log("M5 PASS - leg 4a is permissionless (an arbitrary unprivileged caller runs it while latched)");
    }

    // ───────────────────────────────────────────────────────────────────────
    // Cooldown (M5 §4) — a second pull within escapeCrankInterval reverts; runs
    //   again after the interval. This IS the required COOLDOWN that spaces chunks.
    //   Fork-provable: FULL — block.timestamp arithmetic on the latch struct.
    // ───────────────────────────────────────────────────────────────────────
    function test_leg4a_cooldownSpacesChunks() public {
        _skipIfNoFork();
        vm.etch(Constants.CORE_WRITER, type(MockCoreWriterPull).runtimeCode);
        _armEscape();

        uint64 interval = vault.escapeCrankInterval();
        assertEq(interval, 60, "interval is the fixed 60s envelope");

        // First crank runs immediately (lastCrankTs == 0).
        vm.prank(keeper);
        vault.escapePullToEvm(type(uint64).max);

        // A second crank within the interval is rejected (the cooldown spaces successive
        // chunks so a large balance drains over multiple cranks).
        uint64 nextAllowed = uint64(block.timestamp) + interval;
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IHyperCoreVault.EscapeCooldownActive.selector, nextAllowed));
        vault.escapePullToEvm(type(uint64).max);

        // After the interval elapses, the next chunk runs again.
        vm.warp(block.timestamp + interval);
        vm.prank(keeper);
        vault.escapePullToEvm(type(uint64).max);

        console2.log("M5 PASS - leg 4a cooldown: 1st chunk immediate; 2nd within 60s reverts; runs again after 60s");
    }

    // ───────────────────────────────────────────────────────────────────────
    // Fee-aware + chunk-cap arithmetic (M5 §3 option 4a).
    //   Claim: the send amount = min(balance * 998/1000, maxChunkWei). The fee guard
    //          never sends the exact full balance (the ~0.00134 USDC withdrawal fee
    //          drops an exact-full send — G2 spike); the chunk cap bounds each crank.
    //   Fork limitation: the Core balance reads 0 on a fork, so the send no-ops. To
    //          reach the pure-EVM amount math we inject the balance with vm.mockCall
    //          (control-flow only) and decode the emitted send_asset payload — asserting
    //          code logic, NOT economic settlement (no funds move). The send_asset
    //          targets the USDC system address (verbatim pullFromCore).
    // ───────────────────────────────────────────────────────────────────────
    function test_leg4a_feeGuardSendsUnderFullBalance() public {
        _skipIfNoFork();
        vm.etch(Constants.CORE_WRITER, type(MockCoreWriterPull).runtimeCode);
        _armEscape();

        // Inject a Core USDC balance of 1,000 USDC (8dp Core wei = 1_000e8). The chunk
        // cap is set ABOVE the fee-aware amount so the FEE guard binds, not the cap.
        uint64 balance = 1_000e8; // 1,000 USDC in 8dp Core wei
        _mockCoreUsdcBalance(balance);

        uint64 expected = uint64((uint256(balance) * 998) / 1000); // fee-aware 99.8%
        assertLt(expected, balance, "fee guard sends strictly UNDER the full balance");

        vm.recordLogs();
        vm.prank(keeper);
        vault.escapePullToEvm(balance); // maxChunk == full balance -> fee guard binds
        bytes memory raw = _lastRawAction();
        (address recipient, uint64 token, uint64 amountWei) = _decodeSendAsset(raw);

        assertEq(amountWei, expected, "send amount == balance * 998/1000 (fee-aware)");
        assertEq(recipient, SystemAddress.forToken(vault.coreUsdcIndex()), "send_asset targets USDC system address");
        assertEq(token, vault.coreUsdcIndex(), "send_asset moves the Core USDC token");

        vm.clearMockedCalls();
        console2.log(
            "M5 PASS - leg 4a fee guard: sends balance*998/1000 to the USDC system addr (under the full balance)"
        );
    }

    function test_leg4a_chunkCapBoundsTheSend() public {
        _skipIfNoFork();
        vm.etch(Constants.CORE_WRITER, type(MockCoreWriterPull).runtimeCode);
        _armEscape();

        // Inject a LARGE Core balance and a SMALL chunk cap so the CAP binds (a large
        // balance is repatriated in bounded chunks across cooldown-spaced cranks).
        uint64 balance = 1_000_000e8; // 1,000,000 USDC, fee-aware = 998,000 USDC
        uint64 maxChunk = 100e8; // 100 USDC per crank
        _mockCoreUsdcBalance(balance);

        uint64 feeAware = uint64((uint256(balance) * 998) / 1000);
        assertGt(feeAware, maxChunk, "fee-aware amount exceeds the chunk cap (so the cap binds)");

        vm.recordLogs();
        vm.prank(keeper);
        vault.escapePullToEvm(maxChunk);
        (,, uint64 amountWei) = _decodeSendAsset(_lastRawAction());

        assertEq(amountWei, maxChunk, "send amount == maxChunkWei (chunk cap binds, not the fee guard)");

        vm.clearMockedCalls();
        console2.log("M5 PASS - leg 4a chunk cap: a large balance is bounded to maxChunkWei per cooldown-spaced crank");
    }

    // ───────────────────────────────────────────────────────────────────────
    // Regression — leg 4a does NOT gate the OPERATOR pull or other paths: with escape
    //   INACTIVE, escapePullToEvm reverts EscapeModeNotActive (not callable off-latch),
    //   while pullFromCore (the OPERATOR twin) is unaffected by the latch's absence.
    // ───────────────────────────────────────────────────────────────────────
    function test_leg4a_doesNotDisturbOperatorPull() public {
        _skipIfNoFork();
        vm.etch(Constants.CORE_WRITER, type(MockCoreWriterPull).runtimeCode);
        assertFalse(vault.escapeActive(), "not latched");

        // The OPERATOR pull works without the latch (it is role-gated, not escape-gated).
        // With the stub etched the send_asset submit succeeds; on a fork the Core debit
        // is a no-op but the EVM tx + BridgeWithdraw fire (proven settlement is live).
        vm.expectEmit(false, false, false, true, address(vault));
        emit BridgeWithdraw(1);
        vm.prank(operator);
        vault.pullFromCore(1);

        console2.log("M5 PASS - the OPERATOR pullFromCore is unaffected by the (absent) escape latch");
    }

    // ───────────────────────────────────────────────────────────────────────
    // Live-only (no-fake-settlement): behaviors a forge fork cannot represent.
    // ───────────────────────────────────────────────────────────────────────

    /// @dev _provenInLiveSpike: leg 4a Core->EVM pull settlement (G2 spike 2026-06-15/16).
    ///      The real Core spot debit + the CoreDepositWallet paying native USDC back to
    ///      the vault on the EVM side (and thus idle landing for {fulfillWithdraw} to
    ///      drain the queue) need real HyperCore precompiles + CoreWriter processing +
    ///      the live Circle wallet — not fork-representable. The send_asset encoding +
    ///      the fee/chunk arithmetic that feed it are proven above; the round-trip
    ///      settlement is the G2 spike's job (docs/FORK_PROOFS.md "v1.5 G2 — live spike").
    function test_leg4a_corePullSettlement_provenInLiveSpike() public {
        _skipIfNoFork();
        console2.log(
            "leg 4a Core->EVM pull settlement (G2 spike 2026-06-15/16) needs live precompiles + CoreWriter + the Circle wallet."
        );
        vm.skip(true);
    }
}
