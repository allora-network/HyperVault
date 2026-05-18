// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Constants} from "./Constants.sol";

/// @notice Derives HyperCore "system addresses" — the per-token bridge addresses
///         used both as `spot_send` destinations (Core → EVM) and as the recipient
///         of ERC20 `transfer` calls on the linked contract (EVM → Core).
/// @dev    Layout: `0x20 || 19 zero bytes || tokenIndex (uint64 BE)`. The top
///         byte is the system-address prefix; bytes 1..11 are zero; bytes 12..19
///         hold the big-endian token index.
///
///         HYPE is the exception — it uses the fixed address 0x2222…2222.
library SystemAddress {
    /// @notice Compute the system / bridge address for a Core token index.
    function forToken(uint64 tokenIndex) internal pure returns (address) {
        // bytes20: [0x20][11 zero bytes][8 bytes tokenIndex BE]
        uint256 prefix = uint256(uint8(Constants.TOKEN_SYSTEM_PREFIX)) << 152;
        return address(uint160(prefix | uint256(tokenIndex)));
    }

    /// @notice Convenience: the USDC bridge address.
    function usdc() internal pure returns (address) {
        return forToken(Constants.USDC_CORE_INDEX);
    }

    /// @notice Is this address one of the per-token system addresses (prefix 0x20)?
    function isSystemAddress(address a) internal pure returns (bool) {
        return uint160(a) >> 152 == uint8(Constants.TOKEN_SYSTEM_PREFIX);
    }
}
