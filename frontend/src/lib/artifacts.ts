// Auto-discovery of deployed vaults via Vite's `import.meta.glob`.
// At build time this enumerates every JSON file under `deployments/<chain>/`
// and inlines its contents. To register a new vault, just run the deploy
// script — the next `vite build` picks it up automatically.

import type {Address} from "viem";

// Mirrors what `script/Deploy.s.sol` writes per strategy.
export type VaultArtifact = {
    chainId: number;
    vault: Address;
    timelock: Address;
    registry?: Address;
    asset: Address;
    operator: Address;
    feeRecipient: Address;
    name: string;
    symbol: string;
    deployBlock: number;
    leverageCapBps: number;
    perfFeeBps: number;
    mgmtFeeAnnualBps: number;
    whitelistPerps: number[];
    whitelistSpots: number[];
};

// What `script/DeployRegistry.s.sol` writes — used to surface the chain-level
// registry address in the UI but not itself a vault.
export type RegistryArtifact = {
    chainId: number;
    registry: Address;
    deployer: Address;
    deployBlock: number;
};

export type ChainKey = "mainnet" | "testnet" | "local";

export type LoadedArtifacts = {
    chainKey: ChainKey;
    chainId: number;
    registry?: RegistryArtifact;
    vaults: VaultArtifact[];
};

const CHAIN_KEY_FOR_DIR: Record<string, ChainKey> = {
    mainnet: "mainnet",
    testnet: "testnet",
    local: "local",
};

// Eager-glob every JSON in deployments/*/ at build time.
const RAW = import.meta.glob<Record<string, unknown>>(
    "/deployments/*/*.json",
    {eager: true, import: "default"},
);

function isRegistryArtifact(obj: Record<string, unknown>): obj is RegistryArtifact {
    return "registry" in obj && !("vault" in obj);
}

function isVaultArtifact(obj: Record<string, unknown>): obj is VaultArtifact {
    return "vault" in obj && "asset" in obj && "name" in obj;
}

export function loadAll(): LoadedArtifacts[] {
    const byChain = new Map<string, LoadedArtifacts>();
    for (const [path, raw] of Object.entries(RAW)) {
        const m = path.match(/\/deployments\/([^/]+)\/(.+)\.json$/);
        if (!m) continue;
        const dir = m[1];
        const chainKey = CHAIN_KEY_FOR_DIR[dir];
        if (!chainKey) continue;
        const data = raw as Record<string, unknown>;
        const chainId = typeof data.chainId === "number" ? data.chainId : 0;
        const key = chainKey;
        let bucket = byChain.get(key);
        if (!bucket) {
            bucket = {chainKey, chainId, vaults: []};
            byChain.set(key, bucket);
        }
        if (isRegistryArtifact(data)) {
            bucket.registry = data;
            if (!bucket.chainId) bucket.chainId = data.chainId;
        } else if (isVaultArtifact(data)) {
            bucket.vaults.push(data);
            if (!bucket.chainId) bucket.chainId = data.chainId;
        }
    }
    // Sort vaults by deployBlock ascending so the UI is stable
    for (const b of byChain.values()) {
        b.vaults.sort((a, b2) => a.deployBlock - b2.deployBlock);
    }
    // mainnet first, testnet, then local
    return Array.from(byChain.values()).sort((a, b) => {
        const order = (k: ChainKey) => (k === "mainnet" ? 0 : k === "testnet" ? 1 : 2);
        return order(a.chainKey) - order(b.chainKey);
    });
}
