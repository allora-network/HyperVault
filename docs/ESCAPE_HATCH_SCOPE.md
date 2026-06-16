# Permissionless escape hatch ("dead man's brake"): scoping

Status: scope only, nothing built. 2026-06-11; leg 4 revised 2026-06-12 after the CoreDepositWallet discovery (see `docs/EXECUTIVE_OVERVIEW.md` section 7 and the research notes in chat).

Closes the residual from `REDEMPTION_ASSESSMENT.md` Finding B (no permissionless escape; only the operator can repatriate). Goal: if redemption requests go unhonored for N days (proposal: 7), anyone can force the vault to flatten all positions and route funds back toward withdrawable idle, without the operator, without the emergency key, and without trusting the ops treasury.

## 1. What "stale" means on-chain (the trigger)

The contract already has the raw material: per-request `fulfillmentDeadline` stamped by `requestFulfillmentWindow` (HyperCoreVault.sol:117, :1051), `requestIsOverdue(lp)` (:599), and permissionless `prioritizeOverdue` (:1083) and `fulfillWithdraw` (:1104).

Proposed trigger, evaluated in `triggerEscape(address lp)`:

- the request exists and is overdue by at least `escapeGraceSeconds` beyond its SLA deadline (so escape composes with, and never preempts, the normal H2 priority flow), AND
- the request's remaining claim exceeds `availableIdleUsdc()` at trigger time (an honored or honorable request can never arm the brake).

Anti-grief notes. Restricting the caller to "an LP with an overdue request" adds nothing: anyone can deposit dust, request 1 share, and wait, so the security lives in the condition, not the caller. The unfillability check is the real gate: with a sane idle-buffer policy, a dust claim is only unfillable when idle is ~zero, which is itself a true emergency signal. Optional extra knob: require total escrowed pending shares (trivially trackable at request/cancel/fulfill) to exceed an admin-set floor. Parameters get hard code bounds (e.g. `escapeGraceSeconds` clamped to [3 days, 30 days]) so the timelock cannot quietly disable the brake.

Arming the brake latches `escapeActive = true` and the vault enters ESCAPE mode until no overdue-unfillable request remains (checked on every crank; `exitEscape()` for the explicit clear).

## 2. The four legs, and which are trustless today

| Leg | Action | Trustless today? | Mechanics |
|---|---|---|---|
| 1 | Cancel resting orders | YES | cloids are vault-assigned from a monotonic counter (:92), so `escapeCancelOrders(asset, cloids[])` can validate `cloid < _cloidCounter` and cancel permissionlessly. Cancels are strictly risk-reducing. |
| 2 | Flatten all perp positions | YES | Reuse the `emergencyClosePositions` internals exactly (reduce-only IOC, bug_009 size scaling at :839-862, M4 markPx band at :848-860), with the band MANDATORY and the limit price derived on-chain from `markPxStrict` (caller supplies nothing price-shaped). Reduce-only means spamming it cannot create exposure. CoreWriter is fire-and-forget, so the crank is repeatable until `position().szi == 0` across `_whitelistedPerps` (:1254 loop). |
| 3 | Consolidate perp equity to Core spot | YES | Permissionless variant of `usdPerpToSpot` (:760), amount read from `withdrawable`. Already pause-immune by design; strictly risk-reducing. |
| 4 | Core spot USDC back to EVM idle | YES (revised 2026-06-12) | Core USDC's declared EVM contract (0x6b9e...0a24) turned out to be Circle's CoreDepositWallet, the official USDC bridge live since 2025-12-08. Core-side send of USDC to the system address 0x2000...0000 triggers the wallet's system-guarded `transfer(to, amount)`, paying native USDC (0xb883...630f) from its ~$4.9B reserve to the sender's EVM address. That Core-side send is what `pullFromCore` (:699) already emits. Options below. |

After legs 1-3 the vault is flat: zero market risk, all value sitting as Core spot USDC, fully counted by NAV (`coreSpotUsdc` :525). What remains is purely the crossing.

## 3. Leg 4 options (revised 2026-06-12)

**4a. Official route via Circle's CoreDepositWallet (the recommendation).** Leg 4 is a permissionless escape variant of the existing `pullFromCore` (:699): Core-side send of USDC (token 0) to the system address; the CoreDepositWallet pays native USDC to the vault's EVM address; `fulfillWithdraw`, already permissionless, drains the queue as idle lands. Verified 2026-06-12: wallet live and unpaused, `token()` equals the vault's configured asset, `tokenSystemAddress` equals `SystemAddress.usdc()`, and the payout function is guarded to the system address. **GATE SATISFIED — proven live 2026-06-15/16** (round trip on a throwaway vault; tx hashes in `docs/FORK_PROOFS.md` "v1.5 G2 — live spike"). Two corrections the spike forced and the escape variant MUST inherit: (1) the Core-side action is CoreWriter **`send_asset` (action 13)**, not `spot_send` (action 6) — unified accounts silently drop `spot_send`; (2) a ~0.00134 USDC withdrawal fee is taken on top of the amount, so the escape crank must pull **under** the Core balance (requesting the exact full balance is dropped). Both are already baked into `pullFromCore`.

**4b. USDT0 conversion fallback (defense in depth, optional).** The CoreDepositWallet is Circle-operated, upgradeable, and pausable, so a paused or changed wallet would re-block leg 4a. The previously scoped USDT0 route stays viable as a fallback: buy USDT0 with Core USDC on spot pair @166 (mid 0.99907, ~0.5bp spread, ~$1M/day volume as of 2026-06-11) via the whitelisted-spot order path with its M6 band (:646-663), `spotSend` USDT0 (token 268, working standard linkage to 0xB8CE...5ebb) to its system address, then swap back to USDC on a HyperEVM DEX through an admin-allowlisted router. Requires generalizing `pullFromCore` to arbitrary linked tokens plus the router adapter (the only new external surface). Ship only if the trust budget demands a Circle-independent path.

**4c. Treasury hop (rejected as terminal state).** Permissionless `spotSend` to the timelock-allowlisted `spotRecoverDest` (:972). If ops is dark, funds stranded at the treasury are worse than funds flat on Core under vault control. Keep only as a manual emergency tool.

## 4. ESCAPE mode semantics

While latched:

- Blocked: `placeLimitOrder` except reduce-only flatten cranks, `pushToCore`, `usdSpotToPerp`, `deposit`/`mint` (maxDeposit returns 0; entering a forced unwind is wrong-way risk for the depositor).
- Unblocked and unaffected: all redemption paths, `pullFromCore`-family, `fulfillWithdraw`, `prioritizeOverdue`, emergency functions.
- Pause-immunity: every escape function follows the H2 pattern (no `whenNotPaused`). Neither the operator, nor the emergency key, nor the admin can veto an armed brake; the only exit is clearing the overdue backlog.
- Cranks carry a per-interval cooldown and `nonReentrant`; mgmt-fee accrual runs as usual; perf fee is untouched (charged at exits against per-LP basis, as today).

## 5. Threat model for the new surface

- Forced-unwind griefing: attacker arms the brake during a transient ops stall and the book gets flattened at IOC. Bounded by: the grace window (days, not hours), the unfillability condition, the mandatory markPx band on closes, and the M6 band + chunk caps on the @166 conversion. Residual cost of a malicious-but-successful trigger is bands+spread, not a fire sale.
- Counterparty positioning: closes are at band-bounded IOC against the live book; an attacker pre-positioned on the other side earns at most the band. Tune band tight enough to cap loss, wide enough to fill (proposal: perp close band 100-300bp reusing `emergencyCloseBandBps`, spot band 30-50bp).
- Oracle/precompile outage: `markPxStrict` reverting blocks flatten cranks (fail-closed, retryable). The brake never gets a band-free force variant; that stays EMERGENCY_ROLE (`emergencyClosePositionsForce`).
- Stale-position reads: the lenient `position()` read (bug_007) can skip a held perp in one crank; the next crank retries. Document as best-effort-per-crank, convergent across cranks.
- HyperCore action rate limits on the vault address: verify live; cooldowns should keep cranks far under any limit.

## 6. Accounting and fairness effects

Flatten+consolidate realizes the conservative NAV (margin unlocks, `perpWithdrawable` converges to actual equity), so PPS typically ticks UP during escape; queued LPs' fee snapshots were taken at request time (:1054), so the H2/M1/M2 fairness machinery needs no changes. Conversion slippage and fees are socialized pro-rata through NAV, which is the correct emergency semantics. No caller incentive payment initially (LPs are self-interested; an incentive is new attack surface).

## 7. Phasing recommendation

- **Phase 1 (high value, no new dependencies): legs 1-3 + ESCAPE latch.** Removes "operator holds positions hostage" trust entirely. Worst case under dark ops: funds flat and safe on Core, zero market risk, recoverable by the (distinct) emergency key via the existing allowlisted route. ~120-180 lines in the vault reusing emergency-close internals, fully fork-testable (trigger, latch, reduce-only enforcement, mode gating) plus one cheap live check for IOC fill behavior.
- **Phase 2 (full trustlessness): leg 4a.** Now small: a permissionless, escape-gated variant of `pullFromCore` (the Core-side system-address send already exists) plus chunking and cooldowns, landing alongside the CoreDepositWallet integration of normal capital routing. The brake becomes a permissionless forced run of the standard keeper path under staleness conditions. Gate on the funded round-trip spike.
- **Phase 3 (optional, Circle-independent): leg 4b** USDT0 fallback, only if the trust budget requires surviving a paused/upgraded CoreDepositWallet. Decide after the Discord/HL answer on the wallet's long-term status.

## 8. Open questions

1. `escapeGraceSeconds` value (proposal 7 days, code-clamped [3d, 30d]) and whether it stacks on top of `requestFulfillmentWindow` or replaces it when the window is unset (proposal: if window = 0, escape uses request age alone).
2. Minimum-claim threshold: ship the optional floor, or rely purely on unfillability?
3. Should ESCAPE block deposits (proposed yes) given idle inflow would actually help exits? Simplicity and wrong-way-risk argue yes.
4. HyperCore rate limits and IOC fill behavior for contract-originated closes under stress: live-verify.
5. Prior art note: Lighter ships a protocol-level 14-day "Desert" escape; HyperCore has no native equivalent, which is why this lives at the vault layer via CoreWriter.
