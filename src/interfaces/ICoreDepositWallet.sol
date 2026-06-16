// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @notice Minimal surface of Circle's CoreDepositWallet — the official
///         EVM<->Core bridge contract for natively-minted USDC on HyperEVM
///         (audit G2). Mainnet: `0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24`,
///         which is exactly `tokenInfo(0).evmContract`. Source:
///         github.com/circlefin/hyperevm-circle-contracts (CoreDepositWallet.sol).
/// @dev    Trust model: the wallet is a Circle-operated EIP-1967 upgradeable,
///         pausable proxy holding the EVM-side reserve that backs all Core USDC.
///         This is issuer trust — the same class as holding USDC at all — but
///         note BOTH directions stop while the wallet is paused: `deposit` is
///         `whenNotPaused`, and the Core->EVM payout hook (`transfer`, callable
///         only by the token system address) is `whenNotPaused` too. The vault
///         therefore keeps `operatorRecoverSpot` (audit C-2) as a contingency.
///
///         The vault deliberately uses only this minimal surface:
///         - `deposit` is the single mutating call (`depositFor`/`depositWithAuth`
///           are for third-party/authorized deposits the vault never makes);
///         - `transfer` (the payout hook) is system-address-only, never vault-callable;
///         - the dex-forwarding config getters are irrelevant because the vault
///           always deposits to Core SPOT (see {Constants.CORE_SPOT_DEX_ID}).
interface ICoreDepositWallet {
    /// @notice Deposit `amount` of the wallet's token (6dp EVM scale) from the
    ///         caller to the caller's HyperCore account.
    /// @param amount         EVM token units (6dp). Must be > 0 and small enough
    ///                       to scale into Core's 8dp uint64 range.
    /// @param destinationDex `type(uint32).max` = Core SPOT (direct credit, no
    ///                       fee); `0` = main perps dex via the wallet's
    ///                       CoreWriter forwarding (subject to the wallet's
    ///                       mutable dex config and a new-Core-account fee).
    function deposit(uint256 amount, uint32 destinationDex) external;

    /// @notice The ERC-20 the wallet custodies. MUST equal the vault's `asset()`
    ///         (validated at vault deploy — audit G2).
    function token() external view returns (address);

    /// @notice The per-token system address (`0x20..00 || tokenIndex`) whose
    ///         Core-side receipt triggers the EVM payout. MUST equal
    ///         `SystemAddress.forToken(coreUsdcIndex)` (validated at deploy).
    function tokenSystemAddress() external view returns (address);

    /// @notice Circle's pause switch. Not checked on-chain by the vault (transient
    ///         operational state; the wallet's own `whenNotPaused` revert bubbles
    ///         up through {IHyperCoreVault.pushToCore}) — exposed for tooling,
    ///         runner preflights, and fork-test self-guards.
    function paused() external view returns (bool);
}
