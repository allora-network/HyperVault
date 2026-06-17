// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Constants} from "./Constants.sol";

/// @title  VaultBarrierLib — externalized soft-redemption-barrier logic + state
/// @notice M4 (SOLU-3366) / EIP-170: the soft redemption barriers (lockup /
///         cooldown / per-tx gate) for {HyperCoreVault} live here, factored out
///         exactly like the audit-G2 {VaultTradeLib} split so the vault's runtime
///         bytecode stays under the 24576-byte limit (HyperEVM enforces it; the
///         vault had only ~339 B of headroom). Every function is invoked by the
///         vault via DELEGATECALL, so `address(this)` is the vault — the namespaced
///         storage below, and the {block.timestamp}/{msg.sender} reads, all resolve
///         against the VAULT, identical to inlining.
///
/// @dev    STORAGE OWNERSHIP. Unlike {VaultTradeLib} (stateless, value-threaded),
///         this library OWNS the barrier state, held at an ERC-7201 NAMESPACED slot
///         so it can never collide with the vault's inheritance-laid-out storage no
///         matter how the vault evolves (the vault declares NO barrier storage vars
///         of its own). The vault reads the config for its view getters via the same
///         namespace (a tiny inline `sload`, since a `view` getter cannot itself
///         delegatecall) — see {HyperCoreVault} getters and {SLOT}.
///
///         SELECTORS. The three revert errors MIRROR {IHyperCoreVault} with
///         identical signatures, so a barrier revert is indistinguishable from an
///         inlined one across the delegatecall boundary; the vault re-declares the
///         same errors + the {RedemptionBarriersUpdated} event for its ABI.
///
///         SAFETY SCOPE (the load-bearing invariant). These barriers gate the
///         SYNCHRONOUS exit paths only. The vault never routes its queue
///         (`requestWithdraw`/`fulfillWithdraw`/`cancelWithdrawRequest`/
///         `prioritizeOverdue`), its emergency surface, or any Core->EVM
///         repatriation mover through this library — so redemption liveness
///         (assessment Findings A/B) is preserved: the always-available escape is
///         the ungated request queue.
library VaultBarrierLib {
    // Mirror {IHyperCoreVault} — identical selectors across the delegatecall.
    error LockupNotElapsed(uint64 unlockAt);
    error RedeemCooldownActive(uint64 readyAt);
    error RedeemGateExceeded(uint256 requested, uint256 cap);
    error RedeemGateBpsTooHigh(uint16 gateBps);

    event RedemptionBarriersUpdated(uint64 lockup, uint64 cooldown, uint16 gateBps);

    /// @notice Barrier state. One struct in a namespaced slot keeps the three knobs
    ///         packed (64+64+16 bits in the first word) plus the two per-LP clocks.
    /// @dev    `lockupPeriod` / `redeemCooldown` (seconds) and `redeemGateBps` (bps
    ///         of NAV) each default to 0 = OFF. `lastDepositAt` stamps the lockup
    ///         clock (most-recent deposit; re-deposits refresh it); `lastRedeemAt`
    ///         stamps the cooldown clock (most-recent SYNCHRONOUS redemption).
    struct Barriers {
        uint64 lockupPeriod;
        uint64 redeemCooldown;
        uint16 redeemGateBps;
        mapping(address => uint64) lastDepositAt;
        mapping(address => uint64) lastRedeemAt;
    }

    /// @notice ERC-7201 namespaced storage root for {Barriers}. The vault's getters
    ///         read the scalar config from the SAME slot (see {HyperCoreVault}).
    /// @dev    keccak256(abi.encode(uint256(keccak256("hypervault.storage.barriers")) - 1)) & ~0xff
    ///         (ERC-7201). The vault's getters read the same constant — keep in sync.
    bytes32 internal constant SLOT = 0x77baf71947acbe45a89d2c84006fb2f1cbe1654c8023f6853f43b8e463ccc600;

    function _s() private pure returns (Barriers storage s) {
        bytes32 slot = SLOT;
        assembly {
            s.slot := slot
        }
    }

    /// @notice DELEGATECALL — set all three barriers at once (admin-gated in the
    ///         vault wrapper). A 0 disables that barrier; all three default to 0.
    /// @dev    EIP-170: the WHOLE setter body (validation + the namespaced write + the
    ///         event) lives here so none of it sits in the vault's runtime bytecode —
    ///         the vault carries only a thin `onlyRole` + delegatecall wrapper. The
    ///         three knobs pack into the first word at {SLOT} (Solidity packs
    ///         `lockupPeriod` into bits[0:64], `redeemCooldown` [64:128],
    ///         `redeemGateBps` [128:144]); {enforce} and the off-chain readers in
    ///         docs/INTEGRATION.md decode that word the same way. `gateBps > BPS`
    ///         (100% of NAV) is meaningless → revert. Emits the vault-mirrored
    ///         {RedemptionBarriersUpdated}.
    function setBarriers(uint64 lockup, uint64 cooldown, uint16 gateBps) external {
        if (gateBps > Constants.BPS) revert RedeemGateBpsTooHigh(gateBps);
        Barriers storage s = _s();
        s.lockupPeriod = lockup;
        s.redeemCooldown = cooldown;
        s.redeemGateBps = gateBps;
        emit RedemptionBarriersUpdated(lockup, cooldown, gateBps);
    }

    /// @notice DELEGATECALL — stamp `receiver`'s lockup clock on a deposit/mint.
    ///         Always written (cheap); the lockup is only ENFORCED when
    ///         {Barriers.lockupPeriod} != 0, so this is a harmless no-op effect at
    ///         the default. Most-recent deposit governs (re-deposits refresh it).
    /// @dev    The vault inlines this same write (one `sstore` to {SLOT}+1's mapping
    ///         element) in `HyperCoreVault._stampDeposit` to save the delegatecall's
    ///         bytecode at its two call sites (EIP-170). This canonical definition
    ///         documents the slot semantics and is the entry tests/integrators use.
    function stampDeposit(address receiver) external {
        _s().lastDepositAt[receiver] = uint64(block.timestamp);
    }

    /// @notice DELEGATECALL — enforce the barriers for ONE synchronous
    ///         {HyperCoreVault.withdraw}/{redeem}, reverting on the first violation,
    ///         then stamp the owner's cooldown clock.
    /// @dev    Fast path: all three OFF → returns after a single packed SLOAD with
    ///         NO further reads, NO stamp, behaviour identical to pre-M4 (so a vault
    ///         that never opts in is unchanged). Barriers are keyed on the SHARE
    ///         `owner` (not the caller): the lockup follows the owner's last deposit
    ///         and the cooldown the owner's last sync redemption, so a router /
    ///         approved spender redeeming on the owner's behalf inherits the owner's
    ///         friction. `grossAssets` is the PRE-partial-fill value requested this
    ///         tx, so the gate bounds the request and cannot be dodged via a partial
    ///         fill. `nav` is {HyperCoreVault.totalAssets} (the gate denominator),
    ///         read once by the vault and threaded in (the vault already computes it
    ///         for its NAV reads, so reusing it is cheaper than a self-call here).
    ///         When a barrier IS active the cooldown clock is stamped on every
    ///         value-moving exit — even if the cooldown itself is currently OFF — so
    ///         enabling a cooldown later measures from this exit, not a stale value.
    function enforce(address owner, uint256 grossAssets, uint256 nav) external {
        Barriers storage s = _s();
        uint64 lk = s.lockupPeriod;
        uint64 cd = s.redeemCooldown;
        uint16 gb = s.redeemGateBps;
        if (lk == 0 && cd == 0 && gb == 0) return;

        uint256 nowTs = block.timestamp;
        if (lk != 0) {
            uint256 unlockAt = uint256(s.lastDepositAt[owner]) + lk;
            if (nowTs < unlockAt) revert LockupNotElapsed(uint64(unlockAt));
        }
        if (cd != 0) {
            uint256 readyAt = uint256(s.lastRedeemAt[owner]) + cd;
            if (nowTs < readyAt) revert RedeemCooldownActive(uint64(readyAt));
        }
        if (gb != 0) {
            uint256 cap = (nav * gb) / Constants.BPS;
            if (grossAssets > cap) revert RedeemGateExceeded(grossAssets, cap);
        }
        s.lastRedeemAt[owner] = uint64(nowTs);
    }
}
