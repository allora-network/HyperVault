// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IHyperCoreVault} from "../interfaces/IHyperCoreVault.sol";
import {ICoreDepositWallet} from "../interfaces/ICoreDepositWallet.sol";
import {CoreWriterLib} from "./CoreWriterLib.sol";
import {SystemAddress} from "./SystemAddress.sol";
import {Constants} from "./Constants.sol";

/// @title  VaultEmergencyLib — externalized emergency / operator-recovery surface
/// @notice Audit G2 (EIP-170): factored out of {HyperCoreVault} so the vault's
///         runtime bytecode fits the 24576-byte contract-size limit (HyperEVM
///         enforces it). This is the SAME sanctioned move that created
///         {VaultTradeLib} (trade gate + emergency close) and {VaultEscapeLib}
///         (M5 escape cranks) — externalizing audited logic into a delegatecall
///         library while preserving behaviour byte-for-byte. The M5 escape latch
///         pushed the vault back over the limit; rather than touch the latch/crank
///         surface, the emergency cancel + repatriate BODIES move here.
///
///         Every function is invoked by the vault via DELEGATECALL, so
///         `address(this)` is the vault: CoreWriter sees the vault as the action's
///         sender and the `spotRecoverDest` allowlist resolves against the vault's
///         own storage (threaded in by storage reference), exactly as when this
///         code was inlined.
///
/// @dev    Behaviour is byte-for-byte preserved from the prior inlined version
///         (the C-2 allowlist check, the `send_asset` action-13 route per audit
///         G2, the perp->spot leg, the emitted logs, and the revert selectors).
///         The events and errors below MIRROR {IHyperCoreVault} with identical
///         signatures, so logs (topic0 + data) and revert selectors are
///         indistinguishable from the in-vault originals across the delegatecall
///         boundary. Vault role-gating (`onlyRole(EMERGENCY_ROLE)`) and
///         `nonReentrant` stay on the thin vault wrappers. The only vault state
///         read here is the `spotRecoverDest` mapping (by reference); `coreUsdcIndex`
///         is an IMMUTABLE (baked into the vault's bytecode, not reachable by a
///         delegatecall library) so the vault threads it in by value.
library VaultEmergencyLib {
    using SafeERC20 for IERC20;

    /// @notice Mirror {IHyperCoreVault.OrderCancelByCloidSubmitted} so a leg-by-cloid
    ///         cancel is logged identically across the delegatecall boundary.
    event OrderCancelByCloidSubmitted(uint32 indexed asset, uint128 indexed cloid);
    /// @notice Mirror {IHyperCoreVault.OrderCancelByOidSubmitted}.
    event OrderCancelByOidSubmitted(uint32 indexed asset, uint64 indexed oid);
    /// @notice Mirror {IHyperCoreVault.UsdClassTransferSubmitted} — the perp->spot leg.
    event UsdClassTransferSubmitted(uint64 ntl, bool toPerp);
    /// @notice Mirror {IHyperCoreVault.OperatorSpotRecovered} — the spot-send leg.
    event OperatorSpotRecovered(address indexed to, uint64 token, uint64 amountWei);
    /// @notice Mirror {IHyperCoreVault.EmergencyRepatriated} — the repatriate summary.
    event EmergencyRepatriated(address indexed to, uint64 perpToSpotNtl, uint64 spotSendWei);
    /// @notice Mirror {IHyperCoreVault.StrandedSwept} — the empty-vault EVM sweep.
    event StrandedSwept(address indexed to, uint256 amount);
    /// @notice Mirror {IHyperCoreVault.BridgeDeposit} — EVM USDC -> Core (push).
    event BridgeDeposit(uint64 amount);
    /// @notice Mirror {IHyperCoreVault.BridgeWithdraw} — Core USDC -> EVM (pull).
    event BridgeWithdraw(uint64 amountWei);

    /// @notice Mirror {IHyperCoreVault.SpotRecoverDestinationNotAllowed} — the C-2 guard.
    error SpotRecoverDestinationNotAllowed(address dest);
    /// @notice Mirror {IHyperCoreVault.ZeroAddress}.
    error ZeroAddress();
    /// @notice Mirror {IHyperCoreVault.StrandedSweepRequiresZeroSupply}.
    error StrandedSweepRequiresZeroSupply();
    /// @notice Mirror {IHyperCoreVault.WithdrawExceedsIdleBalance} — the H2 push guard.
    error WithdrawExceedsIdleBalance(uint256 requested, uint256 idle);

    // -------------------------------------------------------------------------
    // Emergency cancels
    // -------------------------------------------------------------------------

    /// @notice Cancel batches of the vault's resting orders by client order id.
    /// @dev    Byte-for-byte the inlined {HyperCoreVault.emergencyCancelByCloid}:
    ///         the `assets.length == cloids.length` invariant, the nested loop, and
    ///         one {OrderCancelByCloidSubmitted} per cloid. CoreWriter is
    ///         fire-and-forget (a cancel for an already-gone order is a Core no-op).
    function emergencyCancelByCloid(uint32[] calldata assets, uint128[][] calldata cloids) external {
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

    /// @notice Cancel one of the vault's resting orders by exchange order id.
    /// @dev    Byte-for-byte the inlined {HyperCoreVault.emergencyCancelByOid}.
    function emergencyCancelByOid(uint32 asset_, uint64 oid) external {
        CoreWriterLib.cancelOrderByOid(asset_, oid);
        emit OrderCancelByOidSubmitted(asset_, oid);
    }

    // -------------------------------------------------------------------------
    // Emergency repatriate (audit H2) — perp->spot + spot-send toward idle
    // -------------------------------------------------------------------------

    /// @notice Repatriate Core funds toward LP redeemability when the operator key
    ///         is dark/compromised: move perp equity to spot and/or send Core spot
    ///         USDC to either the canonical USDC bridge (-> vault idle) or an
    ///         allowlisted (C-2) treasury for the Path-B refill.
    /// @dev    Byte-for-byte the inlined {HyperCoreVault.emergencyRepatriate}: the
    ///         perp->spot leg runs first when `perpToSpotNtl > 0`; the spot-send leg
    ///         (when `spotSendWei > 0`) is C-2-gated to `SystemAddress.usdc()` OR an
    ///         allowlisted `spotRecoverDest`, and uses `send_asset` (action 13) per
    ///         audit G2 (the dropped `spot_send` is never used). The summary
    ///         {EmergencyRepatriated} always fires. `spotRecoverDest` is the vault's
    ///         allowlist by storage reference; `coreUsdcIndex` is the vault's
    ///         immutable, threaded in by value.
    /// @param  spotRecoverDest  the vault's C-2 allowlist (by storage reference).
    /// @param  coreUsdcIndex    the vault's immutable Core-USDC token index.
    /// @param  to               spot-send destination (bridge or allowlisted treasury);
    ///                          ignored when `spotSendWei == 0`.
    /// @param  perpToSpotNtl    6dp USD to move perp->spot first (0 = skip).
    /// @param  spotSendWei      Core-wei USDC to spot-send to `to` (0 = skip).
    function emergencyRepatriate(
        mapping(address => bool) storage spotRecoverDest,
        uint64 coreUsdcIndex,
        address to,
        uint64 perpToSpotNtl,
        uint64 spotSendWei
    ) external {
        if (perpToSpotNtl > 0) {
            CoreWriterLib.usdClassTransfer(perpToSpotNtl, false); // perp -> spot
            emit UsdClassTransferSubmitted(perpToSpotNtl, false);
        }
        if (spotSendWei > 0) {
            if (to != SystemAddress.usdc() && !spotRecoverDest[to]) {
                revert SpotRecoverDestinationNotAllowed(to);
            }
            // Audit G2: send_asset (action 13), not the dropped spot_send. `to` =
            // the USDC system address repatriates to this vault's EVM idle (the
            // wallet pays the caller); an allowlisted treasury is a peer Core move.
            CoreWriterLib.sendAsset(
                to, Constants.CORE_SPOT_DEX_ID, Constants.CORE_SPOT_DEX_ID, coreUsdcIndex, spotSendWei
            );
            emit OperatorSpotRecovered(to, coreUsdcIndex, spotSendWei);
        }
        emit EmergencyRepatriated(to, perpToSpotNtl, spotSendWei);
    }

    // -------------------------------------------------------------------------
    // Operator recovery (kin to the emergency surface — same C-2 / sweep shapes)
    // -------------------------------------------------------------------------

    /// @notice Send a Core spot token from the vault's Core account to an
    ///         allowlisted (C-2) destination. CONTINGENCY path (audit G2).
    /// @dev    Byte-for-byte the inlined {HyperCoreVault.operatorRecoverSpot}: the
    ///         `to != 0` guard, the C-2 `spotRecoverDest` check, the `send_asset`
    ///         (action 13) route per audit G2, and the {OperatorSpotRecovered} log.
    ///         The role gate (`OPERATOR_ROLE`) + `nonReentrant` stay on the vault
    ///         wrapper. `spotRecoverDest` is the vault's allowlist by storage
    ///         reference; `token`/`amountWei` are caller-supplied.
    function operatorRecoverSpot(
        mapping(address => bool) storage spotRecoverDest,
        address to,
        uint64 token,
        uint64 amountWei
    ) external {
        if (to == address(0)) revert ZeroAddress();
        if (!spotRecoverDest[to]) revert SpotRecoverDestinationNotAllowed(to);
        // Audit G2: send_asset (action 13), not the dropped spot_send — see the vault.
        CoreWriterLib.sendAsset(to, Constants.CORE_SPOT_DEX_ID, Constants.CORE_SPOT_DEX_ID, token, amountWei);
        emit OperatorSpotRecovered(to, token, amountWei);
    }

    /// @notice Sweep the vault's EVM-side `asset()` balance when there are no LPs.
    /// @dev    Byte-for-byte the inlined {HyperCoreVault.operatorSweepStranded}: the
    ///         `to != 0` guard, the `totalSupply == 0` precondition, and the
    ///         {StrandedSwept} log. Under delegatecall `address(this)` is the vault,
    ///         so `asset()` / `totalSupply()` resolve via a self-call back into it
    ///         (the same pattern {VaultEscapeLib} uses for `previewRedeem`). The
    ///         role gate (`OPERATOR_ROLE`) + `nonReentrant` stay on the vault wrapper.
    function operatorSweepStranded(address to) external {
        if (to == address(0)) revert ZeroAddress();
        if (IHyperCoreVault(address(this)).totalSupply() != 0) revert StrandedSweepRequiresZeroSupply();
        IERC20 asset = IERC20(IHyperCoreVault(address(this)).asset());
        uint256 bal = asset.balanceOf(address(this));
        if (bal > 0) {
            asset.safeTransfer(to, bal);
            emit StrandedSwept(to, bal);
        }
    }

    // -------------------------------------------------------------------------
    // Bridge routing (EVM <-> Core) — the route bodies (audit G2)
    // -------------------------------------------------------------------------

    /// @notice Move `amount` EVM USDC to the vault's Core spot balance.
    /// @dev    Byte-for-byte the inlined {HyperCoreVault.pushToCore}: the audit-H2
    ///         reserved-idle guard runs FIRST (`amount > availableIdle` reverts
    ///         {WithdrawExceedsIdleBalance} with the identical args, before any
    ///         transfer), then the route — wallet mode = `forceApprove(wallet,
    ///         amount) + deposit(amount, CORE_SPOT_DEX_ID) + forceApprove(wallet, 0)`
    ///         (the trailing zero-approve is the defensive allowance-clear); legacy
    ///         mode (`wallet == 0`) = an ERC20 transfer to the USDC system address.
    ///         Emits {BridgeDeposit}. The `whenNotPaused`/`OPERATOR_ROLE`/escape gate
    ///         + `nonReentrant` stay on the vault wrapper (the modifiers); the vault
    ///         passes `availableIdle` (= `_availableIdle()`) by value so the H2 floor
    ///         is enforced WITHOUT exposing the private `_reservedIdle`. `wallet` is
    ///         the vault's immutable {coreDepositWallet}; `asset()` resolves via
    ///         self-call under delegatecall.
    function pushToCoreRoute(address wallet, uint64 amount, uint256 availableIdle) external {
        // Audit H2: cannot deploy idle reserved for an overdue prioritized request
        // (Finding F) — the reserve is LP-claimable idle, not operator capital.
        if (amount > availableIdle) revert WithdrawExceedsIdleBalance(amount, availableIdle);
        IERC20 asset = IERC20(IHyperCoreVault(address(this)).asset());
        if (wallet == address(0)) {
            // Legacy HIP-1 route (direct-linked assets only): ERC20 transfer to the
            // token system address — Core credits 8dp wei after evmExtraWeiDecimals.
            asset.safeTransfer(SystemAddress.usdc(), amount);
        } else {
            asset.forceApprove(wallet, amount);
            ICoreDepositWallet(wallet).deposit(amount, Constants.CORE_SPOT_DEX_ID);
            asset.forceApprove(wallet, 0);
        }
        emit BridgeDeposit(amount);
    }

    /// @notice Withdraw `amountWei` Core USDC back to the vault's EVM idle.
    /// @dev    Byte-for-byte the inlined {HyperCoreVault.pullFromCore}: a
    ///         `send_asset` (action 13, spot->spot) to the USDC system address —
    ///         the action-6 `spot_send` is silently dropped for unified accounts
    ///         (audit G2, proven live 2026-06-15). HyperCore debits the vault's Core
    ///         spot and the linked CoreDepositWallet pays native USDC to the caller
    ///         (this vault) at amountWei/100 (8dp Core -> 6dp EVM). Emits
    ///         {BridgeWithdraw}. The `OPERATOR_ROLE` gate + `nonReentrant` stay on
    ///         the vault wrapper (it is deliberately NOT `whenNotPaused` — H2).
    ///         `coreUsdcIndex` is the vault's immutable, threaded in by value.
    function pullFromCore(uint64 coreUsdcIndex, uint64 amountWei) external {
        CoreWriterLib.sendAsset(
            SystemAddress.forToken(coreUsdcIndex),
            Constants.CORE_SPOT_DEX_ID,
            Constants.CORE_SPOT_DEX_ID,
            coreUsdcIndex,
            amountWei
        );
        emit BridgeWithdraw(amountWei);
    }
}
