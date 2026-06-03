# Redemption & Production-Readiness Assessment

**Vault:** `src/HyperCoreVault.sol` (v1.3) · **Branch:** `audit/mitigations` · **Date:** 2026-06-02

**Scope of review:** the vault + libraries, the deploy configs (`deployments/configs/*`), the Python live harness (`scripts/python/e2e_runner.py`), and the integration/security docs. The trigger was a strategy-engineer question about how redemptions work when capital is deployed on Core.

> **Verification basis.** Every claim about *contract* behaviour below is read directly from the source (line refs given) — that is proof of what the bytecode does. Claims about *mainnet bridge linkage* and *HyperCore order acceptance* are flagged as **assumptions to prove on a forked-mainnet harness / live test**, per the project's standing de-risk rule (docs and code reads set the hypothesis; the spike is the proof).

---

## 0. Decision record (2026-06-02)

- **Redemption shape:** keep the **synchronous ERC-4626** surface (idle-capped `withdraw`/`redeem`) **plus a hardened version of the existing `requestWithdraw`/`fulfillWithdraw` queue**. Add a keeper, an on-chain fulfillment deadline + permissionless forced-close, and soft barriers (cooldown / gate). **EIP-7540 / async is explicitly out of scope.**
- **Accepted trade-off:** liquidity-gating + barriers mean the vault is **not a strict drop-in ERC-4626** for arbitrary third-party integrators. This is to be **documented loudly** for integrators rather than engineered away (see §3, §4-E).

---

## 1. Bottom line up front

1. **Redemptions are bounded by idle EVM USDC, and nothing in the contract repatriates capital automatically.** When NAV is deployed in perp margin, an LP redemption pays out **$0** until the **operator** manually unwinds and bridges funds back to the EVM side. `fulfillWithdraw` does **not** pull from Core — it only distributes USDC that is already idle.
2. **A request system already exists** (`requestWithdraw` → `fulfillWithdraw` → `cancelWithdrawRequest`) and is compatible with synchronous 4626 — but it is **manual, has no on-chain deadline/SLA, no keeper implementation, and zero test coverage.** The "loop" lives only as prose in `docs/INTEGRATION.md`.
3. **Auto-barriers (lockup / cooldown / notice / gate) do not exist** today — only the liquidity bound (`vaults.md` §6.3.1 confirms "Barriers: None").
4. **The most serious "is my money safe" gap is liveness, not theft.** On Hyperliquid funds can't be *stolen* (the vault is the Core account; CoreWriter has no withdraw-to-arbitrary action). But they **can be frozen**: the only role that can move USDC Core→EVM is `OPERATOR`, those functions are `whenNotPaused`, and **`EMERGENCY_ROLE` cannot repatriate at all.** Pausing the vault freezes the refill path while leaving redemptions "open" against an empty idle pool. There is **no permissionless escape hatch** in the shipped contract.

---

## 2. How redemptions work today

Two exit paths, both gated by the same scarce resource — idle EVM USDC (`idleUsdc()` = the vault's ERC-20 USDC balance, `HyperCoreVault.sol:347`).

### Path A — synchronous ERC-4626 (`withdraw` / `redeem`)
- `maxWithdraw(owner) = min(ownedAssets, idleUsdc())` (`:188`). `maxRedeem(owner) = balanceOf(owner)` (`:193`) — note the asymmetry; it matters for compliance (§3).
- `withdraw` reverts if `assets > idle` (`:252`). `redeem` **silently partial-fills**: if `previewRedeem(shares) > idle` it scales down to `idle` and burns only the corresponding shares (`:288-295`).
- Perf fee is taken out of the exiting LP's gross payout in USDC, no dilution (audit C-3) — working as designed.

### Path B — bespoke escrow queue (the "overflow" path)
- `requestWithdraw(shares)` (`:721`) escrows the LP's shares at the vault address, snapshots cost basis, emits `WithdrawalRequested(lp, shares)`. One open request per LP.
- `fulfillWithdraw(lp)` (`:748`) is **permissionless** (keeper-friendly). Reads `idleUsdc()`, pays out as much as idle allows (partial fills), burns the escrowed shares, takes the perf fee against the snapshot.
- `cancelWithdrawRequest()` (`:735`) returns the escrowed **shares** (not USDC) to the LP.

**The critical fact:** `fulfillWithdraw` contains no call to `pullFromCore` / `usdPerpToSpot` / `operatorRecoverSpot`. It is purely a distributor of already-idle USDC (`:754-755` read idle, `:784` transfer). Refilling idle is a separate, manual, operator-only action.

### The intended loop (per `docs/INTEGRATION.md`, prose only — not coded, not tested)
```
LP: requestWithdraw(shares)  ──emit WithdrawalRequested──►  (off-chain keeper must watch)
operator: close perp ─► usdPerpToSpot(ntl) ─► pullFromCore(wei)   [all OPERATOR_ROLE + whenNotPaused]
keeper/anyone: fulfillWithdraw(lp)  ─► LP paid from idle (partial fills supported)
```

---

## 3. Standards posture: sync-4626 + queue + barriers

Per the decision record (§0), the vault stays synchronous and gains a hardened queue + soft barriers. The team accepts the following deviations from *strict* ERC-4626, **which must be documented for integrators**:

- `maxRedeem` returns the full share balance, but `redeem` of that amount silently burns fewer shares and returns less than `previewRedeem` when idle is short (`:193` vs `:288-295`). A naive router / money-market adapter / aggregator can be surprised. (CLAUDE.md already acknowledges "a naive 4626 router can get fewer assets than `previewRedeem`.")
- Soft barriers (cooldown / gate) will make `withdraw`/`redeem` revert in states the sync view functions don't fully express. EIP-7540 exists precisely to model "can't redeem right now" without lying in the sync views; by staying sync we accept that the view functions are best-effort, not contractual, once capital is deployed or a barrier is active.

This is a deliberate product choice (sync simplicity + own-frontend/keeper integration) over strict third-party 4626 composability.

---

## 4. End-to-end gap register

Severity is relative to the goals "write a strategy, users deposit, users secure about their money."

> **Proof status (2026-06-02):** every finding below is now reproduced on real HyperEVM-mainnet bytecode (no mocks) — `✅ fork` = forked-mainnet Solidity test, `✅ live+fork` = live precompile read + fork test, `⏳ live` = requires the funded live spike (NAV>idle), `⏳ partial` = mechanism tested, automation still to build. Evidence + exact test names: **[`FORK_PROOFS.md`](FORK_PROOFS.md)**. The fork run surfaced a result stronger than originally written — **Finding G is confirmed, and the canonical USDC bridge is unusable for the shipped asset** (blacklisted bridge address + wrong Core-link).

| # | Finding | Where | Severity | Tested? |
|---|---|---|:--:|:--:|
| **A** | **Pause freezes the refill path.** All Core→EVM repatriation (`pullFromCore`, `usdPerpToSpot`, `operatorRecoverSpot`) is `whenNotPaused`; `EMERGENCY_ROLE` can close positions but **cannot repatriate**. Pausing leaves redemptions "open" against a pool that can't be refilled while paused. The `docs/INTEGRATION.md` emergency runbook (pause → … → `usdPerpToSpot` → `pullFromCore`) **would revert at the repatriation steps.** | `:487,493,516,544,549` vs `:558` | 🔴 High | ✅ fork |
| **B** | **No permissionless escape hatch.** If the operator vanishes/misbehaves with capital on Core, no one else can bring it to EVM. LPs can cancel to get shares back, not USDC. The "no stuck funds / forced-close after deadline" property (`vaults.md` §6.3) is **proposed, not shipped.** Funds can't be *stolen* on HL, but they can be *frozen*. | whole contract | 🔴 High | ✅ fork |
| **C** | **Single-EOA control in the shipped config.** `operator == emergencyAdmin == feeRecipient ==` `0x2003…753A`, and `timelockMinDelaySec = 0` with the deployer holding proposer/executor. Role separation collapses to ~one key; the C-2 `spotRecoverDest` allowlist guarantee is only as strong as the (currently 0-delay, deployer-held) timelock. | `deployments/configs/mainnet-tier1.json` | 🔴 High | ✅ fork |
| **D** | **Redemption loop unimplemented and untested.** No keeper watches `WithdrawalRequested`; `fulfillWithdraw` / `requestWithdraw` / `cancel` have zero unit/fork/live coverage. The queue mechanics are now covered (`test/fork/HyperVaultQueueAccounting.fork.t.sol`, Q1–Q7), but the **keeper / off-chain automation is still unbuilt** (TODO-4). | repo-wide | 🔴 High | ⏳ partial |
| **E** | **`fulfillWithdraw` doesn't pull from Core.** Fulfilment and repatriation are decoupled with only an off-chain human/keeper bridging them. No on-chain SLA / `fulfillmentDeadline` / forced close — the operator can stall redemptions indefinitely (or time them favourably vs. PnL). | `:748-788` | 🟡 Med | ✅ fork |
| **F** | **No fairness between exit paths.** Direct `redeem` and the queue compete for the *same* idle pool with no ordering or pro-rata; a direct redeemer (or faster keeper) can drain idle ahead of an earlier queued LP. Queued LPs stay fully PnL-exposed until fulfilled (no epoch NAV lock). | `:278,748` | 🟡 Med | ⏳ live |
| **G** | **CONFIRMED on-chain — the configured USDC is not the Core-linked USDC, and the canonical bridge is unusable.** Live precompile read: `tokenInfo(0).evmContract = 0x6B9E…0A24 ≠ asset() 0xb883…630f` — so `coreSpotUsdc()` (`:351`) measures a *different* token than `asset()`. And the Core bridge `0x2000…0000` is **blacklisted** on the configured Circle USDC, so `pushToCore`/`pullFromCore` **revert** (`test_G_pushToCoreRevertsOnBlacklistedBridge`). ⇒ with the shipped config the queue can **never** realise Core value into `asset()` via the bridge. Resolves the README-vs-`step_pull` contradiction in favour of the README. See `docs/FORK_PROOFS.md`. | `:351,493,516` | 🔴 High | ✅ live+fork |
| **H** | **Safety defaults ship OFF.** `strictNavReads` defaults false (`:111`); factory `strictAssetValidation` defaults false (`HyperCoreVaultFactory.sol:23`). Both must be enabled operationally after the Core account is initialized. Easy to forget. | `:111`, factory `:23` | 🟡 Med | ✅ fork |
| **I** | **Caps are test values.** `depositCap` and `maxDepositPerAddress` = `$100`. Fine for a live spike, not production. | configs | 🟢 Low | ✅ fork |

**Working-as-designed (verified, not flags):** C-3 no-dilution perf fee; the `bug_010` cost-basis escrow fix; `merged_bug_002` gross-`assets` withdraw; `bug_009` emergency-close scaling; C-1 self-share sweep block; C-2 allowlist; redeems being non-pausable at the *distribution* layer.

---

## 5. Prioritized TODOs

Each is framed per the de-risk rule — the proof is a **forked-mainnet harness or live test**, not a mock.

### P0 — before any strategy goes live with real LP money
- **TODO-1 (Finding G):** Fork-prove the USDC repatriation path on real mainnet bytecode: does `pushToCore` → `usdSpotToPerp` → `usdPerpToSpot` → `pullFromCore` actually round-trip the *configured* `asset()` back to idle? If not, define and fork-test the `operatorRecoverSpot`-to-treasury-then-deposit path, and reconcile `coreSpotUsdc()` NAV. **This is the single most important unknown** — the rest of the redemption design depends on the answer.
- **TODO-2 (Findings A+B):** Close the liveness gap. Minimum: make repatriation reachable under emergency (e.g. an `EMERGENCY_ROLE` repatriate path and/or drop `whenNotPaused` from the Core→EVM movers so a paused vault can still drain to idle). Strategic: design the permissionless forced-close / escape hatch for the HL venue. Fork-test "operator goes dark → LPs still get paid."
- **TODO-3 (Finding C):** Production key topology before mainnet LP deposits: split `operator` / `emergencyAdmin` / `feeRecipient`; set a real `timelockMinDelaySec` (24h+, matching the README diagram); hand timelock proposer/executor to a multisig; curate `spotRecoverDest`. Add a deploy-checklist assertion that rejects 0-delay / shared-role configs for mainnet.

### P1 — make the redemption system real (the chosen sync-4626 + hardened queue)
- **TODO-4 (Finding D):** Build and test the keeper: watch `WithdrawalRequested`, repatriate when aggregate pending is material, call `fulfillWithdraw`. Add it as an `e2e_runner.py` step (request → operator repatriates → fulfill → assert LP paid) on the live harness.
- **TODO-5 (Finding E):** Add an on-chain `fulfillmentDeadline` per request + a permissionless forced action after it lapses, so "operator stalls" is bounded on-chain, not by trust.
- **TODO-6 (Finding F):** Decide redemption fairness policy — at minimum document that direct `redeem` can jump the queue; ideally route all deployed-capital exits through one ordered/pro-rata mechanism.
- **TODO-7 (barriers):** Implement the chosen soft barriers (per-LP cooldown, global gate %, optional notice) as `require`s, and **document each as a deviation from strict 4626** in the integrator notes (§3).

### P2 — operational hardening
- **TODO-8 (Finding H):** Runbook + reminder to flip `strictNavReads` and factory `strictAssetValidation` true after Core-account init; consider defaulting them true behind a "fresh vault" grace flag.
- **TODO-9:** Add the queue paths (`requestWithdraw` / `fulfill` / `cancel`, partial fills, perf-fee-at-fulfill, pause interaction) to the Foundry suite — they currently have **no** coverage.
- **TODO-10 (Finding I):** Production caps; reconcile the README "24h timelock" claim with the shipped 0s configs.

---

## 6. Summary

The vault's trading and accounting core is in good shape — the audit and ultrareview mitigations are present and the perp/spot trade guards are sound. The redemption story is where it is **not yet production-ready**, and the strategy engineer identified the exact load-bearing weakness: **redemptions are gated on idle EVM USDC, and the contract does nothing automatically — refilling idle is a manual, operator-only, pausable action, with no keeper built, no on-chain deadline, no escape hatch, and no test coverage.** A request system exists and is sync-4626-compatible, but it's a skeleton.

All nine findings are now **proven on real HyperEVM-mainnet bytecode** (`docs/FORK_PROOFS.md`), and the proof pass made the picture sharper: **Finding G is confirmed and is the headline blocker** — the configured asset `0xb883…630f` is *not* the Core-linked USDC (`tokenInfo(0).evmContract = 0x6B9E…0A24`), and the Core bridge `0x2000…0000` is blacklisted on it, so `pushToCore`/`pullFromCore` **revert**. With the shipped config the redemption queue can never realise Core value back into `asset()` via the canonical bridge at all.

Before users can "be secure about their money," the must-fixes are, in order: **(1) — now urgent and confirmed —** fix the asset/bridge linkage: deploy with the Core-linked USDC (`0x6B9E…0A24`) **or** redesign repatriation around `operatorRecoverSpot`→treasury→re-deposit, since the canonical bridge is unusable for the shipped asset (G); **(2)** close the freeze/escape-hatch liveness gap so deployed capital can always reach LPs even if the operator goes dark or the vault is paused (A+B); **(3)** fix the single-EOA / 0-delay-timelock deployment topology (C); then **(4)** build the keeper-driven request→repatriate→fulfill loop and add the chosen soft barriers + on-chain deadline (D/E/F). Direction is locked to **sync-4626 + hardened request queue** (no EIP-7540); the immediate work is fixing the linkage and wiring that loop end-to-end. The fork suite + live spike are now in place to re-prove each fix as it lands.
