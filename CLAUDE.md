# HyperVault (VaultContract) — in-repo guide for Claude

Production-grade, audited **single-venue Hyperliquid strategy vault**: depositors hold tokenized ERC-4626 shares; an operator trades the pooled USDC on HyperCore (perps + spot) via CoreWriter; NAV is read on-chain from precompiles. One vault = one strategy.

- **Branch:** `audit/mitigations` (main is `main`).
- **Stack:** Foundry, Solidity `0.8.27`, EVM `cancun`. Deploys to **HyperEVM mainnet**.
- **Canonical HyperEVM lib:** `hyperliquid-dev/hyper-evm-lib` (PrecompileLib + CoreWriterLib + CoreSimulator). Remapped `@hyper-evm-lib/`.

## Build / test

```bash
forge build
forge test                 # unit/regression (mocked precompiles + CoreWriter)
# fork spike (real mainnet bytecode, not a mock):
ETH_RPC_URL=<archive-rpc> forge test --match-path test/fork/LighterCustody.fork.t.sol -vvv
# redemption/liveness/governance proofs on real HyperEVM bytecode (no mocks):
HYPEREVM_RPC_MAINNET=<rpc> forge test --match-path 'test/fork/HyperVault*.fork.t.sol' -vvv
```

`foundry.toml`: optimizer 200, `bytecode_hash=none`; RPC `hyperevm_mainnet` from `$HYPEREVM_RPC_MAINNET`; CI profile runs fuzz=5000, invariant=256/32.

## Layout (current code)

| Path | What |
|---|---|
| `src/HyperCoreVault.sol` | The vault. `is IHyperCoreVault, ERC4626, AccessControl, Pausable, ReentrancyGuard`. |
| `src/HyperCoreVaultFactory.sol` | **CREATE2** factory (one per chain); deploys a **per-vault `TimelockController`** + the vault. |
| `src/HyperCoreVaultRegistry.sol` | On-chain directory of deployed vaults (frontend reads it). |
| `src/libraries/` | `CoreWriterLib` (typed CoreWriter actions), `PrecompileLib` (L1 read precompiles), `AssetId` (encode perp/spot index), `SystemAddress` (per-token bridge address), `Constants`. |
| `vaults.md` | **Forward-looking** multi-venue scoping doc (NOT the current code — see below). |

## How the current vault works (verified facts — don't assume from `vaults.md`)

- **Shares:** asset = USDC (6dp); share token is 12dp via a 6-decimal offset (OZ virtual-shares inflation defense).
- **NAV:** `totalAssets() = idleUsdc() + coreSpotUsdc() + perpWithdrawable()`. Deliberately **excludes mark-price PnL** (uses HL's conservative `withdrawable`). `strictNavReads` (off by default) makes the precompile reads revert-on-failure instead of returning 0 (audit H-1).
- **Fees:** management fee accrues by **dilutive share mint**; performance fee is **per-LP cost-basis**, paid in USDC out of the exiting LP's payout — **no fee-share mint, no dilution of stayers** (audit C-3). Hard caps: mgmt ≤ 2000 bps/yr, perf ≤ 5000 bps.
- **Redemption = synchronous ERC-4626 + a bespoke liquidity-gated queue. NOT EIP-7540.**
  - `withdraw`/`redeem` are **capped to idle EVM USDC** (`maxWithdraw = min(owned, idle)`; `redeem` partial-fills). A naive 4626 router can get fewer assets than `previewRedeem` when capital is parked on Core.
  - Overflow path: `requestWithdraw(shares)` escrows shares at the vault → `fulfillWithdraw(lp)` is **permissionless/keeper**, partial fills, one open request per LP, `cancelWithdrawRequest()`.
  - **No lockup / notice / gate / cooldown / epoch barriers** — only the liquidity bound. Redeems are **never pausable**; `emergencyShutdown` (one-way) blocks deposits only. (The 7540 epoch machine + enforced barriers in `vaults.md` are **proposed P1 work**, not shipped.)
- **Redemption assessment + proofs (2026-06; current work):** `docs/REDEMPTION_ASSESSMENT.md` is the e2e review (the strategy engineer flagged that LPs can only redeem against idle while capital sits on Core). **Direction decided: sync-4626 + a *hardened* request queue (keeper + on-chain fulfillment deadline + permissionless forced-close + soft cooldown/gate) — explicitly NOT EIP-7540.** All findings are **proven on real HyperEVM bytecode** (`test/fork/HyperVault*.fork.t.sol`, 16 pass / 2 live-only skips; results in `docs/FORK_PROOFS.md`). **Headline blocker — Finding G CONFIRMED:** the shipped asset `0xb88339…630f` is NOT the Core-linked USDC (`tokenInfo(0).evmContract = 0x6B9E…0A24`) and the Core bridge `0x2000…0000` is **blacklisted** on it ⇒ `pushToCore`/`pullFromCore` **revert** ⇒ the canonical EVM↔Core bridge is unusable for the shipped config (fix the asset/linkage FIRST). **Live funded spike EXECUTED 2026-06-03 — phase CLOSED:** throwaway vault `0x5DE2…3b26`; F (race) + Q4 (partial) + G/A/E/queue/trade-path/C-2 all proven live (NAV>idle via Core-seed `sendAsset`, since the bridge is dead and the asset-swap to `0x6B9E…0A24` is impossible — it's not a usable ERC-20). EVM funds 100% recovered. Results in `docs/FORK_PROOFS.md` "Live spike"; HL ops gotchas in memory `reference_hypercore_live_ops`. Next = remediation (TODO-1 Path B + keeper loop).
- **Roles:** `DEFAULT_ADMIN_ROLE` (should be the TimelockController), `OPERATOR_ROLE` (trades), `EMERGENCY_ROLE` (pause/close). Trade guards: perp/spot **whitelist**, `leverageCapBps`, `slippageBandBps` + per-spot `spotSlippageBandBps`.
- **Audit mitigations baked in:** C-2 `spotRecoverDest` allowlist (operator can't drain Core spot anywhere); C-3 no-dilution perf fee; H-1 strict NAV reads; H-2 strict `markPx` in leverage-notional (no silent drop); H-3 spot slippage band. Ultrareview fixes: bug_010 (cost-basis reset perf-fee evasion), bug_009 (emergency-close size scale), merged_bug_002 (`withdraw` `assets` is gross), bug_007 (leverage-cap lenient read — documented deliberate).

## HyperCore encoding gotchas (these have bitten repeatedly — get them right)

- **`limit_order` `px` AND `sz` are `round(human * 10^8)`** — a **uniform 10^8 scale, NOT szDecimals-based**. Wrong scale → HyperCore reads sub-cent dust below the **$10 min notional** and **silently drops** the order. This (not the TIF) was the root cause of the "HL won't take orders from a contract" saga; fixed in v1.3.
- **Read precompiles use a different scale:** `oraclePx`/`markPx` return `human * 10^(6 - szDecimals)`. Normalize before comparing to action-scale prices.
- **TIF is 1-indexed:** `1=ALO, 2=GTC, 3=IOC` (no FOK). `tif=0` is invalid and silently dropped.
- **CoreWriter is fire-and-forget:** the EVM tx succeeds and events fire **even if HyperCore rejects the action** (place ≠ fill). Reconcile off-chain.
- **A forge fork CANNOT run the HyperCore precompiles (`0x0800–0x0810`)** — Foundry's revm doesn't implement them, so on a fork they read empty ⇒ lenient `PrecompileLib` wrappers return 0 and `totalAssets() == idleUsdc()` (Core/perp NAV reads as 0). Consequences for fork tests: NAV>idle states (partial-fill, redeem-race) are **not fork-representable without mocking** → prove them live; and linkage/price/balance precompile reads must be done via a **live `eth_call`** (e.g. `scripts/python/resolve_usdc_linkage.py`), not a fork. `@hyper-evm-lib/` is **remapped but NOT vendored** in this repo, so `CoreSimulator` is unavailable.
- `Constants` are compile-time inlined → a wrong value requires **redeploy**, not a hot-fix.

## `vaults.md` — multi-venue scoping (proposal, not current code)

Evolves this vault into an EVM/venue-agnostic system (Hyperliquid, Avantis, Lighter, Hibachi). Key idea: **custody and NAV are separable trust axes**; specialize Class-A trustless-NAV paths, share everything else. De-risk spike status:

- **D1** (HL order rests) — ✅ closed (8/8 rested live).
- **D2** (Lighter custody) — ✅ **fork-confirmed** on real mainnet bytecode (`test/fork/LighterCustody.fork.t.sol`, 6/6): a contract is a first-class L1 owner, withdrawals are destination-bound, 14-day permissionless Desert-Mode escape ⇒ **A-custody / B-NAV**. Off-chain trade-restriction (testnet) still pending.
- **D3** (Hibachi destination) — 🔴 leans RED (arbitrary operator-signable `withdrawAddress`); Arbitrum fork + live-API spike pending.

**De-risk rule (the user enforces this):** never conclude from mocks or docs — every spike must reproduce on a **forked-mainnet harness (real deployed bytecode)** or a live testnet/API. Docs set the hypothesis; the spike is the proof.

## Conventions / don't-re-flag

- The original Foundry suite (`test/audit/Mitigations.t.sol`, `test/unit|integration|mocks/*`) was **intentionally deleted** in `33b5149` (suite being rewritten) — don't treat its absence as a mistake. Current tests: `test/RemediationUltrareview.t.sol` (legacy mock suite — superseded for liveness/redemption proofs) + `test/fork/LighterCustody.fork.t.sol` (D2) + **`test/fork/HyperVault{Base,Liveness,QueueAccounting,Governance}.fork.t.sol`** (redemption/liveness/governance proofs on real HyperEVM bytecode; needs `HYPEREVM_RPC_MAINNET`, skips cleanly without). Originals are on `origin/main` / history if needed.
- `vaults.md` is refined via Ultraplan — acknowledge handoffs; don't auto-exit plan mode. Keep its 🟢🟡🔴 / ✅❌⏳ status markers; decorative emojis and story-point sizing were intentionally stripped.
- Commit/push only when asked.
