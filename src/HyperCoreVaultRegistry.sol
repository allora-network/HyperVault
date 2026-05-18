// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice On-chain directory of deployed HyperCore vaults. The frontend reads
///         from this to enumerate vaults without an off-chain indexer; the
///         factory is the only authorized writer.
contract HyperCoreVaultRegistry is Ownable {
    struct VaultMetadata {
        address vault;
        address asset;
        address operator;
        address timelock;
        string name;
        string symbol;
        string version;
        uint64 deployBlock;
    }

    error UnauthorizedWriter(address caller);
    error AlreadyRegistered(address vault);
    error VaultIndexOOB(uint256 index);

    event FactoryUpdated(address indexed oldFactory, address indexed newFactory);
    event VaultDeployed(
        address indexed vault,
        address indexed asset,
        address indexed operator,
        string name,
        string symbol,
        string version,
        uint64 deployBlock
    );

    address public factory;
    VaultMetadata[] private _vaults;
    mapping(address => uint256) private _indexPlusOne; // 0 = not registered, otherwise index+1

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Set the factory authorized to register new vaults.
    function setFactory(address newFactory) external onlyOwner {
        emit FactoryUpdated(factory, newFactory);
        factory = newFactory;
    }

    /// @notice Called once per vault deploy. Authorized writers are:
    ///         (a) the configured `factory` contract (production path)
    ///         (b) the registry `owner()` (deploy-script path used on testnet
    ///             where the factory is bypassed due to EIP-170 contract size)
    function register(VaultMetadata calldata m) external {
        if (msg.sender != factory && msg.sender != owner()) revert UnauthorizedWriter(msg.sender);
        if (_indexPlusOne[m.vault] != 0) revert AlreadyRegistered(m.vault);
        _vaults.push(m);
        _indexPlusOne[m.vault] = _vaults.length;
        emit VaultDeployed(m.vault, m.asset, m.operator, m.name, m.symbol, m.version, m.deployBlock);
    }

    function count() external view returns (uint256) {
        return _vaults.length;
    }

    function getVault(uint256 index) external view returns (VaultMetadata memory) {
        if (index >= _vaults.length) revert VaultIndexOOB(index);
        return _vaults[index];
    }

    function getAllVaults() external view returns (VaultMetadata[] memory) {
        return _vaults;
    }

    function isRegistered(address vault) external view returns (bool) {
        return _indexPlusOne[vault] != 0;
    }
}
