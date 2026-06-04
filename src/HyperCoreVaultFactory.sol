// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {HyperCoreVault} from "./HyperCoreVault.sol";
import {HyperCoreVaultRegistry} from "./HyperCoreVaultRegistry.sol";
import {PrecompileLib} from "./libraries/PrecompileLib.sol";

/// @notice CREATE2 factory for HyperCoreVault. One factory per chain.
contract HyperCoreVaultFactory is Ownable {
    string public constant VERSION = "v1.0.0";

    /// @notice Minimum per-vault timelock delay the factory will deploy with
    ///         (audit H3). The "24h timelock protects LPs" model is void with a
    ///         0-delay timelock; the factory refuses to mint that footgun.
    uint256 public constant MIN_TIMELOCK_DELAY = 24 hours;

    HyperCoreVaultRegistry public immutable registry;

    /// @notice If true, factory validates the configured Core-USDC linkage against
    ///         the live `tokenInfo` precompile at deploy. Disabled by default for
    ///         tests / chains where the precompile isn't populated; flip on once
    ///         mainnet tokenInfo is confirmed wired up.
    /// @dev    Audit C1/M5: validates `tokenInfo(cfg.coreUsdcIndex).weiDecimals`
    ///         equals `cfg.coreUsdcDecimals` (a mismatch mis-scales NAV by 10^|Δ|).
    ///         A Core `evmContract` differing from the asset is NOT fatal — Path B
    ///         keeps the unlinked Circle USDC as the share asset; the vault
    ///         constructor surfaces the mismatch via `CoreLinkUnverified`.
    bool public strictAssetValidation;

    /// @notice Configured Core-USDC decimals disagree with the live `tokenInfo`
    ///         precompile (audit C1/M5).
    error CoreUsdcDecimalsMismatch(uint8 configured, uint8 fromPrecompile);
    /// @notice `timelockMinDelaySec` is below {MIN_TIMELOCK_DELAY} (audit H3).
    error TimelockDelayBelowFloor(uint256 provided, uint256 floor);
    /// @notice operator / emergencyAdmin / feeRecipient are not three distinct
    ///         addresses — the timelock/role-separation model is void (audit H3).
    error RolesNotDistinct();
    error ZeroAddress();

    event StrictAssetValidationUpdated(bool enabled);
    event VaultCreated(
        address indexed vault,
        address indexed timelock,
        address indexed operator,
        bytes32 salt,
        string name,
        string symbol
    );

    constructor(HyperCoreVaultRegistry _registry, address initialOwner, bool _strictValidation)
        Ownable(initialOwner)
    {
        if (address(_registry) == address(0) || initialOwner == address(0)) revert ZeroAddress();
        registry = _registry;
        strictAssetValidation = _strictValidation;
    }

    function setStrictAssetValidation(bool enabled) external onlyOwner {
        strictAssetValidation = enabled;
        emit StrictAssetValidationUpdated(enabled);
    }

    /// @notice Deploy a per-vault `TimelockController` and a `HyperCoreVault`.
    ///         The timelock becomes `DEFAULT_ADMIN_ROLE` on the vault; the
    ///         deployer is granted proposer/executor on the timelock and is
    ///         expected to hand them off to multisig/governance post-deploy.
    /// @param  cfg     Vault config (asset, name, operator, fees, caps)
    /// @param  timelockMinDelaySec  Timelock delay for guardrail changes (recommend 24h+)
    /// @return vault   Deployed vault address (deterministic via CREATE2)
    /// @return timelock Deployed timelock address
    function deployVault(HyperCoreVault.Config memory cfg, uint256 timelockMinDelaySec)
        external
        returns (address vault, address timelock)
    {
        if (address(cfg.asset) == address(0)) revert ZeroAddress();

        // Audit H3: enforce a real timelock delay and distinct operator / emergency
        // / feeRecipient keys. A 0-delay timelock or a single key holding all three
        // roles voids the LP-protection model; the factory refuses to deploy it.
        if (timelockMinDelaySec < MIN_TIMELOCK_DELAY) {
            revert TimelockDelayBelowFloor(timelockMinDelaySec, MIN_TIMELOCK_DELAY);
        }
        if (
            cfg.operator == cfg.emergencyAdmin || cfg.operator == cfg.feeRecipient
                || cfg.emergencyAdmin == cfg.feeRecipient
        ) {
            revert RolesNotDistinct();
        }

        if (strictAssetValidation) {
            PrecompileLib.TokenInfo memory ti = PrecompileLib.tokenInfo(uint32(cfg.coreUsdcIndex));
            bool resolved = ti.weiDecimals != 0 || ti.evmContract != address(0) || bytes(ti.name).length != 0;
            // Audit C1/M5: enforce the decimals invariant (NAV scale); the link
            // mismatch is non-fatal under Path B and is surfaced by the vault's
            // CoreLinkUnverified event rather than reverting here.
            if (resolved && ti.weiDecimals != cfg.coreUsdcDecimals) {
                revert CoreUsdcDecimalsMismatch(cfg.coreUsdcDecimals, ti.weiDecimals);
            }
        }

        // 1. Deploy timelock — proposer/executor = msg.sender, admin = msg.sender (rotate after)
        address[] memory proposers = new address[](1);
        proposers[0] = msg.sender;
        address[] memory executors = new address[](1);
        executors[0] = msg.sender;
        TimelockController tl = new TimelockController(timelockMinDelaySec, proposers, executors, msg.sender);
        timelock = address(tl);
        cfg.admin = timelock;

        // 2. CREATE2 salt = keccak256(name, symbol, msg.sender)
        bytes32 salt = keccak256(abi.encode(cfg.name, cfg.symbol, msg.sender));
        bytes memory bytecode = abi.encodePacked(
            type(HyperCoreVault).creationCode,
            abi.encode(cfg)
        );

        // Inline CREATE2 to capture the deployed address.
        assembly {
            vault := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        if (vault == address(0)) revert();

        // 3. Register
        registry.register(HyperCoreVaultRegistry.VaultMetadata({
            vault: vault,
            asset: address(cfg.asset),
            operator: cfg.operator,
            timelock: timelock,
            name: cfg.name,
            symbol: cfg.symbol,
            version: VERSION,
            deployBlock: uint64(block.number)
        }));

        emit VaultCreated(vault, timelock, cfg.operator, salt, cfg.name, cfg.symbol);
    }

    /// @notice CREATE2 salt for a deploy from `deployer`. Off-chain code can
    ///         combine this with the runtime init-code hash to predict the
    ///         vault address. Note: actual init code depends on `cfg.admin`,
    ///         which the factory mutates to the per-vault timelock before
    ///         deploying — so off-chain prediction requires knowing the
    ///         timelock-to-be (CREATE-derived from the factory's nonce).
    function vaultSalt(string memory name, string memory symbol, address deployer)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(name, symbol, deployer));
    }
}
