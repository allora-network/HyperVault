// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ICoreWriter} from "../interfaces/ICoreWriter.sol";
import {Constants} from "./Constants.sol";

/// @notice Typed wrappers around the CoreWriter system contract. Each function
///         packs `(version byte, action id, abi.encode(args))` per Hyperliquid's
///         spec and dispatches via `sendRawAction`.
///
/// @dev    Encoding template:
///             bytes = abi.encodePacked(
///                 uint8(1),                    // version
///                 uint24(ACTION_ID),           // action selector (big-endian)
///                 abi.encode(args...)          // ABI-encoded tail
///             );
///
///         The `uint24` cast is significant: solidity encodes it as exactly 3
///         bytes when used inside `encodePacked`, which matches what the
///         protocol expects after the version byte.
///
///         All actions are FIRE-AND-FORGET — see `ICoreWriter.sendRawAction`.
library CoreWriterLib {
    // -------------------------------------------------------------------------
    // limit_order (action id 1)
    // -------------------------------------------------------------------------

    /// @param asset       Encoded asset id (perpIndex, or 10_000 + spotIndex).
    /// @param isBuy       True = buy / long, false = sell / short.
    /// @param limitPx     Limit price as round(human_px * 10^8) — uniform HL CoreWriter
    ///                    scale, NOT szDecimals-based (a wrong-scale px is silently dropped).
    /// @param sz          Size as round(human_sz * 10^8) — same uniform 10^8 scale.
    /// @param reduceOnly  If true, order can only reduce an existing position.
    /// @param tif         Constants.TIF_* (ALO=1 / GTC=2 / IOC=3, per HL CoreWriter spec).
    /// @param cloid       Client order id (uint128). 0 = no cloid.
    function placeLimitOrder(
        uint32 asset,
        bool isBuy,
        uint64 limitPx,
        uint64 sz,
        bool reduceOnly,
        uint8 tif,
        uint128 cloid
    ) internal {
        bytes memory data = abi.encodePacked(
            Constants.CORE_WRITER_VERSION,
            uint24(Constants.ACTION_LIMIT_ORDER),
            abi.encode(asset, isBuy, limitPx, sz, reduceOnly, tif, cloid)
        );
        ICoreWriter(Constants.CORE_WRITER).sendRawAction(data);
    }

    // -------------------------------------------------------------------------
    // cancel_order_by_oid (action id 10) — emergency only on vault surface
    // -------------------------------------------------------------------------

    function cancelOrderByOid(uint32 asset, uint64 oid) internal {
        bytes memory data = abi.encodePacked(
            Constants.CORE_WRITER_VERSION,
            uint24(Constants.ACTION_CANCEL_BY_OID),
            abi.encode(asset, oid)
        );
        ICoreWriter(Constants.CORE_WRITER).sendRawAction(data);
    }

    // -------------------------------------------------------------------------
    // cancel_order_by_cloid (action id 11)
    // -------------------------------------------------------------------------

    function cancelOrderByCloid(uint32 asset, uint128 cloid) internal {
        bytes memory data = abi.encodePacked(
            Constants.CORE_WRITER_VERSION,
            uint24(Constants.ACTION_CANCEL_BY_CLOID),
            abi.encode(asset, cloid)
        );
        ICoreWriter(Constants.CORE_WRITER).sendRawAction(data);
    }

    // -------------------------------------------------------------------------
    // spot_send (action id 6)
    // -------------------------------------------------------------------------

    /// @notice Move spot balance on Core. Use system address as `to` to bridge
    ///         balance back to the EVM-side ERC20.
    function spotSend(address to, uint64 token, uint64 amountWei) internal {
        bytes memory data = abi.encodePacked(
            Constants.CORE_WRITER_VERSION,
            uint24(Constants.ACTION_SPOT_SEND),
            abi.encode(to, token, amountWei)
        );
        ICoreWriter(Constants.CORE_WRITER).sendRawAction(data);
    }

    /// @notice Move a Core asset via the unified-account `send_asset` action
    ///         (id 13). Audit G2: REQUIRED instead of {spotSend} (id 6) for
    ///         unified HyperCore accounts — `spot_send`/`spot_transfer` is
    ///         SILENTLY DROPPED there (proven live 2026-06-15: the EVM tx
    ///         succeeds, fire-and-forget, but Core never debits and no ledger
    ///         entry appears). To bridge balance back to the EVM-side token, set
    ///         `recipient` to that token's system address — the HyperCore system
    ///         then invokes the linked EVM contract (for native USDC, Circle's
    ///         CoreDepositWallet `transfer`, paying native USDC from its reserve).
    /// @dev    Payload matches Circle's CoreDepositWallet `_sendAsset` byte-for-byte:
    ///         abi.encode(recipient, subAccount=address(0), sourceDex,
    ///         destinationDex, tokenIndex, amount). `amount` is in Core wei (8dp
    ///         for USDC). subAccount is always address(0) (subaccounts unused).
    /// @param recipient       Core recipient, or the token system address to withdraw to EVM.
    /// @param sourceDex       Dex the funds sit on (Core Spot = type(uint32).max).
    /// @param destinationDex  Destination dex.
    /// @param token           Core token index.
    /// @param amountWei       Amount in Core wei (8dp for USDC).
    function sendAsset(address recipient, uint32 sourceDex, uint32 destinationDex, uint64 token, uint64 amountWei)
        internal
    {
        bytes memory data = abi.encodePacked(
            Constants.CORE_WRITER_VERSION,
            uint24(Constants.ACTION_SEND_ASSET),
            abi.encode(recipient, address(0), sourceDex, destinationDex, token, amountWei)
        );
        ICoreWriter(Constants.CORE_WRITER).sendRawAction(data);
    }

    // -------------------------------------------------------------------------
    // usd_class_transfer (action id 7)
    // -------------------------------------------------------------------------

    /// @notice Move USD between Core spot and Core perp margin classes.
    /// @param ntl     Amount in 6dp USD.
    /// @param toPerp  True = spot → perp; false = perp → spot.
    function usdClassTransfer(uint64 ntl, bool toPerp) internal {
        bytes memory data = abi.encodePacked(
            Constants.CORE_WRITER_VERSION,
            uint24(Constants.ACTION_USD_CLASS_TRANSFER),
            abi.encode(ntl, toPerp)
        );
        ICoreWriter(Constants.CORE_WRITER).sendRawAction(data);
    }

    // -------------------------------------------------------------------------
    // vault_transfer (action id 2) — exposed for future v1.x use
    // -------------------------------------------------------------------------

    /// @dev Reserved for delegating capital to a legacy HyperCore native vault.
    ///      Not used by the v1 surface but encoded here so callers don't need
    ///      to hand-roll the bytes if they extend the vault.
    function vaultTransfer(address vault, bool isDeposit, uint64 usd) internal {
        bytes memory data = abi.encodePacked(
            Constants.CORE_WRITER_VERSION,
            uint24(Constants.ACTION_VAULT_TRANSFER),
            abi.encode(vault, isDeposit, usd)
        );
        ICoreWriter(Constants.CORE_WRITER).sendRawAction(data);
    }
}
