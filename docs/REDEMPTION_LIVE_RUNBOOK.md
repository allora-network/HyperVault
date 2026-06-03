# Redemption Live-Spike Runbook

Closes the residuals the forked-mainnet suite cannot reach (see [`FORK_PROOFS.md`](FORK_PROOFS.md) "Why F, Q4 … are live-only"): the real Core→EVM bridge round-trip, a genuine **NAV > idle** gap (Findings **F** race and **Q4** partial-fill), and live confirmation of **E** / **G** / **A**.

> **This runbook moves real funds and deploys a real contract. It is operator-driven — run it yourself with your keys; nothing here is executed automatically.** Keep the deposit cap tiny ($10–100). The deployed tier1/2/2b vaults are pre-v1.3 and cannot place orders — deploy a **fresh throwaway v1.3 vault**.

## ⚠️ Read first — Finding G changes what's provable with the shipped USDC

The proof pass **confirmed** (`scripts/python/resolve_usdc_linkage.py`, and `test_G_pushToCoreRevertsOnBlacklistedBridge`):

- the configured asset `0xb88339…630f` is **not** the Core-linked USDC (`tokenInfo(0).evmContract = 0x6B9E…0A24`);
- the Core bridge `0x2000…0000` is **blacklisted** on that USDC, so **`pushToCore`/`pullFromCore` revert**.

⇒ With the shipped asset you **cannot** create a real NAV>idle gap (capital can't reach Core via the bridge), so **F and Q4 cannot be demonstrated end-to-end with `0xb88339…630f`.** Two scenarios follow.

| | Scenario A — shipped USDC (cheap, do first) | Scenario B — bridge-functional asset (proves F/Q4) |
|---|---|---|
| Asset | `0xb88339…630f` | the Core-linked USDC `0x6B9E…0A24` *(verify it is a usable ERC-20 first)* |
| Proves | G live (push reverts), A live (pause freeze), queue escrow/cancel, E (fulfill idle-bound) | the above **plus** F (race) and Q4 (partial fill) with a genuine NAV>idle gap |
| Risk/cost | ~3 txns, ~$0 at risk (push reverts) | deposits + Core round-trip; ~$10–100 + fees |
| Gate | none | **first confirm `0x6B9E…0A24` exposes `decimals()`/`transfer()`** (it reverts `name()/symbol()`); if not ERC-4626-usable, F/Q4 stay deferred until the linkage is fixed |

## Prerequisites

- `HYPEREVM_RPC_MAINNET` (e.g. `https://rpc.hyperliquid.xyz/evm`).
- `DEPLOYER_PRIVATE_KEY`, `OPERATOR_PRIVATE_KEY`, `ALICE_PRIVATE_KEY` (with `0x`). For the pause-freeze step the operator must also hold `EMERGENCY_ROLE` (the shipped single-key config already collapses these — Finding C).
- `REGISTRY_MAINNET` in env (or deploy a throwaway registry).
- A throwaway deploy config — copy `deployments/configs/mainnet-tier1.json`, keep `depositCap`/`maxDepositPerAddress` tiny, set `timelockMinDelaySec: 0` for a quick bootstrap.
- Small USDC + HYPE for gas on the operator and alice accounts.

## Step 0 — confirm Finding G live (read-only, no funds)

```bash
python3 scripts/python/resolve_usdc_linkage.py        # expect: NOT LINKED (Finding G CONFIRMED)
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

## Scenario B — F (race) + Q4 (partial fill) with a real NAV>idle gap

Only meaningful with a **bridge-functional asset**. Pre-check the linked token first:

```bash
cast call 0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24 "decimals()(uint8)" --rpc-url "$HYPEREVM_RPC_MAINNET"
# if this reverts, 0x6B9E…0A24 is not a standard ERC-20 -> F/Q4 stay deferred until the
# asset/linkage is fixed (TODO-1); do not proceed with Scenario B.
```

If usable, deploy a throwaway vault with that asset and run the full loop, which creates NAV>idle for real:

```bash
export ARTIFACT=deployments/mainnet/<throwaway-linked>.json
# deposit two LPs, deploy capital to Core (NAV > idle), then exercise the race + partial fulfill
python3 scripts/python/e2e_runner.py \
  --steps deposit,push,spot_to_perp,request_withdraw,fulfill_withdraw,operator_repatriate,fulfill_withdraw,cancel_withdraw
```

- **E (live):** the first `fulfill_withdraw` (capital on Core, idle drained) is a **no-op** — alice unpaid.
- **F (race):** with two LPs and idle < total claims, a direct `redeem` by LP2 drains the shared idle ahead of LP1's queued `fulfill` — add an LP2 `redeem` between the request and the second fulfill and observe LP1 starved until repatriation.
- **Q4 (partial fill):** when `operator_repatriate` returns *part* of the claim, `fulfill_withdraw` partial-fills and leaves a remainder.
- **Operator repatriate:** `usdPerpToSpot`→`pullFromCore` — for `0xb88339…630f` this reverts (Finding G); for a linked asset it credits idle and the second `fulfill_withdraw` pays alice.

## Step N — recover funds and decommission

```bash
# redeem any remaining shares, pull idle back to the deployer, abandon the throwaway vault
python3 scripts/python/e2e_runner.py --steps redeem
```

Record outcomes (tx hashes + which steps reverted) in [`FORK_PROOFS.md`](FORK_PROOFS.md) under the F / Q4 rows.

## Acceptance

- Step 0 prints `NOT LINKED (Finding G CONFIRMED)`.
- Scenario A: `push` reverts on the blacklist; `pause_freeze_check` reverts while paused; queue escrow/cancel succeed.
- Scenario B (if the linked asset is usable): E no-op → repatriate → fulfill pays; F starvation observed; Q4 partial-then-full observed. Otherwise F/Q4 are formally **deferred behind the linkage fix (TODO-1)** and recorded as such.
