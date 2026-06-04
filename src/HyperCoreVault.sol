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
import {CoreWriterLib} from "./libraries/CoreWriterLib.sol";
import {PrecompileLib} from "./libraries/PrecompileLib.sol";
import {SystemAddress} from "./libraries/SystemAddress.sol";
import {AssetId} from "./libraries/AssetId.sol";
import {Constants} from "./libraries/Constants.sol";

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

    bytes32 public constant OPERATOR_ROLE  = keccak256("OPERATOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // -------------------------------------------------------------------------
    // Constructor params (immutable per vault)
    // -------------------------------------------------------------------------

    struct Config {
        IERC20 asset;            // USDC ERC20 on HyperEVM
        uint64 coreUsdcIndex;    // Core spot token index for USDC (canonical mainnet = 0)
        uint8 coreUsdcDecimals;  // Core wei decimals for that token (validated vs live tokenInfo at deploy)
        string name;
        string symbol;
        address admin;           // DEFAULT_ADMIN_ROLE — should be a TimelockController
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

    uint128 private _cloidCounter;          // monotonically increasing client order id
    uint64  private _lastAccrualTs;          // last management-fee accrual timestamp
    bool    public emergencyShutdownActive;  // one-way switch

    /// @notice Per-LP cost basis per share, 1e18-fixed (price-per-share at entry).
    /// @dev    Updated on mint and on transfer between non-vault parties. Used
    ///         for crystallize-on-redeem perf fee.
    mapping(address => uint256) private _costBasisPerShare;

    struct WithdrawalRequest {
        uint256 shares;             // shares escrowed at the vault
        uint256 costBasisAtRequest; // 1e18-fixed snapshot of LP's cb at request time
        uint64 fulfillmentDeadline; // 0 = no SLA; else unix ts after which the request is overdue (H2)
        uint256 reservedAssets;     // idle assets reserved for this overdue request (H2 priority over redeem)
    }

    /// @notice One pending withdrawal request per LP. Issue a new one only after
    ///         cancelling the existing one.
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
    ///         no band (legacy / opt-out). Compared against `spotPx`.
    mapping(uint32 => uint16) public spotSlippageBandBps;

    /// @notice Sanity band (bps) for `emergencyClosePositions` limit prices vs the
    ///         strict markPx (audit M4). 0 = no band (default). Set WIDE (e.g.
    ///         1000-2000 bps) — looser than the trade-time band, since an emergency
    ///         must still be able to exit, but absurd prices on a thin market are
    ///         rejected so a compromised EMERGENCY key cannot bleed value.
    uint16 public emergencyCloseBandBps;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(Config memory cfg)
        ERC4626(cfg.asset)
        ERC20(cfg.name, cfg.symbol)
    {
        if (
            cfg.admin == address(0) ||
            cfg.operator == address(0) ||
            cfg.emergencyAdmin == address(0) ||
            cfg.feeRecipient == address(0)
        ) revert ZeroAddress();
        if (cfg.mgmtFeeAnnualBps > 2_000 || cfg.perfFeeBps > 5_000) {
            // hard caps: 20% mgmt/yr and 50% perf — sanity, not a marketing limit
            revert InvalidFeeConfig(cfg.mgmtFeeAnnualBps, cfg.perfFeeBps);
        }

        feeRecipient         = cfg.feeRecipient;
        coreUsdcIndex        = cfg.coreUsdcIndex;
        coreUsdcDecimals     = cfg.coreUsdcDecimals;
        // Audit C1/M5: validate the Core-USDC linkage against the live precompile.
        // When the `tokenInfo` row resolves (mainnet), the configured Core decimals
        // MUST match `weiDecimals` (a mismatch silently mis-scales NAV by 10^|Δ|),
        // and a Core `evmContract` that differs from `asset()` is surfaced on-chain
        // via {CoreLinkUnverified} rather than silently trusted — the deliberate
        // Path-B posture (Circle USDC stays the share asset; Core balance is
        // operator-recoverable NAV). When the precompile is empty (a fresh Core
        // account, or a revm fork), validation is skipped so deploys still work.
        {
            PrecompileLib.TokenInfo memory ti = PrecompileLib.tokenInfo(uint32(cfg.coreUsdcIndex));
            bool resolved = ti.weiDecimals != 0 || ti.evmContract != address(0) || bytes(ti.name).length != 0;
            if (resolved) {
                if (ti.weiDecimals != cfg.coreUsdcDecimals) {
                    revert CoreUsdcDecimalsMismatch(cfg.coreUsdcDecimals, ti.weiDecimals);
                }
                if (ti.evmContract != address(cfg.asset)) {
                    emit CoreLinkUnverified(address(cfg.asset), ti.evmContract);
                }
            }
        }
        leverageCapBps       = cfg.leverageCapBps;
        slippageBandBps      = cfg.slippageBandBps;
        mgmtFeeAnnualBps     = cfg.mgmtFeeAnnualBps;
        perfFeeBps           = cfg.perfFeeBps;
        depositCap           = cfg.depositCap;
        maxDepositPerAddress = cfg.maxDepositPerAddress;
        _lastAccrualTs       = uint64(block.timestamp);
        _cloidCounter        = 1; // start at 1 — cloid 0 means "no cloid" in HL conventions

        _grantRole(DEFAULT_ADMIN_ROLE, cfg.admin);
        _grantRole(OPERATOR_ROLE,      cfg.operator);
        _grantRole(EMERGENCY_ROLE,     cfg.emergencyAdmin);
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
        if (paused() || emergencyShutdownActive) return 0;
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
        // Audit M2: a deposit into an LP with an open withdrawal request would
        // weighted-average the new basis against shares escrowed at the vault. The
        // bug_010 fix makes that correct for the CANCEL path, but on the FULFILL
        // path the escrowed shares are paid out, double-counting their basis and
        // OVER-charging the perf fee. Block the deposit so the inconsistent state
        // is simply unreachable (the LP must cancel first).
        if (_pendingWithdrawal[receiver].shares != 0) revert PendingRequestBlocksDeposit(receiver);
        _accrueMgmtFee();
        shares = super.deposit(assets, receiver);
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
        // Audit M2: see {deposit} — block mints into an LP with an open request.
        if (_pendingWithdrawal[receiver].shares != 0) revert PendingRequestBlocksDeposit(receiver);
        _accrueMgmtFee();
        assets = super.mint(shares, receiver);
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
            _costBasisPerShare[acct] = (balBefore * _costBasisPerShare[acct] + addedShares * cbForAdded) / (balBefore + addedShares);
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
    ///         scale. Counts as **operator-recoverable NAV**: with the configured
    ///         Circle USDC unlinked from Core (audit C1, see {CoreLinkUnverified}
    ///         and docs/SECURITY.md), this value is realized to idle EVM USDC via
    ///         the Path-B route `operatorRecoverSpot → treasury → re-deposit`, not
    ///         the (blacklisted) canonical bridge. Including it in NAV therefore
    ///         carries an explicit ~1:1 cross-token assumption and operator-trust;
    ///         the keeper automation of Path B is tracked as TODO-4 (out of scope).
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
        if (feeAssets >= currNav) feeAssets = currNav / 2;
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

    function placeLimitOrder(
        uint32 asset_,
        bool isBuy,
        uint64 limitPx,
        uint64 sz,
        bool reduceOnly,
        uint8 tif
    ) external onlyRole(OPERATOR_ROLE) whenNotPaused nonReentrant returns (uint128 cloid) {
        _accrueMgmtFee();

        // 1. Whitelist gate
        if (AssetId.isPerp(asset_)) {
            if (!_whitelistedPerps.contains(asset_)) revert AssetNotWhitelisted(asset_);
        } else {
            if (!_whitelistedSpots.contains(asset_)) revert AssetNotWhitelisted(asset_);
        }

        // 2. Slippage band — perps use oraclePx, spots use spotPx (audit H-3, H-4).
        //    Scale reconciliation (verified on HyperEVM mainnet):
        //      oraclePx precompile        = human * 10^(6 - szDecimals)
        //      limit_order action limitPx = human * 10^8   (UNIFORM; NOT szDecimals-based)
        //    Normalize oraclePx UP to the 10^8 action scale before comparing:
        //      factor = 10^(8 - (6 - szDecimals)) = 10^(2 + szDecimals).
        //    Audit H-4: oraclePx AND szDecimals are read strictly — a zero /
        //    reverting oracle, or a failed asset-info read, fails the trade
        //    closed rather than silently mis-scaling or skipping the check.
        if (AssetId.isPerp(asset_) && slippageBandBps > 0) {
            uint64 oraclePxRaw = PrecompileLib.oraclePxStrict(asset_);
            uint256 szDec = uint256(PrecompileLib.perpAssetInfoStrict(asset_).szDecimals);
            uint256 oracleNorm = uint256(oraclePxRaw) * (10 ** (szDec + 2));
            uint256 limitPxU = uint256(limitPx);
            uint256 diff = limitPxU > oracleNorm ? limitPxU - oracleNorm : oracleNorm - limitPxU;
            uint256 maxDiff = (oracleNorm * slippageBandBps) / Constants.BPS;
            if (diff > maxDiff) revert SlippageBandExceeded(limitPx, oraclePxRaw, slippageBandBps);
        } else if (AssetId.isSpot(asset_)) {
            // Audit H-3: per-spot-asset slippage band. Off by default for
            //            backwards compatibility; admin must opt in per asset.
            //            Scale relationship between `spotPx` and the
            //            `limit_order` action's `limitPx` for spot is HL-defined
            //            and asset-specific; admin must verify on a test order
            //            before tightening the band.
            uint16 spotBand = spotSlippageBandBps[asset_];
            if (spotBand > 0) {
                uint64 spotPxRaw = PrecompileLib.spotPxStrict(AssetId.indexOf(asset_));
                uint256 limitPxU = uint256(limitPx);
                uint256 oracleU  = uint256(spotPxRaw);
                uint256 diff = limitPxU > oracleU ? limitPxU - oracleU : oracleU - limitPxU;
                uint256 maxDiff = (oracleU * spotBand) / Constants.BPS;
                if (diff > maxDiff) revert SlippageBandExceeded(limitPx, spotPxRaw, spotBand);
            }
        }

        // 3. Leverage cap — incremental new-order notional + sum of open perp notionals
        if (!reduceOnly && AssetId.isPerp(asset_) && leverageCapBps > 0) {
            uint256 navNow = totalAssets();
            uint256 gross = _grossOpenPerpNotional6dp() + _orderNotional6dp(sz, limitPx);
            uint256 capUsd = (navNow * leverageCapBps) / Constants.BPS;
            if (gross > capUsd) revert LeverageCapExceeded(gross, navNow, leverageCapBps);
        }

        // 4. Assign cloid, dispatch
        cloid = _cloidCounter++;
        CoreWriterLib.placeLimitOrder(asset_, isBuy, limitPx, sz, reduceOnly, tif, cloid);
        emit LimitOrderSubmitted(asset_, isBuy, limitPx, sz, reduceOnly, tif, cloid, totalAssets());
    }

    function cancelOrderByCloid(uint32 asset_, uint128 cloid) external onlyRole(OPERATOR_ROLE) nonReentrant {
        CoreWriterLib.cancelOrderByCloid(asset_, cloid);
        emit OrderCancelByCloidSubmitted(asset_, cloid);
    }

    function pushToCore(uint64 amount) external onlyRole(OPERATOR_ROLE) whenNotPaused nonReentrant {
        // Audit H2: cannot deploy idle that is reserved for an overdue prioritized
        // request (Finding F) — the reserve is LP-claimable idle, not operator capital.
        uint256 avail = _availableIdle();
        if (amount > avail) revert WithdrawExceedsIdleBalance(amount, avail);
        // ERC20 transfer to USDC bridge — Core credits 8dp wei after scaling by evmExtraWeiDecimals
        IERC20(asset()).safeTransfer(SystemAddress.usdc(), amount);
        emit BridgeDeposit(amount);
    }

    /// @dev Audit H2: NOT `whenNotPaused`. This only moves funds Core->EVM idle
    ///      (toward LP redeemability), adding no market risk — pausing it would
    ///      freeze the refill path and strand LPs (Finding A, proven live). Pause
    ///      still blocks deposits and outbound/market-risk movers.
    function pullFromCore(uint64 amountWei) external onlyRole(OPERATOR_ROLE) nonReentrant {
        // spot_send to USDC system address — system tx then transfers ERC20 back to this vault
        CoreWriterLib.spotSend(SystemAddress.usdc(), coreUsdcIndex, amountWei);
        emit BridgeWithdraw(amountWei);
    }

    /// @notice Send a Core spot token from the vault's Core account to any address.
    /// @dev    Generalised escape hatch needed when the canonical EVM↔Core USDC
    ///         bridge isn't deployed for the chosen asset (the current mainnet
    ///         situation — Circle USDC on EVM is not linked to Core USDC). The
    ///         operator uses this to send realised PnL or rebalancing funds to
    ///         a treasury / re-deposit address.
    ///
    ///         Note: this is `OPERATOR_ROLE` gated, not `EMERGENCY_ROLE`,
    ///         because it's part of the normal rebalance flow when the bridge
    ///         is non-functional. In a deployment with a functional bridge,
    ///         `pullFromCore` is preferred and this can be considered an
    ///         emergency-only path — operators should restrict their key
    ///         accordingly (e.g., via a multisig).
    /// @dev   Audit C-2: `to` must be on the admin-managed `spotRecoverDest`
    ///        allowlist. A compromised OPERATOR key can no longer drain Core
    ///        spot funds to an arbitrary address — destinations must be
    ///        pre-approved via timelock.
    /// @dev Audit H2: NOT `whenNotPaused` — it only moves Core spot to an
    ///      allowlisted (C-2) treasury for the Path-B refill, never deploys new
    ///      market risk; freezing it on pause would strand LPs (Finding A).
    function operatorRecoverSpot(address to, uint64 token, uint64 amountWei)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        if (!spotRecoverDest[to]) revert SpotRecoverDestinationNotAllowed(to);
        CoreWriterLib.spotSend(to, token, amountWei);
        emit OperatorSpotRecovered(to, token, amountWei);
    }

    /// @notice Sweep EVM-side `asset()` balance when there are no LPs.
    /// @dev    Recovery path for the "donation-to-empty-vault" trap: OZ's
    ///         virtual-shares math leaves arbitrary funds in the vault when
    ///         someone bridges/transfers asset before the first real deposit.
    ///         Once `totalSupply == 0`, no LP has any claim on the asset
    ///         balance — it's safe to sweep. Reverts if shares exist.
    function operatorSweepStranded(address to) external onlyRole(OPERATOR_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (totalSupply() != 0) revert StrandedSweepRequiresZeroSupply();
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        if (bal > 0) {
            IERC20(asset()).safeTransfer(to, bal);
            emit StrandedSwept(to, bal);
        }
    }

    function usdSpotToPerp(uint64 ntl) external onlyRole(OPERATOR_ROLE) whenNotPaused nonReentrant {
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

    function emergencyCancelByCloid(uint32[] calldata assets, uint128[][] calldata cloids)
        external
        onlyRole(EMERGENCY_ROLE)
        nonReentrant
    {
        require(assets.length == cloids.length, "len");
        for (uint256 i; i < assets.length; ++i) {
            uint32 a = assets[i];
            uint128[] calldata cs = cloids[i];
            for (uint256 j; j < cs.length; ++j) {
                CoreWriterLib.cancelOrderByCloid(a, cs[j]);
                emit OrderCancelByCloidSubmitted(a, cs[j]);
            }
        }
    }

    function emergencyCancelByOid(uint32 asset_, uint64 oid) external onlyRole(EMERGENCY_ROLE) nonReentrant {
        CoreWriterLib.cancelOrderByOid(asset_, oid);
        emit OrderCancelByOidSubmitted(asset_, oid);
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
        _emergencyClose(perpAssets, limitPxs, true);
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
        _emergencyClose(perpAssets, limitPxs, false);
    }

    function _emergencyClose(uint32[] calldata perpAssets, uint64[] calldata limitPxs, bool enforceBand) internal {
        require(perpAssets.length == limitPxs.length, "len");
        uint16 band = emergencyCloseBandBps;
        for (uint256 i; i < perpAssets.length; ++i) {
            uint32 a = perpAssets[i];
            int64 szi = PrecompileLib.position(address(this), a).szi;
            if (szi == 0) continue;
            uint64 absSz = szi < 0 ? uint64(-szi) : uint64(szi);
            // Ultrareview bug_009: `position().szi` is in szDecimals lots
            // (human_sz * 10^szDecimals), but the limit_order action `sz` is the
            // uniform human_sz * 10^8 scale (see CoreWriterLib.placeLimitOrder and
            // _orderNotional6dp). Without converting, the emergency close fires at
            // ~1/10^(8 - szDecimals) of the real size (1000x too small for BTC),
            // leaving the position essentially open. szDecimals is read strictly so
            // a failed asset-info read fails the close closed (consistent with H-4).
            uint8 szDec = PrecompileLib.perpAssetInfoStrict(a).szDecimals;

            // Audit M4: sanity-bound the supplied price against the strict markPx,
            // normalized to the 10^8 action scale (markPx = human * 10^(6-szDec),
            // limitPx = human * 10^8 -> factor 10^(2+szDec); same derivation as the
            // perp trade band). Strict read => a zero/missing markPx fails closed.
            if (enforceBand && band > 0) {
                uint64 markRaw = PrecompileLib.markPxStrict(a);
                uint256 markNorm = uint256(markRaw) * (10 ** (uint256(szDec) + 2));
                uint256 lpx = uint256(limitPxs[i]);
                uint256 diff = lpx > markNorm ? lpx - markNorm : markNorm - lpx;
                if (diff > (markNorm * band) / Constants.BPS) {
                    revert EmergencyCloseBandExceeded(limitPxs[i], markRaw, band);
                }
            }

            uint64 sz = uint64(uint256(absSz) * (10 ** (8 - szDec)));
            bool isBuy = szi < 0; // close: sell if currently long, buy if currently short
            uint128 cloid = _cloidCounter++;
            CoreWriterLib.placeLimitOrder(a, isBuy, limitPxs[i], sz, true, Constants.TIF_IOC, cloid);
            emit LimitOrderSubmitted(a, isBuy, limitPxs[i], sz, true, Constants.TIF_IOC, cloid, totalAssets());
        }
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
    /// @param  to             spot-send destination: SystemAddress.usdc() (bridge)
    ///                        or an allowlisted `spotRecoverDest`. Ignored if
    ///                        `spotSendWei == 0`.
    /// @param  perpToSpotNtl  6dp USD to move perp→spot first (0 = skip).
    /// @param  spotSendWei    Core-wei USDC to spot-send to `to` (0 = skip).
    function emergencyRepatriate(address to, uint64 perpToSpotNtl, uint64 spotSendWei)
        external
        onlyRole(EMERGENCY_ROLE)
        nonReentrant
    {
        if (perpToSpotNtl > 0) {
            CoreWriterLib.usdClassTransfer(perpToSpotNtl, false); // perp -> spot
            emit UsdClassTransferSubmitted(perpToSpotNtl, false);
        }
        if (spotSendWei > 0) {
            if (to != SystemAddress.usdc() && !spotRecoverDest[to]) {
                revert SpotRecoverDestinationNotAllowed(to);
            }
            CoreWriterLib.spotSend(to, coreUsdcIndex, spotSendWei);
            emit OperatorSpotRecovered(to, coreUsdcIndex, spotSendWei);
        }
        emit EmergencyRepatriated(to, perpToSpotNtl, spotSendWei);
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

    /// @notice Audit H-3: set per-spot-asset slippage band in bps. 0 disables
    ///         the band for that asset (legacy default). Admin must verify
    ///         the `spotPx` ↔ `limitPx` scale relationship for the asset
    ///         before tightening.
    function setSpotSlippageBand(uint32 asset_, uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        spotSlippageBandBps[asset_] = bps;
        emit SpotSlippageBandUpdated(asset_, bps);
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
        if (feeAssets >= navNow) feeAssets = navNow / 2; // sanity cap on absurd dt
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
            _costBasisPerShare[lp] =
                (oldShares * _costBasisPerShare[lp] + newShares * entryPps) / totalShares;
        }
    }

    // -------------------------------------------------------------------------
    // Internal — leverage cap helpers
    // -------------------------------------------------------------------------

    /// @dev   Sum of |size * markPx| over all whitelisted perps, in 6dp USD.
    ///        Scale derivation:
    ///          sz raw         = human_sz * 10^szDec
    ///          markPx precomp = human_px * 10^(6 - szDec)
    ///          product        = human_sz * human_px * 10^6 = direct 6dp USD
    ///        (no divisor needed). Different scale than `_orderNotional6dp`,
    ///        which takes `sz` and `limitPx` in the limit-order-action 10^8 scale.
    ///
    ///        Audit H-2: markPx read is strict — a position with a missing /
    ///        zero markPx reverts the trade rather than silently dropping that
    ///        position from the gross-notional sum (which previously allowed
    ///        the leverage cap to be bypassed).
    function _grossOpenPerpNotional6dp() internal view returns (uint256 total) {
        uint256[] memory perps = _whitelistedPerps.values();
        for (uint256 i; i < perps.length; ++i) {
            uint32 a = uint32(perps[i]);
            // Ultrareview bug_007: `position` is read leniently ON PURPOSE. This
            // loop spans ALL whitelisted perps, and HyperCore reverts / returns
            // empty for a perp the vault holds no position in — a strict read
            // would then revert EVERY trade whenever any whitelisted perp is flat.
            // Residual: a POSITION-precompile failure for a HELD position would
            // under-count its notional (cap under-enforced), but that is not
            // operator-triggerable and the cap is documented best-effort with
            // off-chain monitoring (docs/SECURITY.md). Switch to a strict read
            // only if HyperCore is confirmed to return a populated (non-empty)
            // zero-struct for no-position accounts.
            int64 szi = PrecompileLib.position(address(this), a).szi;
            if (szi == 0) continue;
            uint64 markPx = PrecompileLib.markPxStrict(a);
            uint64 absSz = szi < 0 ? uint64(-szi) : uint64(szi);
            total += uint256(absSz) * uint256(markPx);
        }
    }

    /// @dev   Order notional in 6dp USD. Both `sz` and `limitPx` are in the
    ///        limit-order-action 10^8 scale (human * 10^8), so
    ///          sz * limitPx = human_sz * human_px * 10^16,
    ///        and dividing by 1e10 yields human_sz * human_px * 10^6 = 6dp USD.
    function _orderNotional6dp(uint64 sz, uint64 limitPx) internal pure returns (uint256) {
        return (uint256(sz) * uint256(limitPx)) / 1e10;
    }

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
