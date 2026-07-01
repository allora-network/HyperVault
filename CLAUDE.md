# HyperVault (VaultContract) — in-repo guide for Claude

Production-grade, audited **single-venue Hyperliquid strategy vault**: depositors hold tokenized ERC-4626 shares; an operator trades the pooled USDC on HyperCore (perps + spot) via CoreWriter; NAV is read on-chain from precompiles. One vault = one strategy.

- **Branch:** `main` is current — v1.4 audit remediation, v1.5 G2 bridge, and the **M4/M5 redemption-hardening + permissionless escape-brake** work have all merged (commit `18c5859`; `forge test` 117 pass / 0 fail / 7 live-only skips). Work lands via per-issue draft PRs.
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
| `src/libraries/` | `CoreWriterLib`, `PrecompileLib`, `AssetId`, `SystemAddress`, `Constants` — plus four **delegatecall libs** (EIP-170 split; pure logic, no storage): `VaultTradeLib` (trade gate + emergency close), `VaultEmergencyLib` (escape latch + legs 1-3 cranks), `VaultEscapeLib` (escape trigger + spot→EVM pull), `VaultBarrierLib` (soft redemption barriers). |
| `vaults.md` | **Forward-looking** multi-venue scoping doc (NOT the current code — see below). |

## How the current vault works (verified facts — don't assume from `vaults.md`)

- **Shares:** asset = USDC (6dp); share token is 12dp via a 6-decimal offset (OZ virtual-shares inflation defense).
- **NAV:** `totalAssets() = idleUsdc() + coreSpotUsdc() + perpWithdrawable()`. Deliberately **excludes mark-price PnL** (uses HL's conservative `withdrawable`). `strictNavReads` (off by default) makes the precompile reads revert-on-failure instead of returning 0 (audit H-1).
- **Fees:** management fee accrues by **dilutive share mint**; performance fee is **per-LP cost-basis**, paid in USDC out of the exiting LP's payout — **no fee-share mint, no dilution of stayers** (audit C-3). Hard caps: mgmt ≤ 2000 bps/yr, perf ≤ 5000 bps.
- **Redemption = synchronous ERC-4626 + a bespoke liquidity-gated queue. NOT EIP-7540.**
  - `withdraw`/`redeem` are **capped to idle EVM USDC** (`maxWithdraw = min(owned, idle)`; `redeem` partial-fills). A naive 4626 router can get fewer assets than `previewRedeem` when capital is parked on Core.
  - Overflow path: `requestWithdraw(shares)` escrows shares at the vault → `fulfillWithdraw(lp)` is **permissionless/keeper**, partial fills, one open request per LP, `cancelWithdrawRequest()`.
  - **Soft redemption barriers — SHIPPED (M4 / SOLU-3366):** admin-configurable **lockup / cooldown / per-tx gate** as `require`-checks on the **synchronous** `withdraw`/`redeem` paths only, all default **0 = OFF** (`setRedemptionBarriers`; state lives in `VaultBarrierLib`, read off-chain — the view getters were dropped for EIP-170). The `requestWithdraw` queue + the emergency/repatriation surface are **never** barrier-gated, so redemption liveness holds. Redeems are **never pausable**; `emergencyShutdown` (one-way) blocks deposits only. (The EIP-7540 epoch machine in `vaults.md` remains **proposed**, not shipped — the shipped design is sync-4626 + hardened queue + soft barriers.)
- **Redemption hardening + permissionless escape brake — SHIPPED (M4/M5, 2026-06-17, PRs #18–#24):** (1) **Keeper loop** `scripts/python/keeper.py` (watch `WithdrawalRequested` → repatriate via `send_asset` → `fulfillWithdraw`; pulls `balance × 0.998`; monitors wallet `paused()`) + `reconcile.py` for fire-and-forget Core settlement. (2) **Soft barriers** (above). (3) **Fairness policy:** a direct `redeem` can jump the queue; the permissionless `prioritizeOverdue` reservation is the bounded backstop (`docs/INTEGRATION.md`). (4) The **Chief Scientist's permissionless emergency brake** (`docs/ESCAPE_HATCH_SCOPE.md`): once a request is overdue by `escapeGraceSeconds` (default **8h**, hard bounds **[4h, 30d]** — **final floor pending CS sign-off**) AND its claim exceeds idle, **anyone** may `triggerEscape` → cancel resting orders → flatten perps (reduce-only IOC + M4 band) → consolidate to spot → `escapePullToEvm` (`send_asset`) → `fulfillWithdraw`. Logic in `VaultEscapeLib`/`VaultEmergencyLib`. (SOLU-3419 dropped the dead `EscapeTriggerNotWired` placeholder error from `IHyperCoreVault.sol`.)
- **Redemption assessment + proofs (2026-06):** `docs/REDEMPTION_ASSESSMENT.md` is the e2e review (the strategy engineer flagged that LPs can only redeem against idle while capital sits on Core). **Direction decided: sync-4626 + a *hardened* request queue (keeper + on-chain fulfillment deadline + permissionless forced-close + soft cooldown/gate) — explicitly NOT EIP-7540.** All findings are **proven on real HyperEVM bytecode** (`test/fork/HyperVault*.fork.t.sol`, 16 pass / 2 live-only skips; results in `docs/FORK_PROOFS.md`). **Finding G — RESOLVED in v1.5 G2 (proven live 2026-06-15/16), superseding the "blocker" framing below.** `tokenInfo(0).evmContract = 0x6B9E…0A24` is **Circle's CoreDepositWallet** (the official USDC bridge), not a broken/competing token. The trustless loop works **both directions**: PUSH via `wallet.deposit(amount, CORE_SPOT_DEX_ID)`; PULL via CoreWriter **`send_asset` (action 13)** to the system address (NOT the old `spot_send`, which unified accounts silently drop — see the encoding-gotchas section). Proven on throwaway vault `0xDE6A…c777` (deposit→push→trade→send_asset pull→redeem); tx hashes in `docs/FORK_PROOFS.md` "v1.5 G2 — live spike". The spike also caught + fixed an **EIP-170** size blocker (vault 26411→24237 B via the `VaultTradeLib` delegatecall split). Shipped as **PR #17** (`fix/G2-coredepositwallet-bridge` → main, commit `e6a171f`); fork **54/0/4**, unit **10/10**. Caveats now baked in: ~0.00134 USDC withdrawal fee ⇒ never pull the exact full Core balance; 1.0 USDC one-time first-push activation gas; the wallet is Circle-operated/upgradeable/pausable (issuer trust; both directions pause together — `operatorRecoverSpot`/USDT0 are the documented contingencies). _(Historical: the original 2026-06-03 spike on `0x5DE2…3b26` concluded "bridge dead, need Path-B treasury" — right observations, wrong interpretation; the asset IS usable via the wallet. The escape-hatch permissionless leg is scoped in `docs/ESCAPE_HATCH_SCOPE.md`.)_
- **Roles:** `DEFAULT_ADMIN_ROLE` (should be the TimelockController), `OPERATOR_ROLE` (trades), `EMERGENCY_ROLE` (pause/close). Trade guards: perp/spot **whitelist**, `leverageCapBps`, `slippageBandBps` + per-spot `spotSlippageBandBps`.
- **Audit mitigations baked in:** C-2 `spotRecoverDest` allowlist (operator can't drain Core spot anywhere); C-3 no-dilution perf fee; H-1 strict NAV reads; H-2 strict `markPx` in leverage-notional (no silent drop); H-3 spot slippage band. Ultrareview fixes: bug_010 (cost-basis reset perf-fee evasion), bug_009 (emergency-close size scale), merged_bug_002 (`withdraw` `assets` is gross), bug_007 (leverage-cap lenient read — documented deliberate).

## HyperCore encoding gotchas (these have bitten repeatedly — get them right)

- **`limit_order` `px` AND `sz` are `round(human * 10^8)`** — a **uniform 10^8 scale, NOT szDecimals-based**. Wrong scale → HyperCore reads sub-cent dust below the **$10 min notional** and **silently drops** the order. This (not the TIF) was the root cause of the "HL won't take orders from a contract" saga; fixed in v1.3.
- **Read precompiles use a different scale:** `oraclePx`/`markPx` return `human * 10^(6 - szDecimals)`. Normalize before comparing to action-scale prices.
- **TIF is 1-indexed:** `1=ALO, 2=GTC, 3=IOC` (no FOK). `tif=0` is invalid and silently dropped.
- **CoreWriter is fire-and-forget:** the EVM tx succeeds and events fire **even if HyperCore rejects the action** (place ≠ fill). Reconcile off-chain.
- **`spot_send` (action 6) is SILENTLY DROPPED for unified accounts — use `send_asset` (action 13).** Proven live 2026-06-15: `pullFromCore` via `spot_send` emitted the action and `BridgeWithdraw`, but Core never debited (no ledger entry). The Core↔EVM USDC withdrawal MUST use `send_asset` (`CoreWriterLib.sendAsset`): payload `abi.encode(recipient, address(0), sourceDex, destDex, token, amount)`, 8dp; to withdraw to EVM set `recipient` = the token system address `0x2000…`, `sourceDex == destDex ==` Core Spot (`uint32.max`), and the linked contract pays the **caller** native USDC = `amount/100`. Same fix applied to `operatorRecoverSpot`/`emergencyRepatriate`. **Withdrawal fee ~0.00134 USDC** is taken from Core on top of the amount, so **never request the exact full Core balance** (it's dropped — the fee can't be covered); the keeper pulls `balance × 0.998`. A vault's **first push costs 1.0 USDC** account-activation gas (one-time).
- **EIP-170 (24576-byte runtime limit) IS enforced on HyperEVM.** The G2 vault hit 26411 B; no optimizer/`via_ir` setting fit. The trade gate (whitelist + slippage band + leverage cap) and the emergency-close loop now live in an external delegatecall library `src/libraries/VaultTradeLib.sol` (vault → 24237 B). It's pure logic under delegatecall (`address(this)` = the vault), holds no storage; events/errors re-declared so logs/selectors are identical. **`forge script` deploys+links it automatically**; for a manual deploy, `forge create` the lib then pass `--libraries src/libraries/VaultTradeLib.sol:VaultTradeLib:<addr>`. Fork tests miss this (revm doesn't enforce EIP-170) — only `forge script`/real deploy catches it. **M4/M5 added three more delegatecall libs the same way** (`VaultEmergencyLib`, `VaultEscapeLib`, `VaultBarrierLib`); the vault sits ~23.6–24.4 KB with a small margin — run `forge build --sizes` on any change. **`HyperCoreVaultFactory` is ~40 KB (over EIP-170) but is NOT on the deploy path** — `script/Deploy.s.sol` uses direct `new HyperCoreVault(cfg)`; the EIP-1167 minimal-proxy factory refactor is deferred (SOLU-3378).
- **A forge fork CANNOT run the HyperCore precompiles (`0x0800–0x0810`)** — Foundry's revm doesn't implement them, so on a fork they read empty ⇒ lenient `PrecompileLib` wrappers return 0 and `totalAssets() == idleUsdc()` (Core/perp NAV reads as 0). Consequences for fork tests: NAV>idle states (partial-fill, redeem-race) are **not fork-representable without mocking** → prove them live; and linkage/price/balance precompile reads must be done via a **live `eth_call`** (e.g. `scripts/python/resolve_usdc_linkage.py`), not a fork. `@hyper-evm-lib/` is **remapped but NOT vendored** in this repo, so `CoreSimulator` is unavailable.
- `Constants` are compile-time inlined → a wrong value requires **redeploy**, not a hot-fix.

## `vaults.md` — multi-venue scoping (proposal, not current code)

Evolves this vault into an EVM/venue-agnostic system (Hyperliquid, Avantis, Lighter, Hibachi). Key idea: **custody and NAV are separable trust axes**; specialize Class-A trustless-NAV paths, share everything else. De-risk spike status:

- **D1** (HL order rests) — ✅ closed (8/8 rested live).
- **D2** (Lighter custody) — ✅ **fork-confirmed** on real mainnet bytecode (`test/fork/LighterCustody.fork.t.sol`, 6/6): a contract is a first-class L1 owner, withdrawals are destination-bound, 14-day permissionless Desert-Mode escape ⇒ **A-custody / B-NAV**. Off-chain trade-restriction (testnet) still pending.
- **D3** (Hibachi destination) — 🔴 leans RED (arbitrary operator-signable `withdrawAddress`); Arbitrum fork + live-API spike pending.

**De-risk rule (the user enforces this):** never conclude from mocks or docs — every spike must reproduce on a **forked-mainnet harness (real deployed bytecode)** or a live testnet/API. Docs set the hypothesis; the spike is the proof.

## Conventions / don't-re-flag

- The original Foundry suite (`test/audit/Mitigations.t.sol`, `test/unit|integration|mocks/*`) was **intentionally deleted** in `33b5149` (suite being rewritten) — don't treat its absence as a mistake. Current tests: `test/RemediationUltrareview.t.sol` (legacy mock suite — superseded for liveness/redemption proofs) + `test/fork/LighterCustody.fork.t.sol` (D2) + the **`test/fork/HyperVault*.fork.t.sol`** suite on real HyperEVM bytecode — `{Base, Liveness, QueueAccounting, Governance, Linkage, FeeTransfer, SpotBand, CoreDepositWallet, Escape, EscapeTrigger, EscapePull, Barriers, KeeperEdge, BattleMatrix}` (needs `HYPEREVM_RPC_MAINNET`, skips cleanly without). As of 2026-06-18 `forge test` is **117 pass / 0 fail / 7 live-only skips** (the +4 over the M5 baseline are the M6/M7 `BattleMatrix` tests — multi-LP concurrency + full-escape e2e). Originals of the deleted suite are on history if needed.
- `vaults.md` is refined via Ultraplan — acknowledge handoffs; don't auto-exit plan mode. Keep its 🟢🟡🔴 / ✅❌⏳ status markers; decorative emojis and story-point sizing were intentionally stripped.
- Commit/push only when asked.
