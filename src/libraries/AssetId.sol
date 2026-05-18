// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Constants} from "./Constants.sol";

/// @notice CoreWriter `limit_order` and `cancel_order_*` actions take a single
///         `uint32 asset` field. The HyperCore convention is:
///
///         - Perp markets: `asset = perpIndex`              (0 ≤ perpIndex < 10_000)
///         - Spot markets: `asset = 10_000 + spotIndex`     (spot has its own index space)
///
///         This library encodes / decodes that field and offers a `isPerp`
///         classifier used by the vault's whitelist gate.
library AssetId {
    error InvalidPerpIndex(uint32 perpIndex);

    /// @notice Encode a perp index into the CoreWriter asset field.
    function perp(uint32 perpIndex) internal pure returns (uint32) {
        if (perpIndex >= Constants.SPOT_ASSET_OFFSET) revert InvalidPerpIndex(perpIndex);
        return perpIndex;
    }

    /// @notice Encode a spot index into the CoreWriter asset field.
    function spot(uint32 spotIndex) internal pure returns (uint32) {
        // Cannot overflow uint32 in practice (spot index < 2^22).
        return Constants.SPOT_ASSET_OFFSET + spotIndex;
    }

    /// @notice True if the asset id refers to a spot market.
    function isSpot(uint32 asset) internal pure returns (bool) {
        return asset >= Constants.SPOT_ASSET_OFFSET;
    }

    /// @notice True if the asset id refers to a perp market.
    function isPerp(uint32 asset) internal pure returns (bool) {
        return asset < Constants.SPOT_ASSET_OFFSET;
    }

    /// @notice Decode the underlying index (perp or spot).
    function indexOf(uint32 asset) internal pure returns (uint32) {
        return isSpot(asset) ? asset - Constants.SPOT_ASSET_OFFSET : asset;
    }
}
