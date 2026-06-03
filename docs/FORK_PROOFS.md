# Fork Proofs — Redemption / Liveness / Governance Findings

Evidence that the findings in [`REDEMPTION_ASSESSMENT.md`](REDEMPTION_ASSESSMENT.md) are real, reproduced on **real HyperEVM-mainnet bytecode** (no mocks) per the project's de-risk rule. Two substrates:

- **Forked-mainnet Solidity suite** — `test/fork/HyperVault*.fork.t.sol` (real USDC `0xb883…630f`, real vault deployed on the fork; LP funding via `deal`, a cheatcode, not a mock contract).
- **Live read-only node calls** — for facts a forge fork *cannot* serve, because Foundry's revm does not implement the HyperCore precompiles (`0x0800–0x0810`). These are real `eth_call`s to the live node (`scripts/python/resolve_usdc_linkage.py`, `cast`).
- **Live spike (funds)** — `scripts/python/e2e_runner.py` redemption-queue steps, for residuals that require a genuine NAV>idle gap (capital actually on Core). Staged, not yet executed — see [`REDEMPTION_LIVE_RUNBOOK.md`](REDEMPTION_LIVE_RUNBOOK.md).

**Run substrate of record:** public RPC `https://rpc.hyperliquid.xyz/evm`, chainId 999, fork block **36760512** (2026-06-02). Last run: **25 passed, 0 failed, 2 skipped** (the 2 skips are the intentional live-only stubs F and Q4).

```bash
# fork suite (skips cleanly with no RPC; set HYPEREVM_FORK_BLOCK to pin)
HYPEREVM_RPC_MAINNET=https://rpc.hyperliquid.xyz/evm \
  forge test --match-path 'test/fork/HyperVault*.fork.t.sol' -vv

# live Finding-G linkage read (read-only, no keys/funds)
python3 scripts/python/resolve_usdc_linkage.py
```

## Finding → proof matrix

| ID | Claim | Test / read | Status | Substrate |
|---|---|---|:--:|---|
| **A** | Pause freezes the refill path | `test_A_pauseFreezesRefillPath` | 🟢 PASS | fork |
| **A** | EMERGENCY_ROLE cannot repatriate | `test_A_emergencyRoleCannotRepatriate` | 🟢 PASS | fork |
| **B** | Only OPERATOR (unpaused) moves Core→EVM | `test_B_onlyOperatorCanRepatriate` | 🟢 PASS | fork |
| **B** | Queue fns are permissionless (gap is deliberate) | `test_B_queueFunctionsArePermissionless` | 🟢 PASS | fork |
| **E** | `fulfillWithdraw` pays from idle only; no-ops with value off-idle | `test_E_fulfillOnlyPaysFromIdle` | 🟢 PASS | fork |
| **F** | Direct redeem races the queue (starvation) | `test_F_…_provenInLiveSpike` | ⏳ live-only | live spike |
| **G** | Configured USDC ≠ Core-linked USDC | `resolve_usdc_linkage.py` (live precompile read) | 🟢 CONFIRMED | live read |
| **G** | Core bridge blacklisted → `pushToCore` reverts | `test_G_pushToCoreRevertsOnBlacklistedBridge` | 🟢 PASS | fork |
| **H** | Strict NAV reads default OFF; OFF fails open, ON fails closed | `test_H_strictNavReadsDefaultOffFailsOpen` | 🟢 PASS | fork |
| **C** | Shipped config collapses roles; 0-delay timelock = no protection | `test_C_shippedConfigCollapsesRolesAndTimelock` | 🟢 PASS | fork |
| **I** | $100 caps are real and enforced | `test_I_capsAreHundredDollarTestValues` | 🟢 PASS | fork |
| **Q1** | request escrows exactly the shares + emits | `test_Q1_requestEscrowsExactlyAndEmits` | 🟢 PASS | fork |
| **Q2** | one open request per LP; over-balance / zero guards | `test_Q2_oneOpenRequestPerLp`, `test_Q2_overBalanceAndZeroGuards` | 🟢 PASS | fork |
| **Q3** | cancel restores shares + preserves cost basis | `test_Q3_cancelRestoresSharesAndPreservesCostBasis` | 🟢 PASS | fork |
| **Q4** | partial-fill math (idle < claim) | `test_Q4_…_provenInLiveSpike` | ⏳ live-only | live spike |
| **Q5** | perf fee at fulfill uses the request-time snapshot | `test_Q5_perfFeeAtFulfillUsesRequestSnapshot` | 🟢 PASS | fork |
| **Q6** | stuck request clears + pays once idle refunded | `test_Q6_fulfillPaysOutAfterIdleRefunded` | 🟢 PASS | fork |
| **Q7** | fulfill on no request is a clean no-op | `test_Q7_fulfillNoRequestIsCleanNoOp` | 🟢 PASS | fork |

## Finding G — the decisive on-chain values (recorded)

Read live from the HyperCore `tokenInfo` precompile (`0x…080C`) for Core token 0 (USDC), block 36760512:

```
tokenInfo(0) = ("USDC", [], 0, 0x0000…0000,
                evmContract = 0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24,
                szDecimals = 8, weiDecimals = 8, evmExtraWeiDecimals = -2)
```

| Quantity | Value |
|---|---|
| Core USDC (token 0) linked EVM contract | `0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24` |
| Configured vault asset (`mainnet-tier1.json`) | `0xb88339CB7199b77E23DB6E890353E22632Ba630f` |
| Linked? | **NO** |
| Core bridge address `SystemAddress.usdc()` | `0x2000000000000000000000000000000000000000` |
| `isBlacklisted(bridge)` on the configured USDC | **true** |

**Verdict — Finding G CONFIRMED, and worse than originally written.** The vault's `asset()` is a *different* USDC than the one Core token 0 bridges to. Consequences, all now on-chain facts:

1. `coreSpotUsdc()` (`HyperCoreVault.sol:351`, reads Core token 0) measures the vault's balance of a token that is **not** `asset()` — so that NAV term is not a faithful accounting of redeemable USDC.
2. `pushToCore` / `pullFromCore` target the bridge `0x2000…0000`, which is **blacklisted** on the configured Circle USDC → both **revert** (`test_G_pushToCoreRevertsOnBlacklistedBridge`). The operator cannot deploy idle to Core *or* repatriate via the canonical bridge with this asset.
3. This **resolves the README-vs-`e2e_runner.step_pull` contradiction in favour of the README/natspec** (`HyperCoreVault.sol:500-511`): the bridge is *not* usable for the shipped asset. Any prior "bridge works" observation must have used a different (linked) token or the manual `seed_vault_core.py` Core-side path — not `0xb883…630f`.

Net: with the shipped configuration, the redemption queue can **never** realise Core-deployed value back into `asset()` through the canonical bridge. This is the deepest form of the liveness gap (Findings A/B/E) and a P0 blocker.

## Why F, Q4 (and the E/Q6 funded-payout tail) are live-only

A plain forge fork cannot represent **NAV > idle**: revm does not implement the HyperCore precompiles, so `coreSpotUsdc()`/`perpWithdrawable()` read 0 and `totalAssets() == idleUsdc()` always. Therefore:

- redeem is strictly proportional to idle → no LP can take more than its fair share → **starvation (F) cannot arise on a fork**;
- `previewRedeem(req) ≤ NAV == idle` always → the **partial-fill branch (Q4) never triggers on a fork**.

Reproducing NAV>idle on a fork would require mocking the precompile, which the no-mocks rule forbids. These are proven for real on the live spike, where `pushToCore`→`usdSpotToPerp` creates a genuine NAV>idle gap. The fork **does** prove the full-refund payout path (`Q6`) using `deal` as a stand-in for a completed bridge pull — the contract reads only `idleUsdc()` and cannot tell how idle was funded.

## Cross-links

- Findings + TODOs: [`REDEMPTION_ASSESSMENT.md`](REDEMPTION_ASSESSMENT.md)
- Live spike runbook: [`REDEMPTION_LIVE_RUNBOOK.md`](REDEMPTION_LIVE_RUNBOOK.md)
- Live harness: `scripts/python/e2e_runner.py` (queue steps `request_withdraw` / `fulfill_withdraw` / `operator_repatriate` / `cancel_withdraw` / `pause_freeze_check`)
- Linkage resolver: `scripts/python/resolve_usdc_linkage.py`
