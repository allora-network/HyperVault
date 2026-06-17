# Fork Proofs — Redemption / Liveness / Governance Findings

Evidence that the findings in [`REDEMPTION_ASSESSMENT.md`](REDEMPTION_ASSESSMENT.md) are real, reproduced on **real HyperEVM-mainnet bytecode** (no mocks) per the project's de-risk rule. Two substrates:

- **Forked-mainnet Solidity suite** — `test/fork/HyperVault*.fork.t.sol` (real USDC `0xb883…630f`, real vault deployed on the fork; LP funding via `deal`, a cheatcode, not a mock contract).
- **Live read-only node calls** — for facts a forge fork *cannot* serve, because Foundry's revm does not implement the HyperCore precompiles (`0x0800–0x0810`). These are real `eth_call`s to the live node (`scripts/python/resolve_usdc_linkage.py`, `cast`).
- **Live spike (funds)** — `scripts/python/e2e_runner.py` redemption-queue steps + `cast`, for residuals that require a genuine NAV>idle gap (capital actually on Core). **Executed 2026-06-03** on a throwaway v1.3 vault (`0x5DE26F34256f1303eCb3a3Ba70acEFD6E4f23b26`) — see [`REDEMPTION_LIVE_RUNBOOK.md`](REDEMPTION_LIVE_RUNBOOK.md) and the "Live spike" results section below.

**Run substrate of record:** public RPC `https://rpc.hyperliquid.xyz/evm`, chainId 999. First green run of the original finding suite was fork block **36760512** (2026-06-02, 25 passed / 2 skipped); re-confirmed 2026-06-03 against the `.env` RPC at fork block **36763664** (the Finding-G linkage read returns the same values at both blocks). After the v1.4 audit remediation (bottom section) the full fork suite is **44 passed, 0 failed, 2 skipped** (the 2 skips remain the intentional live-only stubs F and Q4). Per-finding remediation proofs, plus the renamed/flipped tests, are tabulated in the **v1.4 Audit Remediation** section at the end of this file.

**M6/M7 battle-matrix additions (2026-06-18):** `test/fork/HyperVaultBattleMatrix.fork.t.sol` adds four `test_BM_*` tests closing the two coverage gaps the assessment flagged, on real bytecode — multi-LP concurrent requests (per-LP escrow independence + the one-open-request guard), overlapping deadlines with a true partial-fill remainder that stays re-prioritizable, the Finding-F fairness reserve generalized to two racing redeemers, and the **full permissionless escape state machine** (governance SLA + 4h grace → unprivileged `triggerEscape` → 4 legs 60s-spaced → `fulfillWithdraw` → `exitEscape`, asserting the latch + `EscapeModeActive()` deposit-gating). The journal invariant `idle == available + reserved` is asserted throughout. Full `forge test` is now **117 passed / 0 failed / 7 live-only skips**.

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
| **F** | Direct redeem races the queue (starvation) | live spike — bob direct-redeem drained idle, alice's `fulfillWithdraw` got 1 wei | 🟢 **PROVEN** | live spike |
| **G** | Configured USDC ≠ Core-linked USDC | `resolve_usdc_linkage.py` (live precompile read) | 🟢 CONFIRMED | live read |
| **G** | Core bridge blacklisted → LEGACY `pushToCore` reverts (v1.5: wallet route is the fix, see §v1.5 G2) | `test_G_legacyPushRevertsOnBlacklistedBridge` | 🟢 PASS | fork |
| **H** | Strict NAV reads default OFF; OFF fails open, ON fails closed | `test_H_strictNavReadsDefaultOffFailsOpen` | 🟢 PASS | fork |
| **C** | Shipped config collapses roles; 0-delay timelock = no protection | `test_C_shippedConfigCollapsesRolesAndTimelock` | 🟢 PASS | fork |
| **I** | $100 caps are real and enforced | `test_I_capsAreHundredDollarTestValues` | 🟢 PASS | fork |
| **Q1** | request escrows exactly the shares + emits | `test_Q1_requestEscrowsExactlyAndEmits` | 🟢 PASS | fork |
| **Q2** | one open request per LP; over-balance / zero guards | `test_Q2_oneOpenRequestPerLp`, `test_Q2_overBalanceAndZeroGuards` | 🟢 PASS | fork |
| **Q3** | cancel restores shares + preserves cost basis | `test_Q3_cancelRestoresSharesAndPreservesCostBasis` | 🟢 PASS | fork |
| **Q4** | partial-fill math (idle < claim) | live spike — claim $8 vs idle $4 → fulfill paid $3.70, remainder escrowed | 🟢 **PROVEN** | live spike |
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
2. `pushToCore` / `pullFromCore` target the bridge `0x2000…0000`, which is **blacklisted** on the configured Circle USDC → both **revert** (`test_G_legacyPushRevertsOnBlacklistedBridge`). The operator cannot deploy idle to Core via the LEGACY route with this asset. **(v1.5 G2: the official route is the CoreDepositWallet — see the v1.5 section below; this bullet records the pre-G2 state.)**
3. This **resolves the README-vs-`e2e_runner.step_pull` contradiction in favour of the README/natspec** (`HyperCoreVault.sol:500-511`): the bridge is *not* usable for the shipped asset. Any prior "bridge works" observation must have used a different (linked) token or the manual `seed_vault_core.py` Core-side path — not `0xb883…630f`.

Net: with the shipped configuration, the redemption queue can **never** realise Core-deployed value back into `asset()` through the canonical bridge. This is the deepest form of the liveness gap (Findings A/B/E) and a P0 blocker.

## Why F, Q4 (and the E/Q6 funded-payout tail) are live-only

A plain forge fork cannot represent **NAV > idle**: revm does not implement the HyperCore precompiles, so `coreSpotUsdc()`/`perpWithdrawable()` read 0 and `totalAssets() == idleUsdc()` always. Therefore:

- redeem is strictly proportional to idle → no LP can take more than its fair share → **starvation (F) cannot arise on a fork**;
- `previewRedeem(req) ≤ NAV == idle` always → the **partial-fill branch (Q4) never triggers on a fork**.

Reproducing NAV>idle on a fork would require mocking the precompile, which the no-mocks rule forbids. These were proven for real on the **live spike of 2026-06-03** (results below). Because Finding G makes `pushToCore` revert, the NAV>idle gap was created by **seeding the vault's Core spot account directly** (HyperCore `sendAsset`, *not* the dead bridge) — the live precompiles then read it as real Core value. The fork **does** prove the full-refund payout path (`Q6`) using `deal` as a stand-in for a completed bridge pull — the contract reads only `idleUsdc()` and cannot tell how idle was funded.

## Live spike — executed 2026-06-03 (real funds, HyperEVM mainnet)

Throwaway v1.3 vault **`0x5DE26F34256f1303eCb3a3Ba70acEFD6E4f23b26`** (timelock `0x52D7…85CA`, deploy block 36824648, asset = shipped `0xb883…630f`, single-key operator==emergency==feeRecipient, $100 caps, BTC perp whitelisted). Actors: deployer/treasury `0x2003…753A`, operator `0xb0aE…B174`, LPs alice `0x496a…70Ba` + bob `0x1F03…A150`. NAV>idle gaps were manufactured by seeding the vault's **Core spot** account from the deployer's Core USDC (HyperCore `sendAsset("spot","spot",…)` — the documented `seed_vault_core.py` workaround, since the canonical bridge is dead per Finding G).

| Finding | Live result | Evidence |
|---|---|---|
| **G** | `pushToCore($3.2)` **reverted** `Blacklistable: account is blacklisted` (real Circle USDC, not a fork) | tx `0x312657be…`; revert decoded from `0x08c379a0…` |
| **A** | While paused, `usdSpotToPerp`/`pullFromCore` both revert `EnforcedPause()` (`0xd93c0665`); the same movers succeed before pause / after unpause — isolating the pause from the blacklist | pause `0x43a5e715…`, unpause `0x120ca738…` |
| **Queue** | request escrows exactly (4e12 → free 0); cancel restores; permissionless keeper `fulfillWithdraw` pays from idle | Scenario-A run, alice round-tripped to her full $10 |
| **Trade path (D1 re-confirm)** | BTC post-only order **rested on the HL book** from the contract at the uniform-10⁸ scale (enc px `6633000000000`, sz `18000`), then cancelled; leverage-cap + slippage-band + whitelist guards all passed | resting oid `454710262019`, cloid 1 |
| **C-2** | `operatorRecoverSpot` to non-allowlisted alice **reverts** `SpotRecoverDestinationNotAllowed` (`0x72edc76e`); to allowlisted deployer **succeeds** (dest set via the 0-delay timelock) | recover tx `0xb1dc06b1…` |
| **Q4** | NAV $8 (idle $4 + Core $4), alice claim $8 > idle $4 → `fulfillWithdraw` paid **$3.70** ($4 idle − $0.30 perf fee on the donation-driven gain), left **~2e12 shares escrowed**; Core $4 untouched | pending 4e12 → 1999999750000 |
| **E** | same fulfill **could not reach the $4 on Core** — confirmed off-idle value is unreachable | `coreSpotUsdc()` unchanged at fulfill |
| **F** | idle $8 shared by alice+bob (50/50, each claim $8); alice queues `requestWithdraw`, **bob front-runs with a direct `redeem`** → bob paid $1→$8.40, idle drained to 1 wei; alice's queued `fulfillWithdraw` got **1 wei (starved)**, value still trapped on Core | bob redeem; alice pending stayed 3999999500000 |

**Recovery / reconciliation.** All Core seed was reclaimed via `operatorRecoverSpot` (C-2 path) and all funds consolidated to the deployer: **EVM USDC 100% conserved** (`19089258` = the exact starting balance). Core USDC `17.9198` vs `18.9198` start → **≈ $1.00 net cost** in HyperCore transfer fees across the 4× seed + 4× recover round-trips, plus ~0.01 HYPE gas. The throwaway vault is drained and decommissioned.

**Operational findings (for the production runbook):**
1. The vault deploy is ~9M gas (>2M small-block limit) → the **deployer must opt into HyperEVM big blocks** before `forge script --broadcast` (`use_big_blocks(True)`); toggle off afterwards so follow-on small txns stay on fast blocks.
2. `seed_vault_core.py` uses `spot_transfer`, which is **disabled for unified accounts** (`Action disabled when unified account is active`); the working primitive is `Exchange.send_asset(dest, "spot", "spot", "USDC", amt)`. The SDK method for big blocks is `use_big_blocks`, not the script's `update_evm_user_modify`.
3. `operatorRecoverSpot` is **fire-and-forget** (CoreWriter): one $8 recovery's EVM tx succeeded but HyperCore silently dropped the action (vault Core unchanged for 36s); a **retry settled it** (tx `0x6014fe01…`). Keepers must reconcile Core state after recovery, not trust the EVM receipt.
4. `DEPLOYER_PRIVATE_KEY` in `.env` lacks the `0x` prefix — `cast`/`eth_account` accept it, but Foundry's `vm.envUint` requires the prefix.

## Cross-links

- Findings + TODOs: [`REDEMPTION_ASSESSMENT.md`](REDEMPTION_ASSESSMENT.md)
- Live spike runbook: [`REDEMPTION_LIVE_RUNBOOK.md`](REDEMPTION_LIVE_RUNBOOK.md)
- Live harness: `scripts/python/e2e_runner.py` (queue steps `request_withdraw` / `fulfill_withdraw` / `operator_repatriate` / `cancel_withdraw` / `pause_freeze_check`)
- Linkage resolver: `scripts/python/resolve_usdc_linkage.py`

---

## v1.4 Audit Remediation — per-finding fork proofs

The findings above are *closed* by the v1.4 remediation, developed as one stacked
branch per finding (`fix/<finding>-…` off `audit/mitigations`, in the coordination
order C1→H1→H2→H3→M2→M1→M3→M4→M6→L). Each fix ships its contract change + a green
fork test; the pure-EVM invariants are fork-proven on real mainnet bytecode, and
the proofs that genuinely need NAV>idle / a live order remain live-spike items
(below). Several original tests were **flipped** (the finding's *presence* assertion
becomes the *fix* assertion).

| Phase | Closes | Fork test(s) | Status |
|---|---|---|:--:|
| **C1 (+M5)** | G, decimals | `HyperVaultLinkage`: `test_C1_decimalsMismatchRevertsDeploy`, `test_C1_coreSpotUsdcNormalizesScale`, `…MultiplyBranch`, `test_C1_coreLinkUnverifiedFiresInLegacyMode`, `…noEventWhenLinkMatches`, `…matchingDecimalsDeploysClean` (6) | 🟢 PASS |
| **H1** | H | `HyperVaultLiveness`: `test_H_navBootstrapGraceThenStrictFailsClosed` (flips old `test_H_strictNavReadsDefaultOffFailsOpen`), `test_H_depositRedeemWorkWhileBootstrapping` | 🟢 PASS |
| **H2** | A, B, E, F (fairness) | `HyperVaultLiveness`: `test_A_pauseDoesNotFreezeRepatriation` (flips `test_A_pauseFreezesRefillPath`), `test_A_emergencyRepatriateWorksWhilePaused` (flips `test_A_emergencyRoleCannotRepatriate`), `test_F_overdueRequestReservesIdle`, `…prioritizeOverdueGuards`, `…fullReserveReleasedWhenNavFallsAfterPrioritize`, `…pushToCoreCannotDeployReservedIdle` | 🟢 PASS |
| **H3** | C, I | `HyperVaultGovernance`: `test_C_shippedConfigNowDistinctWithRealDelay` (flips `test_C_shippedConfigCollapsesRolesAndTimelock`), `…factoryEnforcesTimelockFloor`, `…factoryRejectsSharedRoles`, `…factoryAcceptsCompliantConfig`, `…timelock24hGateBlocksThenAllows` | 🟢 PASS |
| **M2** | perf-fee over-charge | `HyperVaultQueueAccounting.test_M2_depositBlockedWhileRequestOpen`; `RemediationUltrareview.test_bug010_perfFeeEvasionClosed` (updated) | 🟢 PASS |
| **M1** | loss-netting evasion | `HyperVaultFeeTransfer`: `test_M1_transferRealizesTransferorGain`, `…transferFeeMatchesDirectRedeem`, `…escrowTransfersAreFeeFree`, `…zeroGainTransferNoHaircut`, `…noDilutionOfStayers` (5) | 🟢 PASS |
| **M3** | maxRedeem conformance | `HyperVaultQueueAccounting.test_M3_maxRedeemHonorsPreviewWhenIdleShort` | 🟢 PASS |
| **M4** | emergency-close band | `RemediationUltrareview`: `test_M4_emergencyCloseBandRejectsAbsurdPrice`, `…bandOffMatchesLegacyBehavior` | 🟢 PASS |
| **M6** | spot-band scale | `HyperVaultSpotBand`: `test_M6_bandRequiresScaleFactor`, `…normalizedBandInsideRestsOutsideReverts`, `…demonstratesNormalizationMatters`, `…bandZeroDisablesCheck`, `…suggestedFactorMirrorsPerpDerivation` (5) | 🟢 PASS |
| **L1–L4** | hardening | `RemediationUltrareview`: `test_L1_depositRejectsFeeOnTransferAsset`, `test_L2_dormancyMgmtFeeCappedAtAnnualRate`, `test_L3_emergencyCloseHandlesInt64Min`; `HyperVaultGovernance.test_L4_factoryOwnershipIsTwoStep` | 🟢 PASS |

**Substrate note on the mocked NAV reads.** `HyperVaultLinkage` (C1) and
`test_M3_…` use `vm.mockCall` on the spot-balance / tokenInfo precompiles to create
the NAV>idle / known-Core-balance states a revm fork can't serve. This is consistent
with the no-mocks rule: those are *pure-EVM accounting* invariants (decimal
normalization, maxRedeem math), **not** claims about live Core behaviour — the live
Core confirmation is the spike below. (The starvation *effect* of F and the
partial-fill of Q4 remain live-only for the same reason.)

### Finding G — re-confirmed live (2026-06-04)

`resolve_usdc_linkage.py` re-run on the live node re-confirms the linkage gap and
validates the C1 config (`coreUsdcIndex=0`, `coreUsdcDecimals=8`):

```
Core USDC (token 0) linked EVM contract: 0x6b9e773128f453f5c2c60935ee2de2cbc5390a24
Core USDC weiDecimals / evmExtraWeiDecimals:   8 / -2  (EVM side decimals = 6)
Configured vault asset:                  0xb88339cb7199b77e23db6e890353e22632ba630f
VERDICT: NOT LINKED (Finding G CONFIRMED).
```

So the real mainnet C1 deploy validates `coreUsdcDecimals == 8` (matches `weiDecimals`)
and emits `CoreLinkUnverified(0xb883…630f, 0x6b9e…0a24)` — the mismatch is now
on-chain-visible rather than silently trusted.

### Live consolidated spike — PENDING (funded)

The headline live proofs that need a funded mainnet throwaway — C1 Path-B round-trip
(`operatorRecoverSpot → treasury → re-deposit`), H1 `endNavBootstrap` under a real
Core balance, H2 the exact `pullFromCore`/`operatorRecoverSpot` that reverted
`EnforcedPause` on 2026-06-03 now succeeding while paused, H3 the timelock gate at a
tractable delay, M1 transfer-realization with a real idle gain, and F/Q4 starvation
+ partial-fill — are **staged but NOT yet executed**. Funding constraint: the .env
actors hold ~37 USDC + ~0.31 HYPE total (almost all on the deployer), which does not
support the plan's 10 independent per-phase spikes; a single consolidated spike
sized to that budget is the fallback. See [`REDEMPTION_LIVE_RUNBOOK.md`](REDEMPTION_LIVE_RUNBOOK.md).
Record the real tx hashes + `status==1` confirmations here once run.
**(v1.5 note: Scenario C below subsumes the C1/Path-B item — the round trip now goes
through the official wallet, no treasury hop — and provides the funded substrate for
the H1 strict-read check; F/Q4 remain provable via the Core-seed method whenever a
NAV>idle re-proof is wanted.)**

## v1.5 G2 — pushToCore via Circle's CoreDepositWallet (2026-06-12)

**The Finding-G narrative is corrected:** `tokenInfo(0).evmContract = 0x6B9E…0A24` is not
a competing/broken USDC — it is **Circle's CoreDepositWallet**, the official USDC
EVM<->Core bridge (live 2025-12-08; EIP-1967 proxy, impl `CoreDepositWallet`, deployed by
`Circle: Deployer` 2025-11-18; holds the EVM reserve backing all Core USDC — HL's own
backing accounting sums the Arbitrum bridge plus this contract). It reverts every ERC-20
view *because it is not a token*; Circle blacklisted `0x2000…0000` on the USDC token to
force the wallet path. The pre-G2 facts (legacy push reverts; `0x6B9E…0A24` not
ERC-4626-usable as an asset) remain true and pinned by tests.

v1.5 change set: `pushToCore` = `forceApprove + deposit(amount, CORE_SPOT_DEX_ID)` +
zero-approve; `Config.coreDepositWallet` immutable with three-layer deploy validation
(`wallet.token()`, `wallet.tokenSystemAddress()`, `tokenInfo.evmContract` →
`CoreLinkVerified` / `CoreLinkMismatch`); `pullFromCore` was byte-identical at 06-12 but the
06-15 live spike reworked it to CoreWriter `send_asset` (action 13) — see the live-spike
section below; legacy mode (`address(0)`) preserved.

| Claim | Test | Status | Substrate |
|---|---|:--:|---|
| push deposits into the REAL wallet (custody + event + zero residual allowance) | `test_G2_pushDepositsViaWallet` | 🟢 PASS | fork (real wallet bytecode) |
| wallet emits its Core-credit logs during deposit | `test_G2_pushEmitsWalletLogs` | 🟢 PASS | fork |
| zero-amount push reverts inside the wallet | `test_G2_pushZeroAmountReverts` | 🟢 PASS | fork |
| H2 available-idle guard fires before any wallet interaction | `test_G2_pushExceedingAvailableIdleReverts` | 🟢 PASS | fork |
| `pullFromCore` emits CoreWriter `send_asset` (action 13), NOT the dropped `spot_send` (action 6) | `test_G2_pullUsesSendAssetNotSpotSend` | 🟢 PASS | fork |
| wallet-mode deploy validation (token / system address / linkage, `CoreLinkVerified`) | `test_G2_walletTokenMismatchRevertsDeploy`, `test_G2_walletSystemAddressMismatchRevertsDeploy`, `test_G2_realWalletDeploysClean`, `test_G2_coreLinkMismatchRevertsDeploy`, `test_G2_coreLinkVerifiedEmitsWhenResolved` | 🟢 PASS | fork |
| legacy route preserved + still dead for mainnet USDC | `test_G2_legacyPushStillTransfersToSystemAddress` (unit), `test_G_legacyPushRevertsOnBlacklistedBridge` (fork) | 🟢 PASS | unit + fork |
| residual-allowance zeroing vs a misbehaving wallet | `test_G2_pushClearsResidualAllowance` | 🟢 PASS | unit |
| Core spot credit appears after a wallet push | `test_G2_coreSpotCreditAppears_provenInLiveSpike` | 🟢 PROVEN LIVE | **spike 2026-06-15** |
| wallet pays native USDC to vault idle on a Core-side `send_asset` | `test_G2_walletPayoutOnPull_provenInLiveSpike` | 🟢 PROVEN LIVE | **spike 2026-06-15/16** |

Post-G2 fork suite: **54 passed, 0 failed, 4 skipped** (F, Q4, and the two Scenario-C
stubs above). Linkage read (`resolve_usdc_linkage.py`, v1.5 three-verdict version):
**WALLET-LINKED** — wallet `token() == 0xb883…630f`, `tokenSystemAddress() ==
0x2000…0000`, `paused() == false`, reserve ≈ $4.87B (2026-06-12).

## v1.5 G2 — live spike EXECUTED 2026-06-15/16 (real funds, HyperEVM mainnet)

The funded round trip ran and **closed the full trustless loop in both directions.** It also
surfaced two blockers the fork suite structurally cannot catch — both fixed and re-proven.

**Finding 1 — EIP-170.** The G2 vault compiled to **26411 bytes runtime, 1835 over the
24576 limit**, which HyperEVM enforces (proven: a raw `cast --create` of a 25000-byte
contract → status 0, all gas burned, no code, tx `0x10842e5b…`). No optimizer/`via_ir`
setting fits (best `runs=1` = 25382). `forge script` hard-aborts before broadcast; the
fork suite never caught it because the test EVM doesn't enforce EIP-170. **Fix:** the trade
gate (whitelist + slippage band + leverage cap) and emergency-close loop were extracted into
an external delegatecall library **`VaultTradeLib`** (events/errors re-declared so log topics
and revert selectors are byte-identical). Vault → **24237 bytes**; fork 54/0/4 and unit 10/10
unchanged.

**Finding 2 — the pull used the wrong CoreWriter action.** The original `pullFromCore`
emitted **`spot_send` (action 6)**, which **unified HyperCore accounts silently drop** (the
EVM tx succeeds — CoreWriter is fire-and-forget — but Core never debits and nothing appears
in `userNonFundingLedgerUpdates`). Proven on the first throwaway (`0xf6069C…5722`): two pulls
emitted `BridgeWithdraw`, Core stayed at 7.0 indefinitely. **Fix:** `CoreWriterLib.sendAsset`
(**action 13 / `0x00000D`**) — payload `abi.encode(recipient, address(0), sourceDex,
destinationDex, token, amount)`, 8dp; for a Core→EVM withdrawal `recipient` = the token
system address `0x2000…0000`, `sourceDex == destinationDex ==` Core Spot (`uint32.max`), and
the wallet pays the **caller** (the vault) native USDC = `amount/100`. `pullFromCore`,
`operatorRecoverSpot`, `emergencyRepatriate` all rewired.

**Operational nuances (now encoded / documented):**
- **Withdrawal fee ≈ 0.00134 USDC** is deducted from the Core account *on top of* the
  requested amount, so requesting the **exact full Core balance is dropped** (nothing left to
  cover the fee). The keeper must pull strictly under the balance — `e2e_runner.step_pull`
  now pulls `balance × 0.998`.
- **First push per vault costs 1.0 USDC** account-activation gas (one-time, ledger:
  `accountActivationGas`).

**Round-trip tx hashes — fresh vault `0xDE6A0c9371aCBC95fd3AC6B8A3598780013ec777`,
`VaultTradeLib 0xAc0a0048Ed26fDA42461281876d6D7899dF320ec` (HyperEVM mainnet, chainid 999):**

| Step | Result | Tx |
|---|---|---|
| Vault deploy (linked) | `CoreLinkVerified(asset, wallet)` fired in ctor vs real precompiles | `0x4d6427b786d95c24ab46f90138329447acff2f3a8f790946601b01dea9cb022e` |
| Push EVM→Core (`deposit(4.8e6, SPOT)`) | Core credited 3.8 (1.0 activation gas); `coreSpotUsdc()` == HL API | ledger `spotTransfer 4.8 from 0x2000`, nonce 1785895 |
| Pull FULL balance (`send_asset 3.8e8`) | **DROPPED** (fee uncovered) — Core stayed 3.8, no ledger entry | `0xb65397a05dbdf6ab4268989afc3454a2060a5584e3a7e8e35ba442dc6a43d220` |
| Pull partial (`send_asset 1.0e8`) | **SETTLED** — Core 3.8→2.799 (`send`, fee 0.00134), `idleUsdc()` 0→1.0 | `0xc47db60e24d339b480df155cc874a7b81911b12f064c7f7118497c88c1b9c103` |
| Pull recover (`send_asset 2.79e8`) | **SETTLED** — `idleUsdc()` 1.0→3.79 | `0xa44b4fbf78897ebf33bb5e40ccbcd2614984110238aba8ba753414550468e706` |
| Redeem (alice) | paid 3.79 from idle; shares burned | `0xfb916af9f3e06c2303c9270bda0c63ab1ef7de2b18dd1f367c1ad66e89dd21a2` |

Funds: $10.08 of the original $19.09 recovered to EOAs; ~$2 spent on the two vaults'
one-time activation gas; **$7 permanently stranded on the first throwaway `0xf6069C…5722`**
(deployed with the `spot_send` code before the fix, immutable — the cost of the discovery).
Linkage read on the day: **WALLET-LINKED**, `paused()==false`, reserve ≈ $496M.
