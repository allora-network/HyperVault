// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC4626, IERC20, ERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IHyperCoreVault} from "./interfaces/IHyperCoreVault.sol";
import {ICoreDepositWallet} from "./interfaces/ICoreDepositWallet.sol";
import {CoreWriterLib} from "./libraries/CoreWriterLib.sol";
import {PrecompileLib} from "./libraries/PrecompileLib.sol";
import {SystemAddress} from "./libraries/SystemAddress.sol";
import {AssetId} from "./libraries/AssetId.sol";
import {Constants} from "./libraries/Constants.sol";
// Audit G2 (EIP-170): trade-gate + emergency-close logic lives in an external
// delegatecall library so the vault's runtime bytecode fits the 24576-byte limit.
import {VaultTradeLib} from "./libraries/VaultTradeLib.sol";
// M5 (EIP-170): the permissionless escape-hatch crank bodies live in an external
// delegatecall library for the same reason — see {VaultEscapeLib}.
import {VaultEscapeLib} from "./libraries/VaultEscapeLib.sol";
// Audit G2 (EIP-170): the EMERGENCY_ROLE cancel + repatriate bodies live in an
// external delegatecall library for the same reason — see {VaultEmergencyLib}.
// (M5's latch pushed the vault back over 24576; externalizing the emergency
// surface — the established VaultTradeLib pattern — reclaims the headroom.)
import {VaultEmergencyLib} from "./libraries/VaultEmergencyLib.sol";

/// @title  HyperCoreVault — EIP-4626 vault that trades on HyperCore via CoreWriter
/// @notice One vault per strategy. Operator runs trades; depositors hold tokenized shares.
///         NAV is computed trustlessly from HyperCore precompiles.
///
///         See `docs/ARCHITECTURE.md` for design rationale and
///         `docs/INTEGRATION.md` for live-runner integration.
contract HyperCoreVault is IHyperCoreVault, ERC4626, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    // -------------------------------------------------------------------------
    // Roles
    // -------------------------------------------------------------------------

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // -------------------------------------------------------------------------
    // Constructor params (immutable per vault)
    // -------------------------------------------------------------------------

    struct Config {
        IERC20 asset; // USDC ERC20 on HyperEVM
        uint64 coreUsdcIndex; // Core spot token index for USDC (canonical mainnet = 0)
        uint8 coreUsdcDecimals; // Core wei decimals for that token (validated vs live tokenInfo at deploy)
        address coreDepositWallet; // Circle CoreDepositWallet for EVM->Core deposits (audit G2); 0 = legacy HIP-1 route
        string name;
        string symbol;
        address admin; // DEFAULT_ADMIN_ROLE — should be a TimelockController
        address operator;
        address emergencyAdmin;
        address feeRecipient;
        uint16 leverageCapBps;
        uint16 slippageBandBps;
        uint16 mgmtFeeAnnualBps;
        uint16 perfFeeBps;
        uint256 depositCap;
        uint256 maxDepositPerAddress;
    }

    address public immutable feeRecipient;

    /// @notice Core spot token index this vault treats as its USDC for NAV
    ///         (`coreSpotUsdc`) and bridge/recover calls. Configured per-deployment
    ///         and validated against the live `tokenInfo` precompile in the
    ///         constructor (audit C1 / M5). Canonical mainnet value is 0.
    uint64 public immutable coreUsdcIndex;

    /// @notice Core wei decimals for {coreUsdcIndex}. Used to normalize the Core
    ///         spot balance into the 6dp EVM-USDC scale in {_coreToEvm}. Asserted
    ///         to equal `tokenInfo(coreUsdcIndex).weiDecimals` at deploy when the
    ///         precompile resolves — a wrong value would put NAV off by 10^|Δ|
    ///         (audit M5).
    uint8 public immutable coreUsdcDecimals;

    /// @notice Circle's CoreDepositWallet — the official EVM->Core deposit route
    ///         for natively-minted USDC (audit G2). When set, {pushToCore} runs
    ///         `approve + deposit(amount, CORE_SPOT_DEX_ID)` against it; when
    ///         `address(0)` the vault uses the legacy HIP-1 route (ERC20 transfer
    ///         to the token system address), which is only valid for assets whose
    ///         `tokenInfo.evmContract == asset()`.
    /// @dev    IMMUTABLE by design: a mutable fund-routing destination would hand
    ///         a compromised timelock a clean idle-drain lever (point it at an
    ///         attacker, wait for the next push). The wallet is an EIP-1967 proxy,
    ///         so Circle upgrades change the implementation, not this address; if
    ///         the address itself were ever migrated, only pushToCore breaks (new
    ///         deployments to Core), while {pullFromCore} (Core-side, follows the
    ///         live linkage) and every redemption path keep working — the remedy
    ///         is a vault redeploy, consistent with the repo's posture for
    ///         linkage params. Validated three ways at deploy; see constructor.
    address public immutable coreDepositWallet;

    // -------------------------------------------------------------------------
    // Mutable config (admin / timelock)
    // -------------------------------------------------------------------------

    uint16 public leverageCapBps;
    uint16 public slippageBandBps;
    uint16 public mgmtFeeAnnualBps;
    uint16 public perfFeeBps;
    uint256 public depositCap;
    uint256 public maxDepositPerAddress;

    EnumerableSet.UintSet private _whitelistedPerps;
    EnumerableSet.UintSet private _whitelistedSpots;

    // -------------------------------------------------------------------------
    // Runtime state
    // -------------------------------------------------------------------------

    uint128 private _cloidCounter; // monotonically increasing client order id
    uint64 private _lastAccrualTs; // last management-fee accrual timestamp
    bool public emergencyShutdownActive; // one-way switch

    /// @notice Per-LP cost basis per share, 1e18-fixed (price-per-share at entry).
    /// @dev    Updated on mint and on transfer between non-vault parties. Used
    ///         for crystallize-on-redeem perf fee.
    mapping(address => uint256) private _costBasisPerShare;

    /// @notice One pending withdrawal request per LP. Issue a new one only after
    ///         cancelling the existing one. The {IHyperCoreVault.WithdrawalRequest}
    ///         struct is declared on the interface (inherited here) so {VaultEscapeLib}
    ///         can read this mapping by storage reference across the M5 delegatecall
    ///         boundary (single source of truth — see the interface NatSpec).
    mapping(address => WithdrawalRequest) private _pendingWithdrawal;

    /// @notice On-chain fulfillment SLA window for withdrawal requests (audit H2 /
    ///         TODO-5). 0 = disabled. When > 0, {requestWithdraw} stamps a
    ///         `fulfillmentDeadline = now + window`; once it lapses, anyone may call
    ///         {prioritizeOverdue} to reserve the request's claim on idle ahead of
    ///         racing direct redeems, and the SLA breach is visible on-chain.
    uint64 public requestFulfillmentWindow;

    /// @notice Total idle assets reserved for overdue, prioritized requests (audit
    ///         H2 — Finding F fairness). Ordinary redeem/withdraw and the
    ///         fulfillment of NON-prioritized requests may not draw idle below this
    ///         floor; only the matching prioritized request's fulfillment releases it.
    uint256 private _reservedIdle;

    // -------------------------------------------------------------------------
    // Audit-mitigation state (v1.3)
    // -------------------------------------------------------------------------

    /// @notice Admin-managed allowlist of destinations for
    ///         `operatorRecoverSpot`. Mitigates audit finding C-2 — a
    ///         compromised OPERATOR key would otherwise be able to drain all
    ///         Core spot funds to any address.
    mapping(address => bool) public spotRecoverDest;

    /// @notice One-way "fresh vault" grace flag for NAV reads (audit H-1).
    /// @dev    While true (the deploy default), NAV-component reads (`coreSpotUsdc`,
    ///         `perpWithdrawable`) use LENIENT precompile wrappers — a precompile
    ///         that reverts / has no row reads as 0. This is the only safe posture
    ///         for a brand-new vault whose Core account has no precompile rows yet
    ///         (and it keeps revm-fork harnesses, which can't serve precompiles,
    ///         working). Once {endNavBootstrap} is called — after the Core account
    ///         is initialised by its first cross-chain action — this flips to false
    ///         PERMANENTLY and NAV reads become STRICT (fail-closed): any precompile
    ///         revert bubbles up rather than silently zeroing NAV and mispricing
    ///         shares. Strict is therefore the DEFAULT for a live vault — the
    ///         opposite of the prior `strictNavReads=false` footgun. Trade-off:
    ///         once strict, redemption liveness is coupled to precompile liveness
    ///         (why the grace exists; off-chain monitoring required — docs/SECURITY.md).
    bool public navBootstrap = true;

    /// @notice Per-spot-asset slippage band in bps. Mitigates audit finding
    ///         H-3 (spot orders previously had no slippage protection). 0 =
    ///         no band (legacy / opt-out). Compared against the NORMALIZED `spotPx`.
    mapping(uint32 => uint16) public spotSlippageBandBps;

    /// @notice Per-spot-asset multiplier that brings the `spotPx` precompile value
    ///         up to the `limit_order` action's 10^8 scale (audit M6). Required
    ///         (non-zero) whenever {spotSlippageBandBps} is set — the spot price
    ///         scale is HL-defined and asset-specific, so the admin calibrates this
    ///         from a live test order (see {suggestedSpotPxScaleFactor}) rather than
    ///         the contract guessing a factor that would give false protection.
    mapping(uint32 => uint64) public spotPxScaleFactor;

    /// @notice Sanity band (bps) for `emergencyClosePositions` limit prices vs the
    ///         strict markPx (audit M4). 0 = no band (default). Set WIDE (e.g.
    ///         1000-2000 bps) — looser than the trade-time band, since an emergency
    ///         must still be able to exit, but absurd prices on a thin market are
    ///         rejected so a compromised EMERGENCY key cannot bleed value.
    uint16 public emergencyCloseBandBps;

    // -------------------------------------------------------------------------
    // Escape-hatch state (M5 — permissionless "dead man's brake", Phase 1)
    //
    // docs/ESCAPE_HATCH_SCOPE.md §1/§4. Mirrors the {emergencyShutdownActive}
    // pattern: a latch the gates read. Unlike emergency shutdown the latch is NOT
    // one-way — it clears via {exitEscape} once the overdue backlog that armed it
    // is gone (§1: "until no overdue-unfillable request remains").
    // -------------------------------------------------------------------------

    /// @notice Escape-hatch latch + cooldown (M5 §1/§4). `_escape.active` is the
    ///         ESCAPE-mode latch: while true, deposits/mints and market-deploying
    ///         movers (`placeLimitOrder`, `pushToCore`, `usdSpotToPerp`) are blocked
    ///         and the three permissionless risk-reducing cranks ({escapeCancelOrders},
    ///         {escapeFlattenPerps}, {escapeConsolidateToSpot}) become callable;
    ///         redemption, the `pullFromCore`-family, `usdPerpToSpot`, and the
    ///         emergency surface are UNAFFECTED. `_escape.lastCrankTs` backs the
    ///         per-interval cooldown. The struct is threaded into {VaultEscapeLib} by
    ///         storage reference so the latch/cooldown bookkeeping lives in the
    ///         library (vault EIP-170 budget). Read {escapeActive} for the bool.
    /// @dev    Pause-immune by design (the brake cannot be vetoed by the
    ///         operator/emergency/admin keys — only clearing the overdue backlog via
    ///         {exitEscape} lifts it). NOT one-way (unlike {emergencyShutdownActive}).
    IHyperCoreVault.EscapeState private _escape;

    /// @notice Minimum seconds between escape cranks (M5 §4) — bounds HyperCore
    ///         action-rate exposure and forced-unwind griefing while the brake is
    ///         armed. A COMPILE-TIME CONSTANT (not admin-tunable): the cranks are
    ///         permissionless and pause-immune, so the cooldown is part of the brake's
    ///         fixed safety envelope — a mutable interval would hand a compromised
    ///         timelock a lever to throttle (or, at 0, un-throttle) a permissionless
    ///         safety mechanism. 60s is comfortably under any plausible HyperCore
    ///         action-rate limit (§5, live-verify) while keeping the unwind prompt.
    ///         The first crank after arming runs immediately (`lastCrankTs == 0`).
    uint64 public constant escapeCrankInterval = 60;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(Config memory cfg) ERC4626(cfg.asset) ERC20(cfg.name, cfg.symbol) {
        if (
            cfg.admin == address(0) || cfg.operator == address(0) || cfg.emergencyAdmin == address(0)
                || cfg.feeRecipient == address(0)
        ) revert ZeroAddress();
        if (cfg.mgmtFeeAnnualBps > 2_000 || cfg.perfFeeBps > 5_000) {
            // hard caps: 20% mgmt/yr and 50% perf — sanity, not a marketing limit
            revert InvalidFeeConfig(cfg.mgmtFeeAnnualBps, cfg.perfFeeBps);
        }

        feeRecipient = cfg.feeRecipient;
        coreUsdcIndex = cfg.coreUsdcIndex;
        coreUsdcDecimals = cfg.coreUsdcDecimals;
        coreDepositWallet = cfg.coreDepositWallet;
        // Audit C1/M5/G2: validate the Core-USDC linkage at deploy.
        //
        // WALLET MODE (cfg.coreDepositWallet != 0 — the official route for
        // natively-minted USDC): three layered checks, all fail-closed.
        //   (a)  wallet.token() must be asset() — direct positive check against
        //        the wallet's own bytecode; needs no precompile, so it protects
        //        fork deploys too. A codeless/wrong address reverts on decode.
        //   (a') wallet.tokenSystemAddress() must be the system address derived
        //        from the configured coreUsdcIndex — binds the wallet to the
        //        Core token the NAV reads, catching index typos with no precompile.
        //   (b)  when the `tokenInfo` row resolves (live chain): decimals must
        //        match (a mismatch silently mis-scales NAV by 10^|Δ| — M5), and
        //   (c)  tokenInfo.evmContract must BE the wallet — the pull path pays
        //        out through `tokenInfo.evmContract`, so a mismatch means push
        //        and pull would route through different contracts. On success
        //        the deploy emits {CoreLinkVerified} as an on-chain attestation.
        //
        // LEGACY MODE (cfg.coreDepositWallet == 0 — HIP-1 direct-linked assets,
        // unit tests): pre-G2 behavior byte-for-byte — decimals hard check plus
        // the warn-only {CoreLinkUnverified} surface when evmContract != asset().
        // When the precompile is empty (fresh Core account, revm fork), the
        // tokenInfo checks are skipped so deploys still work (H-1 grace posture).
        {
            if (cfg.coreDepositWallet != address(0)) {
                address walletToken = ICoreDepositWallet(cfg.coreDepositWallet).token();
                if (walletToken != address(cfg.asset)) {
                    revert CoreDepositWalletTokenMismatch(address(cfg.asset), walletToken);
                }
                address expectedSys = SystemAddress.forToken(cfg.coreUsdcIndex);
                address walletSys = ICoreDepositWallet(cfg.coreDepositWallet).tokenSystemAddress();
                if (walletSys != expectedSys) {
                    revert CoreDepositWalletSystemAddressMismatch(expectedSys, walletSys);
                }
            }
            PrecompileLib.TokenInfo memory ti = PrecompileLib.tokenInfo(uint32(cfg.coreUsdcIndex));
            bool resolved = ti.weiDecimals != 0 || ti.evmContract != address(0) || bytes(ti.name).length != 0;
            if (resolved) {
                if (ti.weiDecimals != cfg.coreUsdcDecimals) {
                    revert CoreUsdcDecimalsMismatch(cfg.coreUsdcDecimals, ti.weiDecimals);
                }
                if (cfg.coreDepositWallet != address(0)) {
                    if (ti.evmContract != cfg.coreDepositWallet) {
                        revert CoreLinkMismatch(cfg.coreDepositWallet, ti.evmContract);
                    }
                    emit CoreLinkVerified(address(cfg.asset), cfg.coreDepositWallet);
                } else if (ti.evmContract != address(cfg.asset)) {
                    emit CoreLinkUnverified(address(cfg.asset), ti.evmContract);
                }
            }
        }
        leverageCapBps = cfg.leverageCapBps;
        slippageBandBps = cfg.slippageBandBps;
        mgmtFeeAnnualBps = cfg.mgmtFeeAnnualBps;
        perfFeeBps = cfg.perfFeeBps;
        depositCap = cfg.depositCap;
        maxDepositPerAddress = cfg.maxDepositPerAddress;
        _lastAccrualTs = uint64(block.timestamp);
        _cloidCounter = 1; // start at 1 — cloid 0 means "no cloid" in HL conventions

        _grantRole(DEFAULT_ADMIN_ROLE, cfg.admin);
        _grantRole(OPERATOR_ROLE, cfg.operator);
        _grantRole(EMERGENCY_ROLE, cfg.emergencyAdmin);
    }

    // -------------------------------------------------------------------------
    // ERC4626 overrides
    // -------------------------------------------------------------------------

    /// @notice 6 decimals offset — share token is 12dp. Mitigates inflation attack
    ///         per OpenZeppelin's virtual-shares pattern.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @notice NAV = idle EVM USDC + Core spot USDC (decimal-normalized) + perp withdrawable.
    ///         Intentionally excludes mark-price PnL — uses HL's conservative
    ///         `withdrawable` figure for perp equity.
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        return idleUsdc() + coreSpotUsdc() + perpWithdrawable();
    }

    function maxDeposit(address receiver) public view override(ERC4626, IERC4626) returns (uint256) {
        // M5 §4: ESCAPE mode blocks deposits — entering a forced unwind is wrong-way
        // risk for a depositor (idle inflow would help exits, but simplicity +
        // wrong-way-risk argue for blocking; ESCAPE_HATCH_SCOPE §8 Q3).
        if (paused() || emergencyShutdownActive || _escape.active) return 0;
        uint256 capRemaining = depositCap > totalAssets() ? depositCap - totalAssets() : 0;
        uint256 perAddrRemaining;
        if (maxDepositPerAddress == 0) {
            perAddrRemaining = type(uint256).max;
        } else {
            uint256 ownedAssets = convertToAssets(balanceOf(receiver));
            perAddrRemaining = maxDepositPerAddress > ownedAssets ? maxDepositPerAddress - ownedAssets : 0;
        }
        return Math.min(capRemaining, perAddrRemaining);
    }

    function maxMint(address receiver) public view override(ERC4626, IERC4626) returns (uint256) {
        return convertToShares(maxDeposit(receiver));
    }

    /// @notice CRITICAL: bounded by idle EVM USDC so ERC4626 integrators don't get
    ///         silently reverted when the operator has parked capital on Core.
    function maxWithdraw(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
        uint256 ownedAssets = convertToAssets(balanceOf(owner));
        // Audit H2: bound by idle NOT reserved for overdue prioritized requests.
        return Math.min(ownedAssets, _availableIdle());
    }

    /// @notice Audit M3: cap to the shares whose `previewRedeem` fits in the idle
    ///         available for redemption, so `previewRedeem(maxRedeem(owner))` is
    ///         honored with no silent partial fill — symmetric with the
    ///         idle-bounded {maxWithdraw}. (Plain ERC-4626's full-balance maxRedeem
    ///         over-reports when the operator has parked capital on Core: a naive
    ///         integrator redeeming `maxRedeem` would receive less than
    ///         `previewRedeem(maxRedeem)`.) `convertToShares` rounds down, so the
    ///         cap never maps back above available idle. The withdrawal queue
    ///         (requestWithdraw) is the path for the remainder.
    function maxRedeem(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
        return Math.min(balanceOf(owner), convertToShares(_availableIdle()));
    }

    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (emergencyShutdownActive) revert EmergencyShutdownActive();
        if (_escape.active) revert EscapeModeActive(); // M5 §4
        // Audit M2: a deposit into an LP with an open withdrawal request would
        // weighted-average the new basis against shares escrowed at the vault. The
        // bug_010 fix makes that correct for the CANCEL path, but on the FULFILL
        // path the escrowed shares are paid out, double-counting their basis and
        // OVER-charging the perf fee. Block the deposit so the inconsistent state
        // is simply unreachable (the LP must cancel first).
        if (_pendingWithdrawal[receiver].shares != 0) revert PendingRequestBlocksDeposit(receiver);
        _accrueMgmtFee();
        // Audit L1: USDC-class (non-FOT, non-rebasing) assets only — verify the vault
        // actually received the full `assets`, else a fee-on-transfer token would
        // over-credit shares. (Invariant documented in docs/SECURITY.md.)
        uint256 idleBefore = idleUsdc();
        shares = super.deposit(assets, receiver);
        uint256 received = idleUsdc() - idleBefore;
        if (received < assets) revert DepositAmountNotReceived(assets, received);
        _absorbCostBasis(receiver, shares, assets);
    }

    function mint(uint256 shares, address receiver)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        if (emergencyShutdownActive) revert EmergencyShutdownActive();
        if (_escape.active) revert EscapeModeActive(); // M5 §4
        // Audit M2: see {deposit} — block mints into an LP with an open request.
        if (_pendingWithdrawal[receiver].shares != 0) revert PendingRequestBlocksDeposit(receiver);
        _accrueMgmtFee();
        // Audit L1: USDC-class assets only — verify the full `assets` was received.
        uint256 idleBefore = idleUsdc();
        assets = super.mint(shares, receiver);
        uint256 received = idleUsdc() - idleBefore;
        if (received < assets) revert DepositAmountNotReceived(assets, received);
        _absorbCostBasis(receiver, shares, assets);
    }

    /// @dev Bypasses `super.withdraw` to avoid OZ's `maxWithdraw` check, which
    ///      tightens as our fee accrual mints dilutive shares. We enforce the
    ///      idle-USDC cap here directly.
    ///
    ///      Audit C-3: the performance fee is paid in `asset()` directly to
    ///      feeRecipient out of the exiting LP's payout — no fee shares are
    ///      minted, so non-exiting LPs are not diluted.
    ///
    ///      Ultrareview merged_bug_002: `assets` is the GROSS amount (mirrors
    ///      `redeem`). Exactly `previewWithdraw(assets)` shares are burned and
    ///      the receiver gets `assets - feeAssets`. The previous version
    ///      over-burned `previewWithdraw(assets + feeAssets)` shares, which broke
    ///      the ERC-4626 invariants for `previewWithdraw` (under-reported the
    ///      burn), `maxWithdraw` (`withdraw(maxWithdraw(owner))` reverted for any
    ///      LP with a gain), and the allowance flow (a standard router approving
    ///      `previewWithdraw(assets)` reverted with insufficient allowance).
    ///
    ///      NOTE: `previewWithdraw` / `previewRedeem` are fee-EXCLUSIVE (gross).
    ///      The per-LP performance fee depends on the owner's cost basis and so
    ///      cannot be reflected in the owner-agnostic ERC-4626 preview functions;
    ///      the actual asset delta is `previewRedeem(shares) - perfFee(owner)`.
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        returns (uint256 shares)
    {
        _accrueMgmtFee();

        // Audit H2: idle reserved for overdue prioritized requests is off-limits to
        // direct withdraws (Finding F — racing redeems can't drain a queued LP's reserve).
        uint256 idle = _availableIdle();
        if (assets > idle) revert WithdrawExceedsIdleBalance(assets, idle);

        // `assets` is gross: burn exactly the shares it converts to, then pay the
        // perf fee out of it and send the remainder to the receiver.
        shares = previewWithdraw(assets);
        if (shares > balanceOf(owner)) revert WithdrawExceedsIdleBalance(assets, idle);

        uint256 feeAssets = _perfFeeAssetsWithCb(shares, _costBasisPerShare[owner]);
        if (feeAssets >= assets) feeAssets = 0; // sanity — should not happen for valid fee/gain
        uint256 net = assets - feeAssets;

        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        _burn(owner, shares);
        if (feeAssets > 0) {
            IERC20(asset()).safeTransfer(feeRecipient, feeAssets);
            emit PerfFeePaid(owner, feeAssets);
        }
        IERC20(asset()).safeTransfer(receiver, net);
        emit Withdraw(msg.sender, receiver, owner, net, shares);
    }

    /// @dev Audit C-3: perf fee is deducted from the user's gross payout and
    ///      transferred to feeRecipient in `asset()` terms (no share mint, no
    ///      dilution of other LPs).
    function redeem(uint256 shares, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        returns (uint256 assets)
    {
        if (shares > balanceOf(owner)) shares = balanceOf(owner);

        _accrueMgmtFee();

        uint256 grossAssets = previewRedeem(shares);
        // Audit H2: only un-reserved idle is available to a direct redeem.
        uint256 idle = _availableIdle();
        if (grossAssets > idle) {
            // Partial payout: scale down both legs proportionally
            grossAssets = idle;
            uint256 scaled = previewWithdraw(grossAssets);
            if (scaled < shares) shares = scaled;
        }

        uint256 feeAssets = _perfFeeAssetsWithCb(shares, _costBasisPerShare[owner]);
        if (feeAssets >= grossAssets) feeAssets = 0; // sanity — should not happen for valid fee/gain
        assets = grossAssets - feeAssets;

        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);

        _burn(owner, shares);
        if (feeAssets > 0) {
            IERC20(asset()).safeTransfer(feeRecipient, feeAssets);
            emit PerfFeePaid(owner, feeAssets);
        }
        if (assets > 0) IERC20(asset()).safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @dev   Cost-basis tracking on every share movement so perf fee follows shares.
    ///        - Mint paths set cost basis explicitly in `_absorbCostBasis`.
    ///        - Regular transfers between two LPs: receiver inherits a weighted
    ///          average of the two cost bases.
    ///        - Vault-as-counterparty (escrow during requestWithdraw,
    ///          cancellation): no cost basis update. The pending request stores
    ///          a snapshot separately.
    /// @dev   Audit M1 — an inter-LP transfer is a REALIZATION event for the
    ///        transferor's gain. The old weighted-average-of-cost-bases behaviour
    ///        let a gaining LP route shares into an underwater LP so the gain
    ///        netted against the other LP's loss and was never taxed (perf-fee
    ///        evasion). Now the transferor's perf fee on the transferred shares is
    ///        crystallized at transfer time by DIVERTING fee-equivalent shares to
    ///        `feeRecipient` — a redirect, NOT a mint, so `totalSupply` is unchanged
    ///        and non-transacting LPs are not diluted (preserves audit C-3). The
    ///        receiver gets `value - feeShares`, and those shares enter at the
    ///        CURRENT price-per-share (the gain is realized), so a loss elsewhere
    ///        can no longer absorb it.
    ///
    ///        INTEGRATOR NOTE (ERC-20-surprising): with a non-zero perf fee, a
    ///        `transfer`/`transferFrom` of a gaining LP's shares delivers fewer
    ///        shares than `value` to the recipient (the haircut funds the fee) and
    ///        emits a second `Transfer` to `feeRecipient`. Escrow moves
    ///        (requestWithdraw/cancel, where the vault is a counterparty) and
    ///        mint/burn are exempt. See docs/SECURITY.md.
    function _update(address from, address to, uint256 value) internal override {
        if (
            from != address(0) && to != address(0) && value > 0 && from != to && from != address(this)
                && to != address(this)
        ) {
            // Crystallize the transferor's perf fee on the transferred shares.
            uint256 feeAssets;
            uint256 feeShares;
            if (perfFeeBps != 0 && to != feeRecipient) {
                feeAssets = _perfFeeAssetsWithCb(value, _costBasisPerShare[from]);
                uint256 ta = totalAssets();
                if (feeAssets != 0 && ta != 0) {
                    feeShares = Math.mulDiv(feeAssets, totalSupply(), ta);
                    if (feeShares >= value) feeShares = 0; // sanity: perfFee <= 50% so this never trips
                }
            }

            uint256 curPps = pricePerShare();
            uint256 toReceives = value - feeShares;

            // Receiver's transferred shares enter at the realized (current) PPS basis.
            // (balanceOf reads are PRE-transfer here, as before — super._update follows.)
            if (toReceives != 0) _absorbReceiveCostBasis(to, toReceives, curPps);
            super._update(from, to, toReceives);

            if (feeShares != 0) {
                _absorbReceiveCostBasis(feeRecipient, feeShares, curPps);
                super._update(from, feeRecipient, feeShares);
                emit PerfFeePaid(from, feeAssets);
            }
            // `from` keeps its cost basis on any remaining shares.
            return;
        }
        super._update(from, to, value);
    }

    /// @dev Weighted-average `addedShares` (entering at cost basis `cbForAdded`,
    ///      1e18-fixed) into `acct`'s existing position. `balanceOf(acct)` must be
    ///      read PRE-receipt (callers run this before `super._update`).
    function _absorbReceiveCostBasis(address acct, uint256 addedShares, uint256 cbForAdded) internal {
        uint256 balBefore = balanceOf(acct);
        if (balBefore == 0) {
            _costBasisPerShare[acct] = cbForAdded;
        } else {
            _costBasisPerShare[acct] =
                (balBefore * _costBasisPerShare[acct] + addedShares * cbForAdded) / (balBefore + addedShares);
        }
    }

    // -------------------------------------------------------------------------
    // NAV decomposition (public for indexers and the frontend)
    // -------------------------------------------------------------------------

    function idleUsdc() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @notice Idle USDC available to ordinary redemption (everything except the
    ///         idle reserved for overdue, prioritized withdrawal requests — H2).
    function availableIdleUsdc() public view returns (uint256) {
        return _availableIdle();
    }

    /// @notice Idle currently reserved for overdue prioritized requests (H2).
    function reservedIdleUsdc() external view returns (uint256) {
        return _reservedIdle;
    }

    /// @dev Idle minus the overdue-request reserve, floored at 0 (audit H2).
    function _availableIdle() internal view returns (uint256) {
        uint256 idle = idleUsdc();
        return idle > _reservedIdle ? idle - _reservedIdle : 0;
    }

    /// @notice The vault's Core spot USDC balance, normalized to the 6dp EVM-USDC
    ///         scale.
    /// @dev    Audit G2 — wallet mode (the production posture): this leg is
    ///         **bridgeable NAV**, realized to idle EVM USDC contract-to-contract
    ///         via {pullFromCore} (the CoreDepositWallet pays native USDC from
    ///         its reserve; see {CoreLinkVerified}). Residual trust = the
    ///         Circle-operated wallet (pausable/upgradeable; issuer-trust class).
    ///         Legacy mode (no wallet, asset unlinked): the pre-G2 caveat stands —
    ///         this is operator-recoverable NAV via the Path-B route
    ///         `operatorRecoverSpot -> treasury -> re-deposit` (see
    ///         {CoreLinkUnverified} and docs/SECURITY.md), with its explicit ~1:1
    ///         cross-token assumption and operator-trust.
    function coreSpotUsdc() public view returns (uint256) {
        // Audit H-1: once {navBootstrap} ends, NAV reads are strict — a precompile
        // failure surfaces instead of silently returning zero (fail-closed).
        uint64 totalCore = navBootstrap
            ? PrecompileLib.spotBalance(address(this), coreUsdcIndex).total
            : PrecompileLib.spotBalanceStrict(address(this), coreUsdcIndex).total;
        return _coreToEvm(totalCore);
    }

    function perpWithdrawable() public view returns (uint256) {
        // Audit H-1: see {coreSpotUsdc}.
        return navBootstrap
            ? uint256(PrecompileLib.withdrawable(address(this)).withdrawable)
            : uint256(PrecompileLib.withdrawableStrict(address(this)).withdrawable);
    }

    function nav() external view returns (uint256) {
        return totalAssets();
    }

    function pricePerShare() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return Constants.WAD; // by definition 1.0 in 1e18 units
        return Math.mulDiv(totalAssets(), Constants.WAD, supply);
    }

    function pendingMgmtFeeShares() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0 || mgmtFeeAnnualBps == 0) return 0;
        uint256 dt = block.timestamp - _lastAccrualTs;
        uint256 currNav = totalAssets();
        if (currNav == 0 || dt == 0) return 0;
        uint256 feeAssets = (currNav * mgmtFeeAnnualBps * dt) / (Constants.BPS * Constants.SECONDS_PER_YEAR);
        // Audit L2: a long-dormancy linear fee can exceed NAV; cap it at ONE annual
        // period's worth (the configured rate) rather than the old nav/2 — which
        // confiscated ~50% of NAV in a single accrual. This bounds the dormancy
        // over-charge to <= mgmtFeeAnnualBps of NAV.
        uint256 maxFee = (currNav * mgmtFeeAnnualBps) / Constants.BPS;
        if (feeAssets > maxFee) feeAssets = maxFee;
        if (feeAssets >= currNav) return 0; // defensive: cannot take >= all of NAV
        return (feeAssets * supply) / (currNav - feeAssets);
    }

    function isPerpWhitelisted(uint32 asset_) external view returns (bool) {
        return _whitelistedPerps.contains(asset_);
    }

    function isSpotWhitelisted(uint32 asset_) external view returns (bool) {
        return _whitelistedSpots.contains(asset_);
    }

    function whitelistedPerpsList() external view returns (uint256[] memory) {
        return _whitelistedPerps.values();
    }

    function whitelistedSpotsList() external view returns (uint256[] memory) {
        return _whitelistedSpots.values();
    }

    function pendingWithdrawalShares(address lp) external view returns (uint256) {
        return _pendingWithdrawal[lp].shares;
    }

    /// @notice Fulfillment SLA deadline stamped on `lp`'s request (0 = none) (H2).
    function pendingWithdrawalDeadline(address lp) external view returns (uint64) {
        return _pendingWithdrawal[lp].fulfillmentDeadline;
    }

    /// @notice Idle assets currently reserved for `lp`'s prioritized request (H2).
    function pendingWithdrawalReserved(address lp) external view returns (uint256) {
        return _pendingWithdrawal[lp].reservedAssets;
    }

    /// @notice True iff `lp` has a request with a lapsed fulfillment deadline (H2).
    function requestIsOverdue(address lp) external view returns (bool) {
        WithdrawalRequest storage req = _pendingWithdrawal[lp];
        return req.shares != 0 && req.fulfillmentDeadline != 0 && block.timestamp > req.fulfillmentDeadline;
    }

    function nextCloid() external view returns (uint128) {
        return _cloidCounter;
    }

    // -------------------------------------------------------------------------
    // Operator surface
    // -------------------------------------------------------------------------

    function placeLimitOrder(uint32 asset_, bool isBuy, uint64 limitPx, uint64 sz, bool reduceOnly, uint8 tif)
        external
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint128 cloid)
    {
        // M5 §4: ESCAPE mode blocks the operator's order surface — the only orders
        // permitted while latched are the reduce-only flatten crank ({escapeFlattenPerps},
        // a distinct permissionless surface), which can never add exposure.
        if (_escape.active) revert EscapeModeActive();
        _accrueMgmtFee();

        // Assign the cloid, then delegate the whole trade gate (whitelist,
        // slippage band H-3/H-4, leverage cap) + CoreWriter dispatch to
        // VaultTradeLib (audit G2 — EIP-170 split). The whitelist sets are passed
        // by storage reference so the gate + open-notional loop live in the
        // library, not in the vault's bytecode. `nav` is read once and reused for
        // the cap check and the event snapshot (a submit does not settle
        // synchronously, so it equals the value the inlined code emitted).
        cloid = _cloidCounter++;
        VaultTradeLib.placeOrderChecked(
            VaultTradeLib.OrderParams({
                asset: asset_,
                isBuy: isBuy,
                limitPx: limitPx,
                sz: sz,
                reduceOnly: reduceOnly,
                tif: tif,
                cloid: cloid,
                slippageBandBps: slippageBandBps,
                spotBand: spotSlippageBandBps[asset_],
                spotScale: spotPxScaleFactor[asset_],
                leverageCapBps: leverageCapBps,
                nav: totalAssets()
            }),
            _whitelistedPerps,
            _whitelistedSpots
        );
    }

    function cancelOrderByCloid(uint32 asset_, uint128 cloid) external onlyRole(OPERATOR_ROLE) nonReentrant {
        CoreWriterLib.cancelOrderByCloid(asset_, cloid);
        emit OrderCancelByCloidSubmitted(asset_, cloid);
    }

    /// @dev Audit G2: wallet mode deposits via Circle's CoreDepositWallet —
    ///      `approve + deposit(amount, CORE_SPOT_DEX_ID)`. The spot dex is
    ///      hardcoded deliberately: the credit lands exactly where
    ///      {coreSpotUsdc} reads (NAV continuity), independent of the wallet's
    ///      mutable dex-forwarding config, and free of the perp-route
    ///      new-Core-account fee; spot->perp stays the explicit {usdSpotToPerp}.
    ///      If Circle pauses the wallet, its `EnforcedPause` revert bubbles up
    ///      (no pre-check: it would just add a TOCTOU'd external call). A zero
    ///      `amount` reverts inside the wallet. The trailing zero-approve is
    ///      defensive: today's wallet consumes the exact allowance, but it is an
    ///      upgradeable third-party proxy — never leave an allowance standing.
    function pushToCore(uint64 amount) external onlyRole(OPERATOR_ROLE) whenNotPaused nonReentrant {
        // M5 §4: ESCAPE mode blocks pushing idle to Core — the brake is unwinding
        // Core toward idle, so deploying idle outward is exactly wrong-way.
        if (_escape.active) revert EscapeModeActive();
        // Audit G2 (EIP-170): the audit-H2 reserved-idle guard + the wallet-vs-legacy
        // route body live in {VaultEmergencyLib.pushToCoreRoute} (delegatecall). The
        // vault passes `_availableIdle()` by value (so the H2 floor is enforced
        // without exposing the private `_reservedIdle`); the
        // {WithdrawExceedsIdleBalance} revert + the {BridgeDeposit} log are
        // byte-identical across the boundary. `coreDepositWallet` is the immutable.
        VaultEmergencyLib.pushToCoreRoute(coreDepositWallet, amount, _availableIdle());
    }

    /// @dev Audit H2: NOT `whenNotPaused`. This only moves funds Core->EVM idle
    ///      (toward LP redeemability), adding no market risk — pausing it would
    ///      freeze the refill path and strand LPs (Finding A, proven live). Pause
    ///      still blocks deposits and outbound/market-risk movers.
    /// @dev Audit G2: the Core-side action is route-invariant. For a wallet-mode
    ///      vault the system tx pays out via the CoreDepositWallet's
    ///      system-guarded `transfer` (native USDC from its reserve, to this
    ///      vault); for a legacy direct-linked asset the system address itself
    ///      transfers the ERC20 back. Note the wallet payout is `whenNotPaused`
    ///      on Circle's side — a paused wallet stalls the refill until unpaused
    ///      (contingency: {operatorRecoverSpot} / {emergencyRepatriate}).
    /// @dev Audit G2 (EIP-170): the `send_asset` (action 13) body lives in
    ///      {VaultEmergencyLib.pullFromCore} (delegatecall) to reclaim the vault's
    ///      24576-byte budget after M5's escape latch. The `OPERATOR_ROLE` gate +
    ///      `nonReentrant` stay here (deliberately NOT `whenNotPaused` — H2). The
    ///      {BridgeWithdraw} log is byte-identical; `coreUsdcIndex` is threaded in by
    ///      value (an immutable, unreachable from a delegatecall library).
    ///
    ///      Background (the live-verified action): unified HyperCore accounts
    ///      SILENTLY DROP the legacy spot_send (action 6) — withdrawals must use
    ///      send_asset (action 13). The send (spot -> spot) targets the token system
    ///      address; HyperCore debits this vault's Core spot and the linked
    ///      CoreDepositWallet pays native USDC to the caller (this vault) at
    ///      amountWei/100 (8dp Core -> 6dp EVM); a legacy direct-linked asset's
    ///      system minter credits the caller instead — same action either way.
    function pullFromCore(uint64 amountWei) external onlyRole(OPERATOR_ROLE) nonReentrant {
        VaultEmergencyLib.pullFromCore(coreUsdcIndex, amountWei);
    }

    /// @notice Send a Core spot token from the vault's Core account to an
    ///         allowlisted address. CONTINGENCY path (audit G2).
    /// @dev    With the official CoreDepositWallet route live for natively-minted
    ///         USDC, the primary capital loop is {pushToCore}/{pullFromCore} and
    ///         this is a contingency: a Circle-paused/decommissioned wallet, a
    ///         non-USDC spot token to evacuate, or a legacy asset with no usable
    ///         bridge (the pre-G2 Path-B treasury flow).
    ///
    ///         Note: this is `OPERATOR_ROLE` gated, not `EMERGENCY_ROLE`,
    ///         because in those contingencies it becomes part of the rebalance
    ///         flow. In normal wallet-mode operation `pullFromCore` is the
    ///         route and operators should treat this as emergency-only
    ///         (e.g., restrict via a multisig policy).
    /// @dev   Audit C-2: `to` must be on the admin-managed `spotRecoverDest`
    ///        allowlist. A compromised OPERATOR key can no longer drain Core
    ///        spot funds to an arbitrary address — destinations must be
    ///        pre-approved via timelock.
    /// @dev Audit H2: NOT `whenNotPaused` — it only moves Core spot to an
    ///      allowlisted (C-2) treasury for the Path-B refill, never deploys new
    ///      market risk; freezing it on pause would strand LPs (Finding A).
    /// @dev Audit G2 (EIP-170): the C-2-gated send_asset body lives in
    ///      {VaultEmergencyLib.operatorRecoverSpot} (delegatecall) to reclaim the
    ///      vault's 24576-byte budget after M5's escape latch. The `OPERATOR_ROLE`
    ///      gate + `nonReentrant` stay here; the `spotRecoverDest` allowlist is
    ///      threaded in by storage reference, and the C-2 check, the action-13
    ///      route, the {OperatorSpotRecovered} log, and the {ZeroAddress} /
    ///      {SpotRecoverDestinationNotAllowed} reverts are byte-identical.
    function operatorRecoverSpot(address to, uint64 token, uint64 amountWei)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
    {
        VaultEmergencyLib.operatorRecoverSpot(spotRecoverDest, to, token, amountWei);
    }

    /// @notice Sweep EVM-side `asset()` balance when there are no LPs.
    /// @dev    Recovery path for the "donation-to-empty-vault" trap: OZ's
    ///         virtual-shares math leaves arbitrary funds in the vault when
    ///         someone bridges/transfers asset before the first real deposit.
    ///         Once `totalSupply == 0`, no LP has any claim on the asset
    ///         balance — it's safe to sweep. Reverts if shares exist.
    /// @dev Audit G2 (EIP-170): body in {VaultEmergencyLib.operatorSweepStranded}
    ///      (delegatecall); the `totalSupply == 0` precondition, the {StrandedSwept}
    ///      log, and the {ZeroAddress} / {StrandedSweepRequiresZeroSupply} reverts
    ///      are unchanged across the boundary.
    function operatorSweepStranded(address to) external onlyRole(OPERATOR_ROLE) nonReentrant {
        VaultEmergencyLib.operatorSweepStranded(to);
    }

    function usdSpotToPerp(uint64 ntl) external onlyRole(OPERATOR_ROLE) whenNotPaused nonReentrant {
        // M5 §4: ESCAPE mode blocks spot->perp — it ADDS market exposure, the
        // opposite of an unwind. (perp->spot, {usdPerpToSpot}, stays open — it's
        // risk-reducing and is leg 3's own primitive.)
        if (_escape.active) revert EscapeModeActive();
        CoreWriterLib.usdClassTransfer(ntl, true);
        emit UsdClassTransferSubmitted(ntl, true);
    }

    /// @dev Audit H2: NOT `whenNotPaused` — perp->spot moves equity toward
    ///      redeemable idle (no new market risk). `usdSpotToPerp` (spot->perp,
    ///      which DOES add exposure) deliberately stays paused.
    function usdPerpToSpot(uint64 ntl) external onlyRole(OPERATOR_ROLE) nonReentrant {
        CoreWriterLib.usdClassTransfer(ntl, false);
        emit UsdClassTransferSubmitted(ntl, false);
    }

    // -------------------------------------------------------------------------
    // Emergency surface
    // -------------------------------------------------------------------------

    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }

    /// @dev Audit G2 (EIP-170): the nested cancel loop body lives in
    ///      {VaultEmergencyLib.emergencyCancelByCloid} (an external delegatecall
    ///      library, like {VaultTradeLib}) so it stays out of the vault's
    ///      24576-byte budget after M5's escape latch. The role gate +
    ///      `nonReentrant` stay here, and the emitted {OrderCancelByCloidSubmitted}
    ///      logs + the `"len"` revert are byte-identical across the boundary.
    function emergencyCancelByCloid(uint32[] calldata assets, uint128[][] calldata cloids)
        external
        onlyRole(EMERGENCY_ROLE)
        nonReentrant
    {
        VaultEmergencyLib.emergencyCancelByCloid(assets, cloids);
    }

    /// @dev Audit G2 (EIP-170): body in {VaultEmergencyLib.emergencyCancelByOid}
    ///      (delegatecall); the {OrderCancelByOidSubmitted} log is unchanged.
    function emergencyCancelByOid(uint32 asset_, uint64 oid) external onlyRole(EMERGENCY_ROLE) nonReentrant {
        VaultEmergencyLib.emergencyCancelByOid(asset_, oid);
    }

    /// @notice Close open perp positions via opposite-side IOC orders at the
    ///         caller-supplied `limitPxs` (recommend: mark px ± slippage).
    /// @dev    Caller is responsible for sizing — read each `position(this, a).szi`
    ///         off-chain and pass the matching `limitPx`. Iterates serially.
    ///         Audit M4: when `emergencyCloseBandBps > 0`, each `limitPx` is sanity-
    ///         checked against the STRICT `markPx` (normalized to the 10^8 action
    ///         scale) and rejected if it deviates beyond the (wide) band — so a
    ///         compromised EMERGENCY key cannot bleed value by closing at an absurd
    ///         price on a thin market. The band is wider than the trade-time band
    ///         (emergencies must still exit). Use {emergencyClosePositionsForce} to
    ///         skip the band in the rare case the oracle itself is unusable.
    function emergencyClosePositions(uint32[] calldata perpAssets, uint64[] calldata limitPxs)
        external
        onlyRole(EMERGENCY_ROLE)
        nonReentrant
    {
        _cloidCounter = VaultTradeLib.emergencyClose(
            perpAssets, limitPxs, true, emergencyCloseBandBps, _cloidCounter, totalAssets()
        );
    }

    /// @notice Audit M4: emergency close that SKIPS the {emergencyCloseBandBps}
    ///         sanity band — explicit, last-resort override for when the oracle is
    ///         down/unusable and the position must be exited regardless. Separate
    ///         function so the band is never silently bypassed.
    function emergencyClosePositionsForce(uint32[] calldata perpAssets, uint64[] calldata limitPxs)
        external
        onlyRole(EMERGENCY_ROLE)
        nonReentrant
    {
        _cloidCounter = VaultTradeLib.emergencyClose(
            perpAssets, limitPxs, false, emergencyCloseBandBps, _cloidCounter, totalAssets()
        );
    }

    /// @notice One-way switch. Blocks deposits forever; redeems remain open
    ///         once the operator has rebalanced funds back to idle EVM.
    function emergencyShutdown() external onlyRole(EMERGENCY_ROLE) {
        emergencyShutdownActive = true;
        emit EmergencyShutdownTriggered(msg.sender);
    }

    /// @notice Audit H2: EMERGENCY_ROLE escape hatch to repatriate Core funds
    ///         toward LP redeemability when the operator key is dark/compromised.
    ///         Moves perp equity to spot and/or sends Core spot USDC to either the
    ///         canonical USDC bridge (→ vault idle) or an allowlisted (C-2)
    ///         treasury for the Path-B refill. Deliberately NOT `whenNotPaused`:
    ///         the entire point is liveness under a paused / operator-absent vault.
    ///         It deploys NO new market risk (only moves funds toward idle), and
    ///         the destination is constrained to the same C-2 allowlist as
    ///         `operatorRecoverSpot`, so a rogue EMERGENCY key cannot exfiltrate.
    /// @param  to             spot-send destination: SystemAddress.usdc() — the
    ///                        live route in wallet mode, the CoreDepositWallet
    ///                        pays the vault's EVM idle (audit G2) — or an
    ///                        allowlisted `spotRecoverDest` (legacy Path-B /
    ///                        wallet-paused contingency). Ignored if
    ///                        `spotSendWei == 0`.
    /// @param  perpToSpotNtl  6dp USD to move perp→spot first (0 = skip).
    /// @param  spotSendWei    Core-wei USDC to spot-send to `to` (0 = skip).
    /// @dev Audit G2 (EIP-170): the perp->spot + C-2-gated send_asset body lives in
    ///      {VaultEmergencyLib.emergencyRepatriate} (an external delegatecall
    ///      library, like {VaultTradeLib}) so it stays out of the vault's
    ///      24576-byte budget after M5's escape latch. The role gate +
    ///      `nonReentrant` stay here. The `spotRecoverDest` allowlist is threaded
    ///      in by storage reference and `coreUsdcIndex` (an immutable, unreachable
    ///      from a delegatecall library) by value; the C-2 check, the action-13
    ///      route, the {UsdClassTransferSubmitted}/{OperatorSpotRecovered}/
    ///      {EmergencyRepatriated} logs, and the {SpotRecoverDestinationNotAllowed}
    ///      revert are all byte-identical across the boundary.
    function emergencyRepatriate(address to, uint64 perpToSpotNtl, uint64 spotSendWei)
        external
        onlyRole(EMERGENCY_ROLE)
        nonReentrant
    {
        VaultEmergencyLib.emergencyRepatriate(spotRecoverDest, coreUsdcIndex, to, perpToSpotNtl, spotSendWei);
    }

    // -------------------------------------------------------------------------
    // Escape hatch — permissionless "dead man's brake", Phase 1 (M5)
    //
    // docs/ESCAPE_HATCH_SCOPE.md §2/§4/§7. The latch + ESCAPE-mode gates + the
    // three risk-reducing cranks (cancel / flatten / consolidate). The crank
    // BODIES live in {VaultEscapeLib} (an external delegatecall library, like
    // {VaultTradeLib}) so the loop machinery stays out of the vault's EIP-170
    // budget; the wrappers below thread storage + persist the returned cloid.
    //
    // The cranks are PERMISSIONLESS (no role gate) and PAUSE-IMMUNE (no
    // `whenNotPaused`, mirroring the H2 refill movers) — the security is the
    // `escapeActive` latch + the reduce-only/risk-reducing nature of each leg, not
    // the caller (§1 anti-grief: anyone can deposit dust and wait). They carry
    // `nonReentrant` + a per-interval cooldown (§4).
    // -------------------------------------------------------------------------

    /// @notice True while the escape brake is armed and the vault is in ESCAPE mode (M5).
    function escapeActive() external view returns (bool) {
        return _escape.active;
    }

    /// @notice Arm the escape brake — the vault enters ESCAPE mode (M5 §1/§4).
    /// @dev    INTERIM ENTRY (this issue, SOLU-3369): admin-gated. The PERMISSIONLESS
    ///         staleness trigger — a request overdue by `escapeGraceSeconds` beyond
    ///         its SLA deadline AND with a remaining claim exceeding
    ///         {availableIdleUsdc} (§1) — is implemented in SOLU-3371, which replaces
    ///         this admin guard with that condition. The admin gate here is STRICTLY
    ///         MORE RESTRICTIVE than the final permissionless trigger, so wiring 3371
    ///         only WIDENS access (no security regression in the interim); meanwhile
    ///         the latch, the mode gates, and the cranks are fully exercisable. `lp`
    ///         is the request that armed the brake (recorded in {EscapeActivated}) —
    ///         informational in this issue, the trigger subject in 3371. Latch-set is
    ///         idempotent and lives in {VaultEscapeLib.activate} (the same primitive
    ///         3371's permissionless trigger will call). The {EscapeTriggerNotWired}
    ///         error documents the deferred permissionless path.
    function triggerEscape(address lp) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        VaultEscapeLib.activate(_escape, lp);
    }

    /// @notice Permissionlessly clear the escape brake (M5 §1) — lifts ESCAPE mode.
    /// @dev    Succeeds ONLY when NONE of the supplied `lps` still has an
    ///         overdue-unfillable request (§1: "until no overdue-unfillable request
    ///         remains"). "Overdue-unfillable" = an overdue request (lapsed deadline)
    ///         whose remaining claim still exceeds {availableIdleUsdc} — the exact
    ///         condition that arms the brake in SOLU-3371; a request that has become
    ///         honorable (claim <= available idle) no longer holds the brake. The
    ///         caller supplies the candidate set (the brake is armed by a specific
    ///         stale request; keepers/LPs know which); any remaining offender reverts
    ///         with {EscapeBacklogRemains}. Permissionless + pause-immune like the
    ///         cranks. NB: this issue's interim admin {triggerEscape} can arm the
    ///         brake with no overdue request at all — then `exitEscape(<empty/any>)`
    ///         clears it immediately (no backlog to clear), which is correct. The
    ///         backlog loop lives in {VaultEscapeLib.exit} (delegatecall: reads this
    ///         vault's `_pendingWithdrawal` by storage reference + `previewRedeem` via
    ///         self-call) — out of the vault's EIP-170 budget.
    function exitEscape(address[] calldata lps) external nonReentrant {
        VaultEscapeLib.exit(_escape, lps, _pendingWithdrawal, _availableIdle());
    }

    /// @notice Leg 1 (M5 §2) — permissionlessly cancel the vault's resting orders on
    ///         `asset_` by cloid while latched. Strictly risk-reducing.
    /// @dev    PERMISSIONLESS + nonReentrant + PAUSE-IMMUNE (no `whenNotPaused`,
    ///         mirroring the H2 refill movers). The latch+cooldown gate, cloid
    ///         validation (`cloid < _cloidCounter`), and the CoreWriter dispatch all
    ///         live in {VaultEscapeLib.escapeCancelOrders} (vault EIP-170 budget). No
    ///         fee accrual: a cancel changes no value.
    function escapeCancelOrders(uint32 asset_, uint128[] calldata cloids) external nonReentrant {
        VaultEscapeLib.escapeCancelOrders(_escape, asset_, cloids, _cloidCounter);
    }

    /// @notice Leg 2 (M5 §2) — permissionlessly flatten open perp positions via
    ///         opposite-side reduce-only IOC orders while latched, with the M4 markPx
    ///         band MANDATORY (the band value is read from {emergencyCloseBandBps}).
    /// @dev    PERMISSIONLESS + nonReentrant + PAUSE-IMMUNE. The latch+cooldown gate,
    ///         reduce-only IOC + bug_009 size scaling + M4 band loop live in
    ///         {VaultEscapeLib.escapeFlattenPerps}, which FORCES the band on (there is
    ///         no band-free escape variant — a force close stays EMERGENCY_ROLE, §5).
    ///         Reduce-only means this can never add exposure. Persists the returned
    ///         cloid, exactly as {emergencyClosePositions} does. Accrues the mgmt fee
    ///         (a fill changes value).
    function escapeFlattenPerps(uint32[] calldata perpAssets, uint64[] calldata limitPxs) external nonReentrant {
        _accrueMgmtFee();
        _cloidCounter =
            VaultEscapeLib.escapeFlattenPerps(_escape, perpAssets, limitPxs, emergencyCloseBandBps, _cloidCounter);
    }

    /// @notice Leg 3 (M5 §2) — permissionlessly move all perp `withdrawable` equity
    ///         to Core spot while latched. The amount is read ON-CHAIN from the
    ///         conservative `withdrawable` figure (caller supplies nothing).
    /// @dev    PERMISSIONLESS + nonReentrant + PAUSE-IMMUNE. The latch+cooldown gate
    ///         and the lenient/strict `withdrawable` read (per {navBootstrap},
    ///         matching {perpWithdrawable}) live in
    ///         {VaultEscapeLib.escapeConsolidateToSpot}. Accrues the mgmt fee (moving
    ///         equity converges the conservative NAV).
    function escapeConsolidateToSpot() external nonReentrant {
        _accrueMgmtFee();
        VaultEscapeLib.escapeConsolidateToSpot(_escape, navBootstrap);
    }

    // -------------------------------------------------------------------------
    // Admin (timelock) — guardrail mutations
    // -------------------------------------------------------------------------

    function setWhitelistPerp(uint32 asset_, bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (enabled) _whitelistedPerps.add(asset_);
        else _whitelistedPerps.remove(asset_);
        emit WhitelistUpdated(asset_, true, enabled);
    }

    function setWhitelistSpot(uint32 asset_, bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (enabled) _whitelistedSpots.add(asset_);
        else _whitelistedSpots.remove(asset_);
        emit WhitelistUpdated(asset_, false, enabled);
    }

    function setLeverageCap(uint16 newCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit LeverageCapUpdated(leverageCapBps, newCap);
        leverageCapBps = newCap;
    }

    function setSlippageBand(uint16 newBand) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit SlippageBandUpdated(slippageBandBps, newBand);
        slippageBandBps = newBand;
    }

    function setFees(uint16 newMgmt, uint16 newPerf) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMgmt > 2_000 || newPerf > 5_000) revert InvalidFeeConfig(newMgmt, newPerf);
        _accrueMgmtFee(); // settle at old rate
        mgmtFeeAnnualBps = newMgmt;
        perfFeeBps = newPerf;
        emit FeesUpdated(newMgmt, newPerf);
    }

    function setDepositCap(uint256 newCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit DepositCapUpdated(depositCap, newCap);
        depositCap = newCap;
    }

    function setMaxDepositPerAddress(uint256 newCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit PerAddressCapUpdated(maxDepositPerAddress, newCap);
        maxDepositPerAddress = newCap;
    }

    /// @notice Recover non-asset tokens that landed at the vault. Cannot sweep
    ///         `asset()` nor the vault's own share token.
    /// @dev    Audit C-1: also blocks `address(this)` — the vault holds its own
    ///         shares in escrow during the withdrawal queue, and a sweep of
    ///         those would brick LP withdrawals (fulfillWithdraw / cancel
    ///         would revert at the ERC-20 transfer).
    function sweep(IERC20 token, address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(token) == asset() || address(token) == address(this)) revert SweepingAsset();
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, token.balanceOf(address(this)));
    }

    // -------------------------------------------------------------------------
    // Admin (timelock) — audit-mitigation surface (v1.3)
    // -------------------------------------------------------------------------

    /// @notice Audit C-2: allowlist (or remove) a destination for
    ///         `operatorRecoverSpot`.
    function setSpotRecoverDest(address dest, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (dest == address(0)) revert ZeroAddress();
        spotRecoverDest[dest] = allowed;
        emit SpotRecoverDestUpdated(dest, allowed);
    }

    /// @notice Audit H-1: end the fresh-vault NAV grace period. One-way — flips
    ///         {navBootstrap} false PERMANENTLY, switching NAV reads from lenient
    ///         (fail-open, returns 0 on a precompile failure) to strict
    ///         (fail-closed, reverts). Call once the vault's Core account has had
    ///         its first successful cross-chain action (so the precompile rows
    ///         exist); after that, a precompile revert indicates a real system
    ///         failure and NAV must not silently zero and misprice shares.
    function endNavBootstrap() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!navBootstrap) revert NavBootstrapAlreadyEnded();
        navBootstrap = false;
        emit NavBootstrapEnded(msg.sender);
    }

    /// @notice Audit H2/TODO-5: set the withdrawal-request fulfillment SLA window
    ///         (seconds). 0 disables deadlines (requests never go overdue). After
    ///         a request's `now + window` lapses, anyone may {prioritizeOverdue} it.
    function setRequestFulfillmentWindow(uint64 window) external onlyRole(DEFAULT_ADMIN_ROLE) {
        requestFulfillmentWindow = window;
        emit RequestFulfillmentWindowUpdated(window);
    }

    /// @notice Audit H-3 + M6: set per-spot-asset slippage band in bps together with
    ///         the calibrated `spotPx -> limitPx` scale factor. 0 bps disables the
    ///         band (the factor is ignored). A non-zero band REQUIRES a non-zero,
    ///         live-verified `scaleFactor` (see {suggestedSpotPxScaleFactor}) so the
    ///         normalized comparison is sound — enabling a band without calibrating
    ///         the scale would give false protection (the original H-3 footgun).
    function setSpotSlippageBand(uint32 asset_, uint16 bps, uint64 scaleFactor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > 0 && scaleFactor == 0) revert SpotBandRequiresScaleFactor(asset_);
        spotSlippageBandBps[asset_] = bps;
        spotPxScaleFactor[asset_] = scaleFactor;
        emit SpotSlippageBandUpdated(asset_, bps, scaleFactor);
    }

    /// @notice Audit M6: the factor the admin should START from when calibrating
    ///         {setSpotSlippageBand} — derived by mirroring the perp band, i.e.
    ///         10^(2 + baseTokenSzDecimals) where the base token is `spotInfo(idx).
    ///         tokens[0]`. This ASSUMES spotPx follows the perp `human * 10^(6 -
    ///         szDecimals)` family; because that is not guaranteed for every spot
    ///         market, this is guidance only — the admin MUST confirm it against a
    ///         live test order before calling {setSpotSlippageBand}.
    function suggestedSpotPxScaleFactor(uint32 asset_) external view returns (uint64) {
        uint32 idx = AssetId.indexOf(asset_);
        uint64 baseToken = PrecompileLib.spotInfo(idx).tokens[0];
        uint256 szDec = uint256(PrecompileLib.tokenInfo(uint32(baseToken)).szDecimals);
        return uint64(10 ** (szDec + 2));
    }

    /// @notice Audit M4: set the emergency-close sanity band in bps (vs strict
    ///         markPx). 0 disables it (default). Set WIDE — emergencies must still
    ///         exit; the band only rejects absurd prices. {emergencyClosePositionsForce}
    ///         bypasses it when the oracle itself is unusable.
    function setEmergencyCloseBand(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit EmergencyCloseBandUpdated(emergencyCloseBandBps, bps);
        emergencyCloseBandBps = bps;
    }

    // -------------------------------------------------------------------------
    // Withdrawal queue (escape hatch for illiquid moments)
    //
    // Single pending request per LP. Shares are escrowed at the vault address
    // so the LP cannot transfer or redeem them while a request is open. The
    // LP's cost basis is snapshotted at request time; perf fee at fulfilment
    // uses that snapshot vs. the current pricePerShare.
    // -------------------------------------------------------------------------

    function requestWithdraw(uint256 shares) external nonReentrant {
        if (shares == 0) return;
        uint256 bal = balanceOf(msg.sender);
        if (shares > bal) revert WithdrawExceedsIdleBalance(shares, bal);
        if (_pendingWithdrawal[msg.sender].shares != 0) revert WithdrawExceedsIdleBalance(shares, 0);

        // Audit H2/TODO-5: stamp the on-chain fulfillment SLA deadline (0 = disabled).
        uint64 deadline = requestFulfillmentWindow == 0 ? 0 : uint64(block.timestamp) + requestFulfillmentWindow;
        _pendingWithdrawal[msg.sender] = WithdrawalRequest({
            shares: shares,
            costBasisAtRequest: _costBasisPerShare[msg.sender],
            fulfillmentDeadline: deadline,
            reservedAssets: 0
        });
        _transfer(msg.sender, address(this), shares);
        emit WithdrawalRequested(msg.sender, shares);
        if (deadline != 0) emit WithdrawalDeadlineSet(msg.sender, deadline);
    }

    function cancelWithdrawRequest() external nonReentrant {
        WithdrawalRequest memory req = _pendingWithdrawal[msg.sender];
        if (req.shares == 0) return;
        // Audit H2: release any idle reserved for this (now-cancelled) request.
        if (req.reservedAssets != 0) _reservedIdle -= req.reservedAssets;
        delete _pendingWithdrawal[msg.sender];
        _transfer(address(this), msg.sender, req.shares);
        // cb is preserved on receive (from == address(this) skipped in _update)
    }

    /// @notice Audit H2 (Finding F) — permissionless. Once a request's
    ///         `fulfillmentDeadline` has lapsed, reserve its current claim on idle
    ///         so racing direct redeems can no longer drain it; the matching
    ///         {fulfillWithdraw} then pays the LP from that reserve. Surfaces the
    ///         operator-stall SLA breach on-chain. Reverts if the request is absent,
    ///         has no deadline, isn't overdue yet, or is already prioritized.
    /// @dev    Honest scope: with the canonical bridge dead (C1) no contract can
    ///         permissionlessly pull Core->EVM, so this enforces fairness/priority
    ///         over EXISTING idle and makes stalls visible; actual repatriation
    ///         still needs the operator or the EMERGENCY_ROLE Path-B hatch.
    function prioritizeOverdue(address lp) external nonReentrant {
        WithdrawalRequest storage req = _pendingWithdrawal[lp];
        uint256 shares = req.shares;
        if (shares == 0) revert NoPendingRequest(lp);
        uint64 deadline = req.fulfillmentDeadline;
        if (deadline == 0 || block.timestamp <= deadline) revert RequestNotOverdue(lp);
        if (req.reservedAssets != 0) revert RequestAlreadyPrioritized(lp);

        uint256 claim = previewRedeem(shares);
        uint256 avail = _availableIdle();
        if (claim > avail) claim = avail;
        req.reservedAssets = claim;
        _reservedIdle += claim;
        emit WithdrawalPrioritized(lp, claim, deadline);
    }

    /// @notice Anyone may call (keeper-friendly). Pays out as much of the request
    ///         as idle USDC allows, partial fills supported.
    /// @dev    Audit C-3: perf fee comes out of the LP's gross payout and is
    ///         transferred to feeRecipient in `asset()` terms — no fee shares
    ///         are minted, so non-exiting LPs are not diluted.
    function fulfillWithdraw(address lp) external nonReentrant {
        WithdrawalRequest memory req = _pendingWithdrawal[lp];
        if (req.shares == 0) return;

        _accrueMgmtFee();

        uint256 grossPossible = previewRedeem(req.shares);
        // Audit H2: this LP may draw the free (un-reserved) idle PLUS its own overdue
        // reserve. Non-prioritized requests (reservedAssets == 0) get only the
        // un-reserved idle, leaving other LPs' reserves intact. `_availableIdle()` is
        // floored, so this never underflows even if idle were somehow short.
        uint256 idle = _availableIdle() + req.reservedAssets;
        uint256 grossOut;
        uint256 outShares;

        if (grossPossible <= idle) {
            grossOut = grossPossible;
            outShares = req.shares;
        } else {
            grossOut = idle;
            outShares = previewWithdraw(idle);
            if (outShares > req.shares) outShares = req.shares;
        }
        if (outShares == 0 || grossOut == 0) return;

        uint256 feeAssets = _perfFeeAssetsWithCb(outShares, req.costBasisAtRequest);
        if (feeAssets >= grossOut) feeAssets = 0;
        uint256 userPayout = grossOut - feeAssets;

        // Audit H2: release this request's ENTIRE idle reserve on every fulfill.
        // A partial fill always consumes the whole reserve first (grossOut, the
        // LP's full available draw, is >= reservedAssets), and a full fill resolves
        // the request — so in both cases the reserve must be fully released. (A naive
        // `min(grossOut, reservedAssets)` would strand `reservedAssets - grossOut`
        // in `_reservedIdle` forever if NAV fell after prioritization, permanently
        // locking idle.) The remainder of a partial fill keeps its deadline and can
        // be re-prioritized by a keeper.
        if (req.reservedAssets != 0) _reservedIdle -= req.reservedAssets;

        if (outShares == req.shares) {
            delete _pendingWithdrawal[lp];
        } else {
            _pendingWithdrawal[lp].shares = req.shares - outShares;
            _pendingWithdrawal[lp].reservedAssets = 0;
        }

        _burn(address(this), outShares);
        if (feeAssets > 0) {
            IERC20(asset()).safeTransfer(feeRecipient, feeAssets);
            emit PerfFeePaid(lp, feeAssets);
        }
        if (userPayout > 0) IERC20(asset()).safeTransfer(lp, userPayout);

        emit Withdraw(msg.sender, lp, lp, userPayout, outShares);
        emit WithdrawalFulfilled(lp, userPayout);
    }

    // -------------------------------------------------------------------------
    // Internal — fee accounting
    // -------------------------------------------------------------------------

    function _accrueMgmtFee() internal {
        uint256 supply = totalSupply();
        uint64 nowTs = uint64(block.timestamp);
        if (supply == 0 || mgmtFeeAnnualBps == 0) {
            _lastAccrualTs = nowTs;
            return;
        }
        uint256 dt = nowTs - _lastAccrualTs;
        if (dt == 0) return;
        uint256 navNow = totalAssets();
        if (navNow == 0) {
            _lastAccrualTs = nowTs;
            return;
        }
        uint256 feeAssets = (navNow * mgmtFeeAnnualBps * dt) / (Constants.BPS * Constants.SECONDS_PER_YEAR);
        // Audit L2: cap a long-dormancy fee at one annual period (the configured
        // rate) instead of the old nav/2 confiscation; see {pendingMgmtFeeShares}.
        uint256 maxFee = (navNow * mgmtFeeAnnualBps) / Constants.BPS;
        if (feeAssets > maxFee) feeAssets = maxFee;
        if (feeAssets >= navNow) {
            _lastAccrualTs = nowTs;
            return;
        }
        uint256 feeShares = (feeAssets * supply) / (navNow - feeAssets);
        if (feeShares > 0) {
            _mint(feeRecipient, feeShares);
            _absorbCostBasis(feeRecipient, feeShares, feeAssets);
            emit MgmtFeeAccrued(feeShares, navNow);
        }
        _lastAccrualTs = nowTs;
        emit NavSnapshot(navNow, totalSupply(), idleUsdc(), coreSpotUsdc(), perpWithdrawable(), block.timestamp);
    }

    /// @dev Audit C-3: perf fee computed in `asset()` units. Caller deducts
    ///      `feeAssets` from the exiting LP's payout and transfers it to
    ///      `feeRecipient`. NO share mint, NO dilution of other LPs.
    ///
    ///      Returns 0 if perfFeeBps is 0, shares is 0, current PPS is at or
    ///      below the LP's cost basis, or the computed fee rounds to 0.
    function _perfFeeAssetsWithCb(uint256 shares, uint256 cb) internal view returns (uint256) {
        if (perfFeeBps == 0 || shares == 0) return 0;
        uint256 cur = pricePerShare();
        if (cur <= cb) return 0;
        uint256 gainPerShare = cur - cb;
        uint256 gainAssets = Math.mulDiv(gainPerShare, shares, Constants.WAD);
        return (gainAssets * perfFeeBps) / Constants.BPS;
    }

    /// @dev   Sets the LP's cost basis from the effective entry price
    ///        `entryPps = newAssets * WAD / newShares`. Derived this way to
    ///        cover the first depositor correctly (no pre-existing PPS) and to
    ///        keep fee-mint cost basis consistent with how feeShares are sized.
    function _absorbCostBasis(address lp, uint256 newShares, uint256 newAssets) internal {
        if (newShares == 0) return;
        uint256 entryPps = Math.mulDiv(newAssets, Constants.WAD, newShares);
        // Ultrareview bug_010: include shares escrowed for a pending withdrawal.
        // They live at address(this), so balanceOf(lp) excludes them — without
        // this, a deposit made while a withdrawal request is open hits the
        // `oldShares == 0` branch and OVERWRITES the LP's cost basis to the
        // current (elevated) PPS, wiping the unrealized gain and evading the
        // performance fee entirely (requestWithdraw -> deposit -> cancel ->
        // redeem). Counting the escrow weighted-averages the new deposit against
        // the escrowed shares' real basis instead.
        uint256 totalShares = balanceOf(lp) + _pendingWithdrawal[lp].shares;
        uint256 oldShares = totalShares - newShares;
        if (oldShares == 0) {
            _costBasisPerShare[lp] = entryPps;
        } else {
            _costBasisPerShare[lp] = (oldShares * _costBasisPerShare[lp] + newShares * entryPps) / totalShares;
        }
    }

    // Audit G2 (EIP-170): the leverage-cap helpers — the open-perp-notional sum
    // (`|sz| * markPx` over the whitelisted perps -> 6dp USD) and the order
    // notional (`sz * limitPx / 1e10`) — moved into {VaultTradeLib}, which now
    // owns the whole trade gate (whitelist + slippage band + leverage cap) so the
    // loop and EnumerableSet machinery stay out of the vault's bytecode.

    // -------------------------------------------------------------------------
    // Internal — decimal normalization for USDC
    // -------------------------------------------------------------------------

    /// @dev Normalizes a Core-wei USDC amount (in {coreUsdcDecimals}) to the 6dp
    ///      EVM-USDC scale. `view` (not `pure`) because the Core decimals are an
    ///      immutable read rather than a compile-time constant (audit C1/M5).
    function _coreToEvm(uint64 coreWei) internal view returns (uint256) {
        uint256 cwei = uint256(coreWei);
        if (coreUsdcDecimals >= Constants.USDC_EVM_DECIMALS) {
            // Core has more decimals → divide
            return cwei / (10 ** (coreUsdcDecimals - Constants.USDC_EVM_DECIMALS));
        } else {
            // EVM has more decimals → multiply
            return cwei * (10 ** (Constants.USDC_EVM_DECIMALS - coreUsdcDecimals));
        }
    }

    // -------------------------------------------------------------------------
    // ERC165 — required by AccessControl + ERC4626 inheritance
    // -------------------------------------------------------------------------

    function supportsInterface(bytes4 id) public view virtual override(AccessControl) returns (bool) {
        return super.supportsInterface(id);
    }
}
