# Python scripts — live mainnet test harness + ops helpers

These scripts are the project's **live mainnet integration coverage** (the
mock-based forge tests were retired in favour of real on-chain verification).
Run from the repo root after `forge build` (the runner reads ABIs from `out/`).

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r scripts/python/requirements.txt
```

Everything targets **HyperEVM mainnet** by default. Set `OPERATOR_PRIVATE_KEY`
(the vault operator key) and `HYPEREVM_RPC_MAINNET` (see `.env`).

## `e2e_runner.py` — full-lifecycle live test harness
Drives a vault through `deposit → push → spot→perp → place → cancel → fill →
perp→spot → pull → redeem` on mainnet, asserting both the vault's on-chain state
and the HL API view at each step. `place` rests a post-only order; `fill` crosses
the book with a marketable IOC (real taker fill + fees, then flattens
reduce-only); the bridge steps need a linked EVM↔Core USDC bridge.

```bash
ARTIFACT=deployments/mainnet/<strategy>.json \
OPERATOR_PRIVATE_KEY=0x... ALICE_PRIVATE_KEY=0x... \
python scripts/python/e2e_runner.py                                   # full run
python scripts/python/e2e_runner.py --steps preflight,core_status    # read-only sanity
python scripts/python/e2e_runner.py --steps place,cancel --skip-bridge
```

### `keeper` step — automated redemption fulfillment (Assessment TODO-4)
`keeper.py`, driven via the `keeper` step. Watches `WithdrawalRequested`, sizes
each LP's claim (`previewRedeem(pendingWithdrawalShares)`) against free idle
(`idleUsdc() − reservedIdleUsdc()`), repatriates the shortfall from Core when
material (`usdPerpToSpot` if perp equity exists, then `pullFromCore` with the
mandatory **`× 0.998` fee guard** — never the exact full Core balance, which
HyperCore silently drops), then calls `fulfillWithdraw(lp)`. It records fulfilled
LPs + residuals (partial fills stay pending for the next pass) and monitors the
CoreDepositWallet `paused()` state every pass — if paused, it WARNS, skips the
dead pull route, and fulfills against idle only.

**Dry-run is the default**: it reads live on-chain state and logs the actions it
*would* take without sending any tx. The tx-sending mode is an explicit opt-in
(`--keeper-execute`) and the funded run is a **human gate**.

```bash
# dry-run (default) — reads + logs intended actions, sends nothing:
ARTIFACT=deployments/mainnet/<strategy>.json OPERATOR_PRIVATE_KEY=0x... ALICE_PRIVATE_KEY=0x... \
python scripts/python/e2e_runner.py --steps keeper

# tx-sending (funded, human-gated) — actually repatriates + fulfills:
python scripts/python/e2e_runner.py --steps keeper --keeper-execute \
  --keeper-poll 5 --keeper-max-iter 12 --keeper-timeout 600 --keeper-start-block <block>
```

## `live_contract_path.py` — focused order-lifecycle live test
Whitelist BTC → fund perp (`send_asset`) → place a `tif=1` / `10^8`-scale order
through the vault → confirm it rests on the HL book → cancel → recover funds.
Used to confirm the v1.3 px/sz-scale + TIF fixes from the contract path.

```bash
TEST_VAULT=0x... OPERATOR_PRIVATE_KEY=0x... \
python scripts/python/live_contract_path.py
```

## `optin_big_blocks.py`
Opt an address into HyperEVM big blocks (required to deploy the ~6–8M-gas vault).

```bash
OPERATOR_PRIVATE_KEY=0x... VAULT_ADDRESS=0x... NETWORK=mainnet \
python scripts/python/optin_big_blocks.py
```

## `seed_vault_core.py`
Spot-send USDC from your HL Core account to a vault's Core address — how to fund
a vault for perp orders when the EVM↔Core USDC bridge isn't linked for the asset
(the current mainnet state).

```bash
VAULT_ADDRESS=0x... OPERATOR_PRIVATE_KEY=0x... USDC_AMOUNT=20 NETWORK=mainnet \
python scripts/python/seed_vault_core.py
```

## `seed_whitelist.py`
Schedule + execute whitelist additions through the per-vault timelock.

```bash
ARTIFACT=deployments/mainnet/<strategy>.json \
HYPEREVM_RPC_MAINNET=https://rpc.hyperliquid.xyz/evm \
DEPLOYER_PRIVATE_KEY=0x... PERPS_TO_ADD=1,5,12 \
python scripts/python/seed_whitelist.py
```

## Battle-test kit (10-account live spike) — `docs/LIVE_SPIKE_RUNBOOK.md`

A 10-LP battle-test that exercises the full redemption/escape/fee matrix. Like the
keeper, it is **DRY-RUN-first**: without `--execute` nothing is ever sent.

- `gen_battle_keys.py` — generate the FULL throwaway account set (funder + operator
  + emergency + feeRecipient + 10 LPs + trigger) from one mnemonic into the
  gitignored `scripts/python/.battle_keys.json` (offline; prints addresses +
  allocations only). The **funder** is the ONE wallet you fund; it prints how much
  USDC + HYPE to send it.
- `disperse.py` — fan the per-account allocations out from the funder to every
  wallet (USDC + native HYPE), with a JSON-lines audit trail. DRY-RUN-first; runs
  a balance preflight; `--execute` broadcasts. `--check` shows balances anytime.
- `plan_funding.py --check` — alternative balance/shortfall report + `cast send`
  funding commands if you'd rather move funds manually.
- `monitor.py` — read-only watcher (CoreDepositWallet `paused()` alert + order
  reconciliation cloid→oid + leverage-cap monitor). Run alongside the keeper.
- `admin_timelock.py` — build the 24h-timelock admin batch (SLA window, escape
  grace, barriers, fees); dry-run prints the `scheduleBatch`/`executeBatch` cmds.
- `battle_test.py` — the orchestrator. `--plan` prints the coverage matrix;
  `--phase A..F,Z` / `--scenario <id>` run a slice (dry-run unless `--execute`);
  `--resume` skips PASS scenarios; `--journal-out` appends a NAV snapshot.
- `journal.py` — read-only daily NAV reconciliation + invariant checks.
- `state_store.py` — resumable `.battle_state.json` checkpoint (gitignored).

```bash
python3 scripts/python/gen_battle_keys.py                     # offline keygen -> prints the funder addr + amounts
# ... fund the funder with the printed USDC + HYPE on HyperEVM ...
python3 scripts/python/disperse.py                            # dry-run: plan + balance preflight
python3 scripts/python/disperse.py --execute                 # fan funds out (audit trail -> logs/)
python3 scripts/python/battle_test.py --plan                  # coverage matrix
ARTIFACT=deployments/mainnet/spike.json \
  python3 scripts/python/battle_test.py --phase A             # DRY-RUN (no funds)
python3 scripts/python/monitor.py --interval 30 --artifact deployments/mainnet/spike.json
```
