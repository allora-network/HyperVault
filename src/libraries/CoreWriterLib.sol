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
