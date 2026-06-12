# Redemption Live-Spike Runbook

Closes the residuals the forked-mainnet suite cannot reach (see [`FORK_PROOFS.md`](FORK_PROOFS.md) "Why F, Q4 … are live-only"): the real Core→EVM bridge round-trip, a genuine **NAV > idle** gap (Findings **F** race and **Q4** partial-fill), and live confirmation of **E** / **G** / **A**.

> **This runbook moves real funds and deploys a real contract. It is operator-driven — run it yourself with your keys; nothing here is executed automatically.** Keep the deposit cap tiny ($10–100). The deployed tier1/2/2b vaults are pre-v1.3 and cannot place orders — deploy a **fresh throwaway v1.3 vault**.

## ⚠️ Read first — Finding G changes what's provable with the shipped USDC

The proof pass **confirmed** (`scripts/python/resolve_usdc_linkage.py`, and `test_G_legacyPushRevertsOnBlacklistedBridge`):

- the configured asset `0xb88339…630f` is **not** the Core-linked USDC (`tokenInfo(0).evmContract = 0x6B9E…0A24`);
- the Core bridge `0x2000…0000` is **blacklisted** on that USDC, so **`pushToCore`/`pullFromCore` revert**.

⇒ With the shipped asset you **cannot** create a real NAV>idle gap (capital can't reach Core via the bridge), so **F and Q4 cannot be demonstrated end-to-end with `0xb88339…630f`.** Two scenarios follow.

| | Scenario A — shipped USDC (cheap, do first) | Scenario B — bridge-functional asset (proves F/Q4) |
|---|---|---|
| Asset | `0xb88339…630f` | the Core-linked USDC `0x6B9E…0A24` *(verify it is a usable ERC-20 first)* |
| Proves | G live (push reverts), A live (pause freeze), queue escrow/cancel, E (fulfill idle-bound) | the above **plus** F (race) and Q4 (partial fill) with a genuine NAV>idle gap |
| Risk/cost | ~3 txns, ~$0 at risk (push reverts) | deposits + Core round-trip; ~$10–100 + fees |
| Gate | none | **first confirm `0x6B9E…0A24` exposes `decimals()`/`transfer()`** (it reverts `name()/symbol()`); if not ERC-4626-usable, F/Q4 stay deferred until the linkage is fixed |

> **v1.5 G2 update (2026-06-12): Scenario B (asset swap) is permanently CLOSED, and that's fine.**
> `0x6B9E…0A24` reverts ERC-20 reads because it was never a token — it is **Circle's
> CoreDepositWallet, the official USDC EVM<->Core bridge** (live 2025-12-08). The "gate"
> failing was the expected behavior of a bridge contract, not a broken linkage. v1.5 routes
> `pushToCore` through it (approve+deposit), `pullFromCore` is unchanged, and the shipped
> Circle USDC stays the vault asset. The G2 round trip is **Scenario C** below; the
> Core-seed method (Scenario B') remains useful for manufacturing NAV>idle without trading.

## Status (2026-06-03)

The real-bytecode tests are **done and green** — the fork suite (`test/fork/HyperVault*.fork.t.sol`, 16 pass / 2 live-only skips) and the Finding-G read both ran against the `.env` RPC at block 36763664. The **funded spike was EXECUTED 2026-06-03** on throwaway vault `0x5DE26F34256f1303eCb3a3Ba70acEFD6E4f23b26` (deploy block 36824648). **F and Q4 are now PROVEN live**; full results in [`FORK_PROOFS.md`](FORK_PROOFS.md) → "Live spike — executed 2026-06-03". EVM funds were 100% recovered (≈$1 net Core-fee cost). The asset-swap "Scenario B" below was **disproven** (the linked USDC `0x6B9E…0A24` has bytecode but reverts on every standard ERC-20 read → it cannot be an ERC-4626 asset); the spike instead used the **Core-seed** method now documented in Scenario B'.

## Prerequisites

- `HYPEREVM_RPC_MAINNET` — in `.env`. ✅
- `DEPLOYER_PRIVATE_KEY` — in `.env`. ✅
- `OPERATOR_PRIVATE_KEY` / `ALICE_PRIVATE_KEY` — generated 2026-06-03, in `.env` (gitignored). ✅
  - **OPERATOR** `0xb0aE7D6FC5526449997193b6455ED1c9e6faB174` — fund with HYPE for gas. The vault **must** be deployed with `config.operator == this address` (else operator txns revert on `OPERATOR_ROLE`); set `config.emergencyAdmin` to it too for `pause_freeze_check`.
  - **ALICE** `0x496aFAd2a7FC15404d406b1D82cFEF99C9e970Ba` — the test LP; fund with a little USDC + HYPE for gas.
- `REGISTRY_MAINNET` — in `.env`. ✅
- ⏳ **Still required before running:** (1) fund both addresses; (2) a throwaway deploy config (copy `deployments/configs/mainnet-tier1.json`, set `operator`/`emergencyAdmin`/`feeRecipient` to the OPERATOR address, tiny `depositCap`/`maxDepositPerAddress`, `timelockMinDelaySec: 0`); (3) deploy (Step 1) so `ARTIFACT` exists.

## What `ARTIFACT` needs

`ARTIFACT` is the path to a deployment JSON. `e2e_runner.build_ctx` reads exactly two fields:

```json
{ "vault": "0x<vault address>", "asset": "0x<USDC EVM address>" }
```

It is **produced by Step 1** — `script/Deploy.s.sol` writes a full artifact (these + timelock/registry/operator/…) to `deployments/mainnet/<config-name>.json`; then `export ARTIFACT=deployments/mainnet/<throwaway>.json`. Caveats:

- The existing `deployments/mainnet/mainnet-tier{1,2,2b}.json` are **not usable**: they are pre-v1.3 (wrong px/sz scale baked in) **and** were deployed with a different `operator`, so the generated key holds no role on them.
- The vault's `config.operator` must equal the generated OPERATOR address, or every operator step reverts.

## Step 0 — confirm the USDC linkage live (read-only, no funds)

```bash
python3 scripts/python/resolve_usdc_linkage.py
# v1.5 expectation: WALLET-LINKED (CoreDepositWallet, unpaused, reserve printed), exit 0.
# (Pre-G2 this printed "NOT LINKED (Finding G CONFIRMED)".)
```

## Step 1 — deploy a fresh throwaway v1.3 vault

```bash
STRATEGY_CONFIG=deployments/configs/<throwaway>.json \
  forge script script/Deploy.s.sol --rpc-url "$HYPEREVM_RPC_MAINNET" --broadcast
# capture the printed Vault / Timelock; artifact lands in deployments/mainnet/<throwaway>.json
python3 scripts/python/optin_big_blocks.py            # emergency fan-out paths need big blocks
# whitelist BTC perp if you intend to deploy capital (Scenario B):
python3 scripts/python/seed_whitelist.py
```

## Scenario A — confirm the bridge is unusable + queue mechanics (shipped USDC)

```bash
export ARTIFACT=deployments/mainnet/<throwaway>.json
# G live: pushToCore must REVERT (blacklisted bridge). Expect step 'push' to fail loudly.
python3 scripts/python/e2e_runner.py --steps deposit,push
# A live: paused vault cannot repatriate (operator must hold EMERGENCY_ROLE)
python3 scripts/python/e2e_runner.py --steps pause_freeze_check
# Queue mechanics live: escrow + permissionless fulfill from idle + cancel
python3 scripts/python/e2e_runner.py --steps deposit,request_withdraw,fulfill_withdraw,cancel_withdraw
```

Expected: `push` reverts (`Blacklistable: account is blacklisted`) — the canonical EVM→Core deposit is impossible for this asset; `pause_freeze_check` shows `pullFromCore` reverts while paused; the queue escrows, fulfills from idle, and cancels cleanly. `fulfill_withdraw` here pays from idle (no Core gap), so it is **not** the F/Q4 proof.

## Scenario B' — F (race) + Q4 (partial fill) via **Core-seed** (the method actually used)

The original "Scenario B" assumed a bridge-functional asset obtained by redeploying with the Core-linked USDC `0x6B9E…0A24`. **That is impossible:** `0x6B9E…0A24` has bytecode but reverts on `decimals()/symbol()/totalSupply()/balanceOf()`, so the ERC-4626 constructor can't even read it. Instead, manufacture the NAV>idle gap by **seeding the vault's Core spot account directly** from a Core account you control — bypassing the dead bridge. The live precompiles then read it as genuine Core value.

> **Seeding primitive (unified accounts):** `seed_vault_core.py` uses `spot_transfer`, which HyperCore **disables for unified accounts**. Use `Exchange.send_asset(vault, "spot", "spot", "USDC", amount)` signed by the funding (deployer) key. Recover later with `operatorRecoverSpot(dest, 0, amountWei)` to a timelock-allowlisted `dest` (Core wei = human × 1e8). `operatorRecoverSpot` is fire-and-forget — **verify Core settled and retry if not**.

**Order of operations matters** (OZ virtual shares): a donation into an *empty* vault accrues to virtual shares, not to a depositor. **Deposit first, then seed**, so the LP's claim exceeds idle.

```bash
export ARTIFACT=deployments/mainnet/mainnet-spike.json   # throwaway, shipped USDC
# allow recovery dest once (via the 0-delay timelock): setSpotRecoverDest(deployer,true)

# --- Q4 (partial fill), single LP ---
python3 scripts/python/e2e_runner.py --steps deposit --deposit-usdc 4      # alice $4 (100%), idle $4
#   send_asset(vault,"spot","spot","USDC",4)  -> Core $4 ; NAV $8 > idle $4
python3 scripts/python/e2e_runner.py --steps request_withdraw,fulfill_withdraw
#   => fulfill pays the $4 idle (minus perf fee), leaves a remainder escrowed; Core $4 untouched (E)

# --- F (race), two LPs (drive bob via cast) ---
#   alice $4 + bob $4 -> idle $8 ; send_asset $8 -> Core $8 ; NAV $16, 50/50
#   alice requestWithdraw(all) ; bob redeem(all) DIRECT -> drains idle ; alice fulfillWithdraw -> starved
```

Executed result (2026-06-03): **Q4** fulfill paid **$3.70** of an $8 claim, ~2e12 shares left escrowed; **F** bob's direct redeem drained $8 idle, alice's fulfill got 1 wei. See [`FORK_PROOFS.md`](FORK_PROOFS.md) for tx hashes.

- **E (live):** while value sits on Core, `fulfill_withdraw` is idle-bound — it pays only idle and never reaches Core (confirmed: `coreSpotUsdc()` unchanged across the fulfill).
- **F (race):** the direct `redeem` path and the queue compete for the same idle with no reservation/ordering — LP2's direct redeem drains it ahead of LP1's queued request, starving LP1 until repatriation.
- **Q4 (partial fill):** when the claim exceeds idle, `fulfill_withdraw` partial-fills to exactly idle and leaves the remainder escrowed.
- **Repatriation reality (as of that 2026-06-03 run; superseded by G2):** the v1.3 spike vault could not bridge Core→EVM; the realisation path used was `operatorRecoverSpot`→treasury→re-deposit (Path B). **v1.5: `pullFromCore` is the faithful route via the CoreDepositWallet (Scenario C); Path B is the contingency.**

## Scenario C — v1.5 G2: official CoreDepositWallet round trip (the merge gate)

Proves the two live-only G2 stubs (`test_G2_coreSpotCreditAppears_provenInLiveSpike`,
`test_G2_walletPayoutOnPull_provenInLiveSpike`): the wallet route works end-to-end for a
CONTRACT account, with real funds, no treasury hop anywhere.

Throwaway v1.5 vault, tiny caps, `ALLOW_SHORT_TIMELOCK=1`, big-blocks opt-in for the
deploy (~9M gas). The deploy config MUST carry `"coreDepositWallet":
"0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24"` (the mainnet guard in `Deploy.s.sol`
enforces it for `coreUsdcIndex` 0).

```bash
# 0. read-only preflight: expect WALLET-LINKED + unpaused
python3 scripts/python/resolve_usdc_linkage.py

# 1. deploy the throwaway v1.5 vault (big blocks first); capture the artifact.
#    ASSERT: the deploy receipt emits CoreLinkVerified(asset, wallet) — the live-only
#    positive attestation (the precompile resolves on the real node, unlike a fork).
STRATEGY_CONFIG=deployments/configs/<throwaway>.json ALLOW_SHORT_TIMELOCK=1 \
  forge script script/Deploy.s.sol --rpc-url "$HYPEREVM_RPC_MAINNET" --broadcast
python3 scripts/python/optin_big_blocks.py
python3 scripts/python/seed_whitelist.py   # BTC perp for the trade leg

# 2. the round trip ($10): push $8 via the wallet -> Core spot credit -> perp leg ->
#    back to spot -> pull through the wallet -> redeem.
export ARTIFACT=deployments/mainnet/<throwaway>.json
python3 scripts/python/e2e_runner.py \
  --steps preflight,deposit,wallet_status,push,spot_to_perp,place,cancel,perp_to_spot,pull,wallet_status,redeem \
  --deposit-usdc 10
```

**PASS criteria (all required):**
- every tx `status == 1`; **no `operatorRecoverSpot` / treasury hop anywhere**;
- push: wallet reserve `+$8`, HL API spot and on-chain `coreSpotUsdc()` agree at `$8`
  within 60s (first push = fresh Core account: record any unexpected fee);
- pull: vault idle `+floor(amountWei/100)` (±$0.01 dust), wallet reserve `−same`;
- `wallet_status`: vault→wallet allowance is 0 at rest, before and after;
- alice recovers ≥ deposit − trade fees − $0.05.

Record the tx-hash table in [`FORK_PROOFS.md`](FORK_PROOFS.md) §"v1.5 G2" and flip the two
`_provenInLiveSpike` stubs' status rows. Optional H1 residual while funded: timelock-execute
`endNavBootstrap()`, then read `coreSpotUsdc()` strict against the real precompile.

## Step N — recover funds and decommission

```bash
# redeem any remaining shares, pull idle back to the deployer, abandon the throwaway vault
python3 scripts/python/e2e_runner.py --steps redeem
```

Record outcomes (tx hashes + which steps reverted) in [`FORK_PROOFS.md`](FORK_PROOFS.md) under the F / Q4 rows.

## Acceptance

- Step 0 (historical, pre-G2 runs): printed `NOT LINKED (Finding G CONFIRMED)`. **v1.5: expect `WALLET-LINKED`.**
- Scenario A (historical, v1.3 vault): `push` reverted on the blacklist; `pause_freeze_check` showed `pullFromCore` reverting while paused (pre-H2). **v1.5: a wallet-mode `push` succeeds; `pause_freeze_check` now asserts the H2 posture (pull succeeds while paused, `usdSpotToPerp` blocked).** The blacklist fact is pinned by the fork test `test_G_legacyPushRevertsOnBlacklistedBridge`.
- Scenario B' (Core-seed): ✅ **PASSED 2026-06-03** — Q4 partial fill ($3.70 of an $8 claim, remainder escrowed), F starvation (direct redeem drained idle, queued LP got 1 wei), E (fulfill never reached Core). All funds recovered via `operatorRecoverSpot` (C-2 allowlist). **F and Q4 are closed.** The realisation-gap caveat in that run is superseded by G2: the faithful Core→EVM path exists (the CoreDepositWallet); Scenario C proves it.
- Scenario C (v1.5 G2): ⏳ pending — the merge gate for `fix/G2-coredepositwallet-bridge`.
