// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @notice Minimal interface for the CoreWriter system contract at
///         0x3333333333333333333333333333333333333333.
/// @dev    `sendRawAction` is fire-and-forget: it emits a `RawAction` event on
///         the EVM side and hands execution to HyperCore. It does NOT revert if
///         the action is later rejected by HyperCore (insufficient margin,
///         invalid asset, post-only crossed, etc.). Callers must reconcile fills
///         off-chain via the L1 read precompiles or HL API.
interface ICoreWriter {
    /// @notice Emitted by the system contract on every successful submission.
    /// @dev    `data` is the raw payload as defined in `CoreWriterLib`.
    event RawAction(address indexed user, bytes data);

    /// @notice Submit a CoreWriter action.
    /// @param  data Action payload: `abi.encodePacked(uint8(1), uint24(actionId), abi.encode(args))`.
    function sendRawAction(bytes calldata data) external;
}
