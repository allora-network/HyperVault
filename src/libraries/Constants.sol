// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @notice Protocol-wide constants for the HyperCore vault template.
/// @dev    All addresses, token indices, and decimals are fixed by the
///         HyperEVM / HyperCore protocol. If Hyperliquid changes them in
///         a future fork, bump the constants here in a single place.
library Constants {
    // -------------------------------------------------------------------------
    // System addresses (HyperEVM)
    // -------------------------------------------------------------------------

    /// @notice CoreWriter system contract: dispatches actions from HyperEVM to HyperCore.
    address internal constant CORE_WRITER = 0x3333333333333333333333333333333333333333;

    /// @notice Native HYPE token has a fixed system address (not derived from token index).
    address internal constant HYPE_SYSTEM_ADDR = 0x2222222222222222222222222222222222222222;

    // -------------------------------------------------------------------------
    // L1 read precompiles
    // -------------------------------------------------------------------------

    // Note: using integer literals + explicit cast to bypass EIP-55 checksum
    // requirements on mixed-case 40-char hex literals. These are pseudo-addresses
    // defined by the HyperEVM protocol, not real account addresses, so the EIP-55
    // checksum is irrelevant.
    address internal constant POSITION_PRECOMPILE          = address(uint160(0x800));
    address internal constant SPOT_BALANCE_PRECOMPILE      = address(uint160(0x801));
    address internal constant VAULT_EQUITY_PRECOMPILE      = address(uint160(0x802));
    address internal constant WITHDRAWABLE_PRECOMPILE      = address(uint160(0x803));
    address internal constant DELEGATIONS_PRECOMPILE       = address(uint160(0x804));
    address internal constant DELEGATOR_SUMMARY_PRECOMPILE = address(uint160(0x805));
    address internal constant MARK_PX_PRECOMPILE           = address(uint160(0x806));
    address internal constant ORACLE_PX_PRECOMPILE         = address(uint160(0x807));
    address internal constant SPOT_PX_PRECOMPILE           = address(uint160(0x808));
    address internal constant L1_BLOCK_NUMBER_PRECOMPILE   = address(uint160(0x809));
    address internal constant PERP_ASSET_INFO_PRECOMPILE   = address(uint160(0x80A));
    address internal constant SPOT_INFO_PRECOMPILE         = address(uint160(0x80B));
    address internal constant TOKEN_INFO_PRECOMPILE        = address(uint160(0x80C));
    address internal constant TOKEN_SUPPLY_PRECOMPILE      = address(uint160(0x80D));
    address internal constant BBO_PRECOMPILE               = address(uint160(0x80E));
    address internal constant ACCOUNT_MARGIN_PRECOMPILE    = address(uint160(0x80F));
    address internal constant CORE_USER_EXISTS_PRECOMPILE  = address(uint160(0x810));

    // -------------------------------------------------------------------------
    // CoreWriter action IDs (24-bit, packed after version byte 0x01)
    // -------------------------------------------------------------------------

    uint24 internal constant ACTION_LIMIT_ORDER          = 1;
    uint24 internal constant ACTION_VAULT_TRANSFER       = 2;
    uint24 internal constant ACTION_TOKEN_DELEGATE       = 3;
    uint24 internal constant ACTION_STAKING_DEPOSIT      = 4;
    uint24 internal constant ACTION_STAKING_WITHDRAW     = 5;
    uint24 internal constant ACTION_SPOT_SEND            = 6;
    uint24 internal constant ACTION_USD_CLASS_TRANSFER   = 7;
    uint24 internal constant ACTION_FINALIZE_EVM         = 8;
    uint24 internal constant ACTION_ADD_API_WALLET       = 9;
    uint24 internal constant ACTION_CANCEL_BY_OID        = 10;
    uint24 internal constant ACTION_CANCEL_BY_CLOID      = 11;
    uint24 internal constant ACTION_APPROVE_BUILDER_FEE  = 12;
    uint24 internal constant ACTION_SEND_ASSET           = 13;

    /// @notice Encoding version. Currently 1. Bumped only when CoreWriter
    ///         introduces a non-backwards-compatible action layout.
    uint8 internal constant CORE_WRITER_VERSION = 1;

    // -------------------------------------------------------------------------
    // TIF (time in force) enum, encoded as uint8 in limit_order payload.
    //
    // Values are fixed by the HyperCore `limit_order` action and are 1-INDEXED:
    //   1 = Alo, 2 = Gtc, 3 = Ioc
    // See the Hyperliquid CoreWriter docs ("Interacting with HyperCore") and the
    // canonical hyper-evm-lib HLConstants (LIMIT_ORDER_TIF_ALO/GTC/IOC = 1/2/3).
    // A tif byte of 0 is OUT OF RANGE: HyperCore silently drops the action
    // (CoreWriter is fire-and-forget, so the EVM tx still succeeds but no order
    // ever rests). There is no FOK variant in the CoreWriter limit_order encoding.
    // -------------------------------------------------------------------------

    uint8 internal constant TIF_ALO = 1; // add liquidity only (post-only)
    uint8 internal constant TIF_GTC = 2; // good till cancel
    uint8 internal constant TIF_IOC = 3; // immediate or cancel

    // -------------------------------------------------------------------------
    // Asset ID encoding (CoreWriter limit_order `asset` field)
    // -------------------------------------------------------------------------

    /// @notice Spot asset IDs are encoded as 10000 + spotIndex.
    uint32 internal constant SPOT_ASSET_OFFSET = 10_000;

    // -------------------------------------------------------------------------
    // USDC (the quote asset for v1)
    // -------------------------------------------------------------------------

    /// @notice Core spot token index for USDC.
    uint64 internal constant USDC_CORE_INDEX = 0;

    /// @notice HyperCore stores USDC spot balance with this many decimals.
    /// @dev    Verify on chain via `tokenInfo(USDC_CORE_INDEX).weiDecimals` at deploy;
    ///         the factory asserts this matches before deploying a vault.
    uint8 internal constant USDC_CORE_DECIMALS = 8;

    /// @notice EVM-side USDC ERC20 decimals.
    uint8 internal constant USDC_EVM_DECIMALS = 6;

    /// @notice Perp `withdrawable` is denominated in USD with this many decimals.
    /// @dev    Matches the EVM ERC20 decimals — no scaling needed when adding to NAV.
    uint8 internal constant PERP_USD_DECIMALS = 6;

    /// @notice CoreDepositWallet `destinationDex` value for the Core SPOT dex
    ///         (audit G2). The wallet credits the depositor's Core spot balance
    ///         directly — the leg `coreSpotUsdc()` reads — with no dependence on
    ///         the wallet's mutable dex-forwarding config and no new-Core-account
    ///         fee (both apply only to dex-forwarded deposits, e.g. perps = 0).
    uint32 internal constant CORE_SPOT_DEX_ID = type(uint32).max;

    // -------------------------------------------------------------------------
    // Bridge address prefix
    // -------------------------------------------------------------------------

    /// @notice Token system / bridge addresses start with this byte.
    bytes1 internal constant TOKEN_SYSTEM_PREFIX = 0x20;

    // -------------------------------------------------------------------------
    // Math
    // -------------------------------------------------------------------------

    uint256 internal constant BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant WAD = 1e18;
}
