// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {HyperCoreVault} from "./HyperCoreVault.sol";
import {HyperCoreVaultRegistry} from "./HyperCoreVaultRegistry.sol";
import {PrecompileLib} from "./libraries/PrecompileLib.sol";
import {Constants} from "./libraries/Constants.sol";

/// @notice CREATE2 factory for HyperCoreVault. One factory per chain.
contract HyperCoreVaultFactory is Ownable {
    string public constant VERSION = "v1.0.0";

    HyperCoreVaultRegistry public immutable registry;

    /// @notice If true, factory validates `tokenInfo(USDC).evmContract` against the
    ///         supplied asset address. Disabled by default for tests / chains
    ///         where the precompile isn't populated; flip on once mainnet
    ///         tokenInfo is confirmed wired up.
    bool public strictAssetValidation;

    error AssetMismatch(address configured, address fromPrecompile);
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

        if (strictAssetValidation) {
            address fromPrecompile = PrecompileLib.tokenInfo(uint32(Constants.USDC_CORE_INDEX)).evmContract;
            if (fromPrecompile != address(0) && fromPrecompile != address(cfg.asset)) {
                revert AssetMismatch(address(cfg.asset), fromPrecompile);
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
