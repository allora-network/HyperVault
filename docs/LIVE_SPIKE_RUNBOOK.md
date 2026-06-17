# HyperVault Live-Spike Runbook — ONE vault, ONE strategy, TEN funded LPs

> Status: PREP COMPLETE, awaiting funded execution. The contract code, the deploy
> config, the keeper + monitor, and the 10-account battle-test kit are all merged
> as draft PRs and dry-run-verified. This runbook sequences the **human-run,
> funded** steps. Claude prepared and dry-ran every step; a human holds the keys,
> broadcasts the transactions, and moves the funds.

This is the M6/M7 live spike: deploy a single production-config vault running one
strategy, then battle-test it for 1-2 weeks with ten funded LP wallets across the
full redemption / escape / fee matrix, and wind down with a full reconciliation.

House rules carried from `docs/REDEMPTION_LIVE_RUNBOOK.md`:
- Every funded step lists the exact command and its expected outcome.
- DRY-RUN first (no `--broadcast`, no `--execute`), then broadcast.
- Record every tx hash in the Appendix table; reconcile every dollar at wind-down.

---

## 0. Human-decision gates (fill these in BEFORE deploy)

| Decision | Where | Default / placeholder | Owner |
|---|---|---|---|
| operator / emergencyAdmin / feeRecipient EOAs (3 DISTINCT, key-controlled) | `deployments/configs/spike.json` | sentinels `0x…a001/a002/a003` | you |
| The ONE strategy market (`whitelistPerps`) | `spike.json` | `[0]` = BTC perp | you + strategy |
| `leverageCapBps` / `slippageBandBps` | `spike.json` | `30000` (3x) / `200` | you + strategy |
| Spike caps (`depositCap` / `maxDepositPerAddress`) | `spike.json` | 500 / 100 USDC | you (confirm) |
| Fees (`perfFeeBps` / `mgmtFeeAnnualBps`) | `spike.json` | 1500 / 200 | you (confirm) |
| Timelock delay | `spike.json` | `86400` (24h) — DECIDED | — |
| `escapeGraceSeconds` for the escape test | post-deploy timelock | `14400` (4h floor) | you + Chief Scientist |
| SLA `requestFulfillmentWindow` | post-deploy timelock | `300`s (short, for the spike) | you |
| Seed size + per-LP funding | this runbook §3 | 220 USDC LPs + ~120 USDC operator seed | you |

The vault's `escapeGraceSeconds` ships at 8h; the spike lowers it to the 4h floor
so the escape brake can be exercised in one session. Final production floor is
pending Chief Scientist sign-off (interim 8h, hard bounds [4h, 30d]).

## Prerequisites

```bash
# .env (gitignored) must provide:
HYPEREVM_RPC_MAINNET=...          # a private/archive RPC (the public one rate-limits getLogs)
REGISTRY_MAINNET=0x...            # the existing per-chain vault registry
DEPLOYER_PRIVATE_KEY=0x...        # funded; big-blocks opted-in; = timelock proposer/executor
OPERATOR_PRIVATE_KEY=0x...        # the operator EOA (trades + keeper)
EMERGENCY_PRIVATE_KEY=0x...       # the emergencyAdmin EOA (pause/shutdown/repatriate)
# feeRecipient must also be key-controlled (to recover fee shares/USDC at wind-down).
ALERT_WEBHOOK_URL=...             # optional Slack-compatible alert sink for monitor.py
```

`forge build` once so `out/` exists (the Python scripts read ABIs from it).

---

## 1. Step 0 — Preflight (read-only, no funds)

```bash
# Confirm the USDC<->CoreDepositWallet linkage resolves on mainnet:
python3 scripts/python/resolve_usdc_linkage.py
# Expect: USDC 0xb88339…630f linked to CoreDepositWallet 0x6B9E…0A24 (WALLET-LINKED).

# Dry-run the deploy (NO --broadcast) — validates roles + 24h floor + wallet linkage:
STRATEGY_CONFIG=deployments/configs/spike.json \
  forge script script/Deploy.s.sol --rpc-url "$HYPEREVM_RPC_MAINNET"
# Expect: "SIMULATION COMPLETE". (Remove the simulated deployments/mainnet/spike.json afterward.)
```

## 2. Step 1 — Deploy the vault (FUNDED) + opt into big blocks

```bash
# 1a. Opt the DEPLOYER into HyperEVM big blocks (the vault is ~6-8M gas to deploy):
OPERATOR_PRIVATE_KEY=$DEPLOYER_PRIVATE_KEY python3 scripts/python/optin_big_blocks.py

# 1b. Broadcast the deploy (writes deployments/mainnet/spike.json with real addresses):
STRATEGY_CONFIG=deployments/configs/spike.json \
  forge script script/Deploy.s.sol --rpc-url "$HYPEREVM_RPC_MAINNET" --broadcast --slow
# Record: VAULT, TIMELOCK addresses from the output -> Appendix.

export ARTIFACT=deployments/mainnet/spike.json

# 1c. Opt the VAULT into big blocks (needed before it can act on Core):
OPERATOR_PRIVATE_KEY=$OPERATOR_PRIVATE_KEY VAULT_ADDRESS=$(jq -r .vault $ARTIFACT) \
  python3 scripts/python/optin_big_blocks.py
```

Because the timelock delay is 24h, the deploy does NOT auto-seed the whitelist —
that's the first timelock batch (Step 2).

## 3. Step 2 — Timelock admin batches (24h cadence)

All `DEFAULT_ADMIN_ROLE` config goes scheduleBatch -> wait 24h -> executeBatch.
`emergency`/`operator` actions are instant. Use `admin_timelock.py` to build each
batch; it prints the exact `cast send` commands (broadcasting is yours).

The cadence (front-load so the 24h waits overlap the run):

```
Day 0  deploy (Step 1). Schedule BATCH-1: whitelist the market + SLA window + 4h grace.
Day 1  execute BATCH-1  -> enables phases A, B, E (and F's grace prereq).
       Schedule BATCH-2: barriers ON (lockup/cooldown/gate).
Day 2  execute BATCH-2  -> run phase C (barriers). Schedule BATCH-3: barriers OFF (0,0,0).
Day 3  execute BATCH-3  -> run phases D and F. Then wind-down (Z).
```

```bash
# BATCH-1 (day 0 schedule): whitelist BTC(0) + SLA 300s + escape grace 4h.
python3 scripts/python/admin_timelock.py --actions "perp=0,sla=300,grace=14400"
#   -> prints the scheduleBatch cast send; broadcast it as DEPLOYER.
# Day 1: re-run with --execute to print the executeBatch cast send; broadcast it.
python3 scripts/python/admin_timelock.py --actions "perp=0,sla=300,grace=14400" --execute

# BATCH-2 (day 1 schedule, day 2 execute): barriers ON (example: 1h lockup, 1h cooldown, 20% gate).
python3 scripts/python/admin_timelock.py --actions "barriers=3600:3600:2000"          # schedule
python3 scripts/python/admin_timelock.py --actions "barriers=3600:3600:2000" --execute # day 2

# BATCH-3 (day 2 schedule, day 3 execute): barriers OFF before phase D.
python3 scripts/python/admin_timelock.py --actions "barriers=0:0:0"                     # schedule
python3 scripts/python/admin_timelock.py --actions "barriers=0:0:0" --execute           # day 3
```

> `admin_timelock.py` is dry-run by default; add `--execute-onchain` (with
> `DEPLOYER_PRIVATE_KEY` present) ONLY if you want it to broadcast for you instead
> of copy-pasting the `cast send` lines. Either way is a human gate.

## 4. Step 3 — LP wallets + funding + seed

```bash
# 3a. Generate the 10 LP + 1 trigger throwaway keys (offline, gitignored, 0600):
python3 scripts/python/gen_battle_keys.py            # prints addresses only

# 3b. See what to fund, then broadcast the funding yourself:
python3 scripts/python/plan_funding.py --keys scripts/python/.battle_keys.json --artifact $ARTIFACT
#   -> emits `cast send <USDC> transfer ...` for each LP (220 USDC total) + HYPE gas drips.
#   Fund the operator separately with the vault seed (~120 USDC) + 1.0 USDC activation reserve + gas.
# 3c. Confirm funding landed:
python3 scripts/python/plan_funding.py --keys scripts/python/.battle_keys.json --artifact $ARTIFACT --check
#   -> every account should read OK.

# 3d. Seed the vault (operator deposits the strategy capital + activates Core on first push):
#   The first pushToCore costs 1.0 USDC account-activation gas (one-time). Use e2e_runner:
ARTIFACT=$ARTIFACT python3 scripts/python/e2e_runner.py --steps deposit,push --deposit-usdc 120
```

## 5. Step 4 — Keeper + monitor online (continuous, for the whole window)

```bash
# Keeper (fulfillment engine) — funded, human-gated. Run under a supervisor; log to logs/.
ARTIFACT=$ARTIFACT python3 scripts/python/e2e_runner.py --steps keeper --keeper-execute \
  --keeper-poll 10 --keeper-max-iter 0 --keeper-timeout 1209600 \
  --keeper-start-block $(jq -r .deployBlock $ARTIFACT) | tee -a logs/keeper.log

# Monitor (read-only) — paused-wallet + order reconciliation + leverage alerts.
ARTIFACT=$ARTIFACT python3 scripts/python/monitor.py --interval 30 \
  --log-file logs/monitor.jsonl | tee -a logs/monitor.log
```

> ESCAPE EXCEPTION (phase F): so LP10's request can age into the brake, the keeper
> must NOT fulfill it. Either stop the keeper for the duration of phase F, or start
> it with `--keeper-start-block` AFTER LP10's request block so it never sees it.
> Resume the normal keeper after `exitEscape`.

## 6. Steps 5-10 — The 10-account matrix (phase by phase)

Each phase is dry-run first (no `--execute`), then run for real with `--execute`.
`--journal-out` appends a NAV snapshot after every scenario; `--resume` skips PASS.

```bash
python3 scripts/python/battle_test.py --plan        # the coverage matrix

# Phase A (barriers OFF): happy-path full/partial redeem; mgmt accrual; NAV-moving entry.
python3 scripts/python/battle_test.py --phase A --artifact $ARTIFACT --journal-out logs/journal.jsonl
python3 scripts/python/battle_test.py --phase A --artifact $ARTIFACT --journal-out logs/journal.jsonl --execute

# Phase B: queue (request -> keeper fulfill, full + partial+re-prioritize), Finding-F race, cancel/re-request.
python3 scripts/python/battle_test.py --phase B --artifact $ARTIFACT --journal-out logs/journal.jsonl --execute

# Phase C (after BATCH-2 barriers ON): barrier lockup/cooldown/gate; queue proven ungated.
python3 scripts/python/battle_test.py --phase C --artifact $ARTIFACT --journal-out logs/journal.jsonl --execute

# Phase D (after BATCH-3 barriers OFF): emergencyShutdown + pause/repatriate-while-paused + fee edge.
python3 scripts/python/battle_test.py --phase D --artifact $ARTIFACT --journal-out logs/journal.jsonl --execute

# Phase E: overdue -> permissionless prioritizeOverdue -> fulfill (wait for the SLA window to lapse).
python3 scripts/python/battle_test.py --phase E --artifact $ARTIFACT --journal-out logs/journal.jsonl --execute

# Phase F (LAST — scope the keeper off LP10): permissionless escape end-to-end.
#   LP10 requests, operator goes dark, wait deadline(300s)+grace(4h), then the matrix
#   has the `trigger` account arm + run the 4 legs (60s apart) + fulfill + exitEscape.
python3 scripts/python/battle_test.py --phase F --artifact $ARTIFACT --journal-out logs/journal.jsonl --execute
```

Per-account expectations are in `battle_test.py --plan` and the PR-5 coverage table.

## 7. Daily NAV reconciliation + journal

Once per day (and at every phase boundary):

```bash
python3 scripts/python/journal.py --once --artifact $ARTIFACT \
  --keys scripts/python/.battle_keys.json --journal-out logs/journal.jsonl
```

Snapshot captures: `totalAssets / idle / available / reserved / coreSpot /
perpWithdrawable / totalSupply / pricePerShare`; per-LP shares + previewRedeem +
pending/deadline/reserved/overdue; feeRecipient USDC + share balances; posture
(escape/paused/shutdown/grace/SLA); and HL-vs-precompile drift. It asserts:
`idle == available + reserved`; `totalAssets ≈ idle + coreSpot + perpWithdrawable`;
`reserved <= idle`; mgmt-fee shares only increase; a stayer's PPS is not diluted
by another LP's exit; HL drift < 0.01 USDC. Investigate any red invariant line.

## 8. Step 11 — Wind-down + decommission

```bash
# Dry-run the wind-down to see the full recovery plan, then execute:
python3 scripts/python/battle_test.py --phase Z --artifact $ARTIFACT
python3 scripts/python/battle_test.py --phase Z --artifact $ARTIFACT --execute
```

Wind-down order (the Z scenario + manual ops):
1. `exitEscape([...])` if still latched (once every offender is honorable).
2. Keeper drains every remaining queue request; re-`prioritizeOverdue` any partial remainder.
3. Bring all Core capital to EVM idle: `usdPerpToSpot` -> `pullFromCore(balance*0.998)`;
   finish dust with `operatorRecoverSpot`/`emergencyRepatriate` to an allowlisted dest.
   NEVER request the exact full Core balance (the ~0.00134 USDC fee makes it drop).
   Confirm each fire-and-forget send settled with `reconcile.py`.
4. Every LP with shares: final `redeem` (barriers confirmed OFF).
5. Operator redeems accrued mgmt-fee shares; sweep `feeRecipient` perf-fee USDC.
6. Sweep residual USDC + HYPE from all 12 accounts to treasury.
7. Decommission: `pause()` (or leave `emergencyShutdown` set); confirm `totalAssets`
   and `totalSupply` ≈ 0; archive the keyfile + the final journal.

---

## 9. Battle-test report template

```
HyperVault Battle-Test Report — <dates>, vault <addr>, block range <a>-<b>

1. Scenario results
   table: (a..l) -> PASS/FAIL + tx hashes + assertion notes

2. Coverage
   every redemption/escape/fee path -> the exercising tx

3. Fee accounting
   mgmt-fee shares minted to operator (dilutive)
   perf-fee USDC to feeRecipient, per realizing LP (per-LP cost basis, no mint)

4. Dollar reconciliation
   funded_in  (220 USDC LPs + ~120 operator seed + 1.0 activation reserve)
   - fees_paid (perf to feeRecipient)
   - bridge/withdrawal fees (~0.00134 USDC * N pulls)
   - gas (HYPE, separate currency)
   = funds_out (recovered per account)   => residual ~0 within known fees

5. Escape timeline
   request -> deadline -> +grace -> triggerEscape -> leg1..leg4 (timestamps, >=60s apart)
   -> fulfill -> exitEscape

6. Anomalies / invariant violations / HL drift > 0.01 with root cause

7. Final state: totalAssets, totalSupply, latch cleared, vault paused/shutdown
```

## 10. Appendix — tx-hash table

| Step | Action | Account | Tx | Result |
|---|---|---|---|---|
| 1b | deploy vault | deployer | `0x…` | vault `0x…` |
| 2  | BATCH-1 schedule/execute | deployer | `0x…` | whitelist+SLA+grace |
| … | … | … | … | … |

> Mirror the `docs/FORK_PROOFS.md` "live spike" section: paste every funded tx
> hash here as you go, so the spike is auditable end-to-end.
