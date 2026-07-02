// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IHyperCoreVault} from "../interfaces/IHyperCoreVault.sol";
import {CoreWriterLib} from "./CoreWriterLib.sol";
import {PrecompileLib} from "./PrecompileLib.sol";
import {SystemAddress} from "./SystemAddress.sol";
import {Constants} from "./Constants.sol";

/// @title  VaultEscapeLib — externalized permissionless escape-hatch logic (M5)
/// @notice Phases 1-2 of the "dead man's brake" (docs/ESCAPE_HATCH_SCOPE.md §2,§4,§7):
///         the latch + cooldown machinery and the risk-reducing / repatriating cranks
///         that run while the vault is latched into ESCAPE mode — cancel resting orders
///         (leg 1), flatten perps via reduce-only IOC (leg 2), consolidate perp
///         equity to Core spot (leg 3), and pull Core spot USDC back to EVM idle
///         (leg 4a — Phase 2, SOLU-3370). Like {VaultTradeLib} these are EXTERNAL
///         functions invoked by the vault via DELEGATECALL, so `address(this)` is
///         the vault: CoreWriter sees the vault as the order's sender, the precompile
///         reads resolve the vault's own Core positions, and — crucially for M5 — the
///         vault's escape STATE and withdrawal queue are reachable by storage
///         reference (same slots), so the latch/cooldown bookkeeping AND the
///         leg-heavy loops both live here, out of the vault's 24576-byte EIP-170
///         budget (HyperEVM enforces it — audit G2; the same reason
///         {VaultTradeLib} exists; the vault only had ~339 bytes of headroom).
///
/// @dev    The cranks are PERMISSIONLESS on the vault surface (see §2/§4): the
///         security is in the latch condition + the reduce-only / risk-reducing
///         nature of each leg, NOT the caller. Every crank entry first runs the
///         shared {_gate} (latch armed + per-interval cooldown + nonReentrant lives
///         on the vault wrapper). The events and errors below MIRROR
///         {IHyperCoreVault} / {VaultTradeLib} with identical signatures, so logs
///         (topic0) and revert selectors are indistinguishable from the emergency
///         path across the delegatecall boundary — the flatten crank reuses the
///         SAME reduce-only IOC + bug_009 size scaling + M4 markPx band logic as
///         {VaultTradeLib.emergencyClose}, with the band FORCED mandatory. The only
///         vault state mutated here is the escape latch/cooldown struct (threaded by
///         reference) and the cloid (returned for the vault to persist).
library VaultEscapeLib {
    /// @dev Minimum seconds between escape cranks (M5 §4). A compile-time constant
    ///      (matches {HyperCoreVault.escapeCrankInterval}, which surfaces it on the
    ///      ABI) so the vault need not thread it into every crank call — keeps the
    ///      delegatecall arg-marshaling (and thus the vault's EIP-170 footprint)
    ///      minimal. See the vault's NatSpec for why the cooldown is fixed, not tunable.
    uint64 internal constant CRANK_INTERVAL = 60;

    /// @dev Compile-time hard bounds for the permissionless-trigger grace window (M5
    ///      §1, SOLU-3371), the canonical source the vault's {setEscapeGraceSeconds}
    ///      enforces. Constants so a compromised timelock can neither DISABLE the brake
    ///      (grace absurdly long) nor make it HAIR-TRIGGER (grace ~0) — §1/§8.
    ///      DECISION PENDING: final floor + permissionless-vs-permissioned posture await
    ///      Chief Scientist sign-off; 4h is the interim conservative floor.
    uint64 internal constant ESCAPE_GRACE_MIN = 4 hours; // 14_400s
    uint64 internal constant ESCAPE_GRACE_MAX = 30 days; // 2_592_000s

    /// @dev Mirrors {IHyperCoreVault.LimitOrderSubmitted} / {VaultTradeLib} so the
    ///      flatten crank's CoreWriter submit is logged identically to the emergency
    ///      and trade paths.
    event LimitOrderSubmitted(
        uint32 indexed asset,
        bool isBuy,
        uint64 limitPx,
        uint64 sz,
        bool reduceOnly,
        uint8 tif,
        uint128 indexed cloid,
        uint256 navSnapshot
    );

    /// @notice Mirror {IHyperCoreVault} escape events so they are emitted identically
    ///         across the delegatecall boundary.
    event EscapeActivated(address indexed by, address indexed lp);
    event EscapeDeactivated(address indexed by);
    event EscapeCrankRun(address indexed by, uint8 indexed leg);
    /// @notice Mirror {IHyperCoreVault} — admin retuned the permissionless-trigger
    ///         grace window (SOLU-3371), emitted identically across the delegatecall.
    event EscapeGraceSecondsUpdated(uint64 newGrace);
    /// @notice A leg-1 cancel (mirrors {IHyperCoreVault.OrderCancelByCloidSubmitted}).
    event OrderCancelByCloidSubmitted(uint32 indexed asset, uint128 indexed cloid);
    /// @notice A leg-3 perp->spot move (mirrors {IHyperCoreVault.UsdClassTransferSubmitted}).
    event UsdClassTransferSubmitted(uint64 ntl, bool toPerp);
    /// @notice A leg-4a Core spot USDC -> EVM idle pull (mirrors
    ///         {IHyperCoreVault.BridgeWithdraw} / {VaultEmergencyLib.BridgeWithdraw}), so
    ///         the escape pull is logged byte-identically to {HyperCoreVault.pullFromCore}.
    event BridgeWithdraw(uint64 amountWei);

    /// @notice Mirrors {VaultTradeLib.EmergencyCloseBandExceeded}: a flatten
    ///         `limitPx` deviates from the strict markPx beyond the mandatory band.
    error EmergencyCloseBandExceeded(uint64 limitPx, uint64 markPx, uint16 bandBps);
    /// @notice Audit M-1: a permissionless flatten tried to place a close order while
    ///         `emergencyCloseBandBps == 0`. The band is MANDATORY on the escape path — a
    ///         band-free close stays EMERGENCY_ROLE-only. Mirrors {IHyperCoreVault}.
    error EmergencyCloseBandRequired();
    /// @notice A supplied cloid is not one the vault has issued (>= the live
    ///         `_cloidCounter`), so it cannot name a vault-placed resting order (§2 leg 1).
    error EscapeCloidOutOfRange(uint128 cloid, uint128 cloidCounter);
    /// @notice Mirror {IHyperCoreVault} — a crank ran while not latched (§4).
    error EscapeModeNotActive();
    /// @notice Mirror {IHyperCoreVault} — a crank ran before the cooldown elapsed (§4).
    error EscapeCooldownActive(uint64 nextAllowedTs);
    /// @notice Mirror {IHyperCoreVault} — {exitEscape} found a still-blocking request (§1).
    error EscapeBacklogRemains(address lp);
    /// @notice Mirror {IHyperCoreVault} — {triggerEscape}'s permissionless staleness
    ///         gate was not met for `lp` (SOLU-3371). Re-declared so the revert
    ///         selector is identical across the delegatecall boundary.
    error EscapeConditionNotMet(address lp);
    /// @notice Mirror {IHyperCoreVault} — {setEscapeGraceSeconds} got an out-of-bounds
    ///         value (SOLU-3371). Re-declared for selector identity across delegatecall.
    error EscapeGraceOutOfRange(uint64 lo, uint64 hi);

    // -------------------------------------------------------------------------
    // Latch entry / exit (§1) — operate on the vault's escape state by reference
    // -------------------------------------------------------------------------

    /// @notice Arm the brake — vault enters ESCAPE mode (M5 §1). Idempotent (no
    ///         spurious event on a re-arm). The vault threads its {EscapeState} in by
    ///         storage reference; this writes `s.active` in the vault's storage.
    function activate(IHyperCoreVault.EscapeState storage s, address lp) external {
        if (s.active) return;
        s.active = true;
        emit EscapeActivated(msg.sender, lp);
    }

    /// @dev Audit H-1: the SINGLE overdue-unfillable predicate used by BOTH
    ///      {triggerIfStale} (to ARM) and {exit} (to HOLD) — making them exactly
    ///      symmetric (the prior {exit} omitted the grace, an asymmetry vs the
    ///      grace-stacked arm). True iff `req` has an SLA deadline, is overdue by AT
    ///      LEAST `grace` beyond it, AND its remaining claim still exceeds `availableIdle`.
    ///      `previewRedeem` is a view self-call (`address(this)` is the vault under
    ///      delegatecall). A zero-share `req` (e.g. the `address(0)` anchor) returns false.
    function _overdueUnfillable(
        IHyperCoreVault.WithdrawalRequest storage req,
        uint256 availableIdle,
        uint64 grace
    ) private view returns (bool) {
        uint256 shares = req.shares;
        if (shares == 0) return false;
        uint64 deadline = req.fulfillmentDeadline;
        // deadline==0 (no SLA) can never be overdue. Adding grace cannot overflow uint64
        // (deadline is a unix ts, grace <= ESCAPE_GRACE_MAX == 30d) — widen to uint256.
        if (deadline == 0 || block.timestamp <= uint256(deadline) + grace) return false;
        return IERC4626(address(this)).previewRedeem(shares) > availableIdle;
    }

    /// @notice PERMISSIONLESS staleness trigger (M5 §1, SOLU-3371) — arm the brake on
    ///         `lp` iff its request is OVERDUE-UNFILLABLE by the grace-stacked gate.
    ///         This is the EXACT SYMMETRIC counterpart to {exit}: the same
    ///         "overdue + claim>availableIdle" predicate that holds the brake also
    ///         arms it, but here the overdue test STACKS `grace` on top of the SLA
    ///         deadline (escape composes with, never preempts, the normal H2 priority
    ///         flow — §1). Idempotent re-arm via {activate}.
    /// @dev    Lives in the library (not the vault wrapper) to keep the vault inside
    ///         its 24576-byte EIP-170 budget (audit G2; ~312 B headroom). Reads the
    ///         vault's `_pendingWithdrawal` by storage reference and its own
    ///         `previewRedeem` via self-call (`address(this)` is the vault under
    ///         delegatecall — identical to {exit}); `availableIdle` is the vault's
    ///         `_availableIdle()`. The two-part condition (§1):
    ///           (a) `req.fulfillmentDeadline != 0 && now > deadline + grace`, AND
    ///           (b) `previewRedeem(req.shares) > availableIdle`.
    ///         EDGE CASE (§8 Q1): a request with `fulfillmentDeadline == 0` (the vault
    ///         has no {requestFulfillmentWindow}) can never be overdue, so it can never
    ///         arm the brake — a vault with no SLA window has NO permissionless brake
    ///         (the admin must set a window). Fail-closed: any unmet leg reverts
    ///         {EscapeConditionNotMet} rather than silently no-op'ing.
    function triggerIfStale(
        IHyperCoreVault.EscapeState storage s,
        address lp,
        mapping(address => IHyperCoreVault.WithdrawalRequest) storage pendingWithdrawal,
        uint256 availableIdle
    ) external {
        // Fail-closed via the shared predicate: any unmet leg reverts, never a silent no-op.
        if (!_overdueUnfillable(pendingWithdrawal[lp], availableIdle, s.graceSeconds)) {
            revert EscapeConditionNotMet(lp);
        }
        // Idempotent re-arm: while already armed, DO NOT touch `armedFor`. Security-critical
        // (audit H-1): during escape availableIdle≈0 so even a dust request is
        // "overdue-unfillable", and re-pointing the anchor onto an attacker-controlled
        // request would let them resolve it and clear a live brake.
        if (s.active) return;
        s.active = true;
        s.armedFor = lp; // audit H-1: anchor set ONLY on the inactive->active transition
        emit EscapeActivated(msg.sender, lp);
    }

    /// @notice Governance setter body for {HyperCoreVault.setEscapeGraceSeconds} (M5
    ///         §1, SOLU-3371). REVERTS {EscapeGraceOutOfRange} outside [{ESCAPE_GRACE_MIN},
    ///         {ESCAPE_GRACE_MAX}] = [4h, 30d] — fail-closed, NOT a silent clamp, so
    ///         governance cannot quietly set a bad value. Writes the vault's
    ///         `escapeGraceSeconds` by storage reference + emits {EscapeGraceSecondsUpdated}.
    /// @dev    Lives here (vault wrapper is one line) for the same EIP-170 reason as the
    ///         cranks; the access-control gate stays on the vault wrapper. The grace is
    ///         held in {IHyperCoreVault.EscapeState} (threaded by storage reference), so
    ///         this writes `s.graceSeconds` directly. The bounds are the library
    ///         constants — the single source of truth.
    function setGrace(IHyperCoreVault.EscapeState storage s, uint64 newGrace) external {
        if (newGrace < ESCAPE_GRACE_MIN || newGrace > ESCAPE_GRACE_MAX) {
            revert EscapeGraceOutOfRange(ESCAPE_GRACE_MIN, ESCAPE_GRACE_MAX);
        }
        s.graceSeconds = newGrace;
        emit EscapeGraceSecondsUpdated(newGrace);
    }

    /// @notice Permissionlessly clear the brake (M5 §1) — succeeds ONLY when the request
    ///         that ARMED the brake ({EscapeState.armedFor}) is no longer overdue-unfillable
    ///         (funded to honorable, fulfilled, or cancelled). Permissionless + pause-immune.
    /// @dev    Audit H-1: the hold decision is re-derived from the STORED `armedFor` anchor,
    ///         NOT the caller-supplied `lps`. The `lps` array is retained in the ABI for
    ///         backward compatibility but is IGNORED — otherwise `exitEscape([])` or
    ///         `exitEscape([nonBlocker])` would clear a live brake (the caller could
    ///         volunteer an empty/irrelevant set). Uses the same {_overdueUnfillable}
    ///         predicate as {triggerIfStale} (reads `_pendingWithdrawal` by storage
    ///         reference + `previewRedeem` self-call). `armedFor == address(0)` (armed with
    ///         no anchor) ⇒ zero-share lookup ⇒ clears. If the anchor resolves while a
    ///         DIFFERENT request still qualifies, the brake clears and anyone re-arms
    ///         permissionlessly via {triggerIfStale} (cranks are cooldown-gated, so the
    ///         one-tx gap is immaterial).
    function exit(
        IHyperCoreVault.EscapeState storage s,
        address[] calldata, /* lps: ignored (audit H-1) — kept for ABI compatibility */
        mapping(address => IHyperCoreVault.WithdrawalRequest) storage pendingWithdrawal,
        uint256 availableIdle
    ) external {
        if (!s.active) return;
        if (_overdueUnfillable(pendingWithdrawal[s.armedFor], availableIdle, s.graceSeconds)) {
            revert EscapeBacklogRemains(s.armedFor);
        }
        s.active = false;
        s.armedFor = address(0);
        emit EscapeDeactivated(msg.sender);
    }

    /// @dev Shared crank gate (M5 §4): require the latch is armed, enforce the
    ///      per-interval cooldown, and stamp the timestamp — all on the vault's
    ///      {EscapeState} by reference. `nonReentrant` + pause-immunity live on the
    ///      vault wrapper. The first crank after arming runs immediately
    ///      (`lastCrankTs == 0`, so `last + interval` <= now).
    function _gate(IHyperCoreVault.EscapeState storage s) private {
        if (!s.active) revert EscapeModeNotActive();
        uint64 nowTs = uint64(block.timestamp);
        uint64 nextAllowed = s.lastCrankTs + CRANK_INTERVAL;
        if (s.lastCrankTs != 0 && nowTs < nextAllowed) revert EscapeCooldownActive(nextAllowed);
        s.lastCrankTs = nowTs;
    }

    // -------------------------------------------------------------------------
    // Leg 1 — cancel resting orders (§2 leg 1)
    // -------------------------------------------------------------------------

    /// @notice Permissionlessly cancel the vault's resting orders on `asset` by
    ///         client order id while latched. Each cloid is validated against the
    ///         vault's monotonic `_cloidCounter` (passed in) so only vault-issued ids
    ///         can be cancelled; cancels are strictly risk-reducing, so the crank is
    ///         safe to spam.
    /// @dev    `cloidCounter` is the vault's NEXT free cloid: every issued id is
    ///         `< cloidCounter` (counter starts at 1, post-incremented per placement),
    ///         so `cloid >= cloidCounter` cannot name a real order. CoreWriter is
    ///         fire-and-forget — a cancel for an already-gone order is a Core no-op.
    function escapeCancelOrders(
        IHyperCoreVault.EscapeState storage s,
        uint32 asset,
        uint128[] calldata cloids,
        uint128 cloidCounter
    ) external {
        _gate(s);
        for (uint256 i; i < cloids.length; ++i) {
            uint128 c = cloids[i];
            if (c >= cloidCounter) revert EscapeCloidOutOfRange(c, cloidCounter);
            CoreWriterLib.cancelOrderByCloid(asset, c);
            emit OrderCancelByCloidSubmitted(asset, c);
        }
        emit EscapeCrankRun(msg.sender, 1);
    }

    // -------------------------------------------------------------------------
    // Leg 2 — flatten perps (§2 leg 2)
    // -------------------------------------------------------------------------

    /// @notice Flatten open perp positions via opposite-side reduce-only IOC orders
    ///         while latched — the escape-mode twin of {VaultTradeLib.emergencyClose},
    ///         with the M4 markPx band FORCED mandatory.
    /// @dev    Reuses the emergency-close internals verbatim in spirit (reduce-only
    ///         IOC, bug_009 size scaling, M4 markPx band). The caller supplies
    ///         `limitPxs`, but each is bounded against the strict markPx within the
    ///         mandatory `band` (supplied by the vault from `emergencyCloseBandBps`) —
    ///         there is NO band-free escape variant (a band-free force close stays
    ///         EMERGENCY_ROLE, §5). Reduce-only means spamming cannot create exposure.
    ///         Issues cloids from `startCloid`, returns the next free cloid for the
    ///         vault to persist. The event's `nav` snapshot is the vault's own
    ///         {totalAssets} read via self-call (`address(this)` is the vault under
    ///         delegatecall) — constant across the loop since a CoreWriter submit does
    ///         not settle synchronously, so it equals the inlined value while sparing
    ///         the vault a `totalAssets()` arg to marshal.
    function escapeFlattenPerps(
        IHyperCoreVault.EscapeState storage s,
        uint32[] calldata perpAssets,
        uint64[] calldata limitPxs,
        uint16 band,
        uint128 startCloid
    ) external returns (uint128 nextCloid) {
        _gate(s);
        require(perpAssets.length == limitPxs.length, "len");
        uint256 nav = IERC4626(address(this)).totalAssets();
        nextCloid = startCloid;
        for (uint256 i; i < perpAssets.length; ++i) {
            // Per-position work lives in a helper so the loop's live-variable set
            // stays within the EVM stack limit (avoids a project-wide via-IR build),
            // mirroring {VaultTradeLib._closeOnePosition}.
            if (_flattenOnePosition(perpAssets[i], limitPxs[i], band, nextCloid, nav)) {
                nextCloid++;
            }
        }
        emit EscapeCrankRun(msg.sender, 2);
    }

    /// @dev Flatten one perp position with an opposite-side reduce-only IOC. The band
    ///      is ALWAYS enforced on the escape path (no `enforceBand` toggle). Returns
    ///      true when an order was placed (a cloid was consumed), false when the
    ///      position was flat. Byte-for-byte the same math as
    ///      {VaultTradeLib._closeOnePosition} (bug_009 scale; M4 band; L3 widen).
    function _flattenOnePosition(uint32 a, uint64 limitPx, uint16 band, uint128 cloid, uint256 nav)
        private
        returns (bool placed)
    {
        // Ultrareview bug_007: lenient position read — the loop spans ALL whitelisted
        // perps and HyperCore reverts/returns empty for a flat perp. A held perp
        // skipped by a transient lenient read is retried on the next crank (CoreWriter
        // is fire-and-forget; convergent across cranks — §5).
        int64 szi = PrecompileLib.position(address(this), a).szi;
        if (szi == 0) return false;
        // Audit L3: widen through int256 so `-szi` cannot overflow at int64.min.
        uint64 absSz = uint64(szi < 0 ? uint256(-int256(szi)) : uint256(int256(szi)));
        uint8 szDec = PrecompileLib.perpAssetInfoStrict(a).szDecimals;

        // Audit M4 + M-1: the band is TRULY MANDATORY on the permissionless escape path.
        // A HELD position (szi != 0, checked above) can only be flattened WITH a configured
        // band — before, `band == 0` silently SKIPPED this check and let a permissionless
        // caller push an off-market IOC (value bleed on a thin book). A band-free close now
        // stays EMERGENCY_ROLE-only ({emergencyClosePositionsForce}). markPxStrict reverting
        // (oracle outage) fails the crank closed — retryable, never a band-free force.
        if (band == 0) revert EmergencyCloseBandRequired();
        {
            uint64 markRaw = PrecompileLib.markPxStrict(a);
            uint256 markNorm = uint256(markRaw) * (10 ** (uint256(szDec) + 2));
            uint256 lpx = uint256(limitPx);
            uint256 diff = lpx > markNorm ? lpx - markNorm : markNorm - lpx;
            if (diff > (markNorm * band) / Constants.BPS) {
                revert EmergencyCloseBandExceeded(limitPx, markRaw, band);
            }
        }

        // bug_009: rescale szDecimals lots -> uniform 10^8 action size.
        uint64 sz = uint64(uint256(absSz) * (10 ** (8 - szDec)));
        bool isBuy = szi < 0; // close: sell if currently long, buy if currently short
        CoreWriterLib.placeLimitOrder(a, isBuy, limitPx, sz, true, Constants.TIF_IOC, cloid);
        emit LimitOrderSubmitted(a, isBuy, limitPx, sz, true, Constants.TIF_IOC, cloid, nav);
        return true;
    }

    // -------------------------------------------------------------------------
    // Leg 3 — consolidate perp equity to Core spot (§2 leg 3)
    // -------------------------------------------------------------------------

    /// @notice Move the vault's entire perp `withdrawable` equity to Core spot via
    ///         `usd_class_transfer` (perp -> spot) while latched. Strictly
    ///         risk-reducing; the amount is read ON-CHAIN from the conservative
    ///         `withdrawable` figure (caller supplies nothing), so it cannot move
    ///         more than the perp account can free.
    /// @dev    Reads `withdrawable` lenient/strict per `navBootstrap`, mirroring
    ///         {HyperCoreVault.perpWithdrawable} — a strict read fails the crank
    ///         closed on a precompile outage rather than silently moving zero. After
    ///         legs 1-3 the vault is flat with all value as Core spot USDC, fully
    ///         counted by {HyperCoreVault.coreSpotUsdc} (§2). No-ops the CoreWriter
    ///         call (but still runs the gate + crank event) when nothing is withdrawable.
    function escapeConsolidateToSpot(IHyperCoreVault.EscapeState storage s, bool navBootstrap)
        external
        returns (uint64 movedNtl)
    {
        _gate(s);
        movedNtl = navBootstrap
            ? PrecompileLib.withdrawable(address(this)).withdrawable
            : PrecompileLib.withdrawableStrict(address(this)).withdrawable;
        if (movedNtl != 0) {
            CoreWriterLib.usdClassTransfer(movedNtl, false); // perp -> spot
            emit UsdClassTransferSubmitted(movedNtl, false);
        }
        emit EscapeCrankRun(msg.sender, 3);
    }

    // -------------------------------------------------------------------------
    // Shared USD class-transfer primitive (used by {HyperCoreVault.usdSpotToPerp} /
    // {usdPerpToSpot}). Externalized here (delegatecall) so the vault no longer inlines
    // the CoreWriter `usd_class_transfer` encode + the emit on those movers, reclaiming
    // EIP-170 budget for leg 4a (SOLU-3370). The access-control gate, `whenNotPaused`
    // posture, `nonReentrant`, and the M5 ESCAPE-mode check stay on the vault wrappers;
    // the {UsdClassTransferSubmitted} log is byte-identical across the boundary.
    // -------------------------------------------------------------------------

    /// @notice Move USD between Core spot and perp margin classes (`toPerp`: spot->perp
    ///         when true, perp->spot when false) and emit {UsdClassTransferSubmitted}.
    function usdClassTransfer(uint64 ntl, bool toPerp) external {
        CoreWriterLib.usdClassTransfer(ntl, toPerp);
        emit UsdClassTransferSubmitted(ntl, toPerp);
    }

    /// @notice Cancel a single resting order by client order id and emit
    ///         {OrderCancelByCloidSubmitted}. Body of {HyperCoreVault.cancelOrderByCloid}
    ///         (the OPERATOR cancel), externalized here (delegatecall) for the same
    ///         EIP-170 reason — the role gate + `nonReentrant` stay on the vault wrapper
    ///         and the log is byte-identical. (Distinct from leg 1's permissionless,
    ///         latch-gated, cloid-validated {escapeCancelOrders} loop.)
    function cancelOrderByCloid(uint32 asset, uint128 cloid) external {
        CoreWriterLib.cancelOrderByCloid(asset, cloid);
        emit OrderCancelByCloidSubmitted(asset, cloid);
    }

    // -------------------------------------------------------------------------
    // Leg 4a — pull Core spot USDC back to EVM idle (§2 leg 4, §3 option 4a, §7 Phase 2)
    // -------------------------------------------------------------------------

    /// @dev Fee-aware send numerator/denominator (PULL_FEE_NUM/PULL_FEE_DEN =
    ///      998/1000 = 99.8%). A Core->EVM withdrawal takes a ~0.00134 USDC fee FROM
    ///      Core on TOP of the requested amount, so requesting the EXACT full balance
    ///      is silently DROPPED (the fee cannot be covered) — proven live in the G2
    ///      spike (2026-06-15/16). Sending `balance * 998 / 1000` leaves a 0.2% cushion
    ///      that dwarfs the fixed fee for any non-trivial balance and rounds DOWN toward
    ///      zero for dust (so the send can never exceed the balance). This mirrors the
    ///      keeper's `balance * 0.998` and {HyperCoreVault.pullFromCore}'s documented
    ///      "pull under the full balance". (NB: a dedicated 998/1000 — NOT
    ///      {Constants.BPS}'s 1/10_000 scale — so the cushion is 0.2%, not 9.98%.)
    uint64 internal constant PULL_FEE_NUM = 998;
    uint64 internal constant PULL_FEE_DEN = 1000;

    /// @notice PERMISSIONLESS, escape-gated, CHUNKED pull of the vault's Core spot USDC
    ///         back to EVM idle while latched (M5 §2 leg 4 / §3 option 4a / §7 Phase 2,
    ///         SOLU-3370) — the escape-mode twin of {HyperCoreVault.pullFromCore},
    ///         re-targeting funds toward LP redeemability. Moves Core USDC toward idle
    ///         (no new market risk), so it belongs to the pull family the H2 design
    ///         keeps UNBLOCKED during escape; the only gate is the latch + cooldown.
    /// @dev    Repatriation crank (anyone can run it; keepers/LPs spam it). The Core
    ///         balance is read ON-CHAIN (caller supplies nothing but the chunk cap), so
    ///         the crank can never move more than the vault actually holds on Core:
    ///           1. {_gate} — latch armed + the per-interval cooldown ({CRANK_INTERVAL});
    ///              this IS the required cooldown that spaces successive chunks.
    ///           2. read the vault's Core USDC spot balance (8dp Core wei), lenient/strict
    ///              per `navBootstrap`, mirroring {HyperCoreVault.coreSpotUsdc} — a strict
    ///              read fails the crank CLOSED on a precompile outage (never pulls 0).
    ///           3. FEE-AWARE: take `balance * PULL_FEE_NUM / PULL_FEE_DEN` (= 99.8%),
    ///              never the exact full balance (the ~0.00134 USDC withdrawal fee would
    ///              drop an exact-full send — G2 spike). See {PULL_FEE_NUM}.
    ///           4. CHUNK: bound the send to `maxChunkWei` (caller-supplied) so a large
    ///              balance is repatriated in bounded chunks across cooldown-spaced
    ///              cranks. The send amount = `min(feeAwareAmount, maxChunkWei)`.
    ///         The send is a `send_asset` (action 13, spot->spot) to the USDC system
    ///         address — byte-identical to {VaultEmergencyLib.pullFromCore}; the
    ///         legacy `spot_send` (action 6) is silently dropped for unified accounts
    ///         (audit G2). HyperCore debits the vault's Core spot and the linked
    ///         CoreDepositWallet pays native USDC to the caller (this vault, under
    ///         delegatecall — `address(this)` is the vault) at amount/100 (8dp Core ->
    ///         6dp EVM). {fulfillWithdraw} (already permissionless) then drains the LP
    ///         queue as the pulled idle lands. No-ops the send (but still runs the gate
    ///         + emits the crank event) when the fee-aware/chunked amount is zero (dust
    ///         or empty balance), exactly like leg 3's zero-withdrawable branch. NOT
    ///         NAV-mutating (Core->EVM is NAV-neutral — both legs count in
    ///         {totalAssets}), so — like {pullFromCore} and unlike leg 3 — no mgmt-fee
    ///         accrual is needed.
    /// @param  s             The vault's escape latch/cooldown state (by reference).
    /// @param  coreUsdcIndex The vault's immutable Core USDC token index (by value).
    /// @param  navBootstrap  The vault's NAV-read mode (lenient while bootstrapping).
    /// @param  maxChunkWei   Per-crank send cap in Core wei (8dp); bounds the chunk.
    function escapePullToEvm(
        IHyperCoreVault.EscapeState storage s,
        uint64 coreUsdcIndex,
        bool navBootstrap,
        uint64 maxChunkWei
    ) external {
        _gate(s);
        // Audit H-1: lenient/strict per navBootstrap, mirroring {coreSpotUsdc}. A strict
        // read fails the crank closed on a precompile outage rather than pulling zero.
        uint64 balance = navBootstrap
            ? PrecompileLib.spotBalance(address(this), coreUsdcIndex).total
            : PrecompileLib.spotBalanceStrict(address(this), coreUsdcIndex).total;
        // Fee-aware (never the exact full balance) then chunk-capped. Widen to uint256
        // for the multiply (balance and PULL_FEE_NUM are uint64; the product can exceed
        // uint64); the quotient <= balance <= uint64.max, so the cast back is safe.
        uint64 amount = uint64((uint256(balance) * PULL_FEE_NUM) / PULL_FEE_DEN);
        if (amount > maxChunkWei) amount = maxChunkWei;
        if (amount != 0) {
            // send_asset (action 13) to the USDC system address — verbatim
            // {VaultEmergencyLib.pullFromCore}; spot->spot, 8dp.
            CoreWriterLib.sendAsset(
                SystemAddress.forToken(coreUsdcIndex),
                Constants.CORE_SPOT_DEX_ID,
                Constants.CORE_SPOT_DEX_ID,
                coreUsdcIndex,
                amount
            );
            emit BridgeWithdraw(amount);
        }
        emit EscapeCrankRun(msg.sender, 4);
    }
}
