import {createPublicClient, http, formatUnits, type PublicClient, type Address} from "viem";
import {chainFor} from "./chains";
import {vaultAbi} from "./abi";
import type {ChainKey} from "./artifacts";

const _clients: Partial<Record<ChainKey, PublicClient>> = {};
function clientFor(key: ChainKey): PublicClient {
    return _clients[key] ?? (_clients[key] = createPublicClient({chain: chainFor(key), transport: http()}));
}

export type LiveState = {
    totalAssets: bigint;
    totalSupply: bigint;
    pricePerShare: bigint;
    idleUsdc: bigint;
    coreSpotUsdc: bigint;
    perpWithdrawable: bigint;
    paused: boolean;
    emergencyShutdownActive: boolean;
    rpcError?: string;
};

export async function fetchLive(chainKey: ChainKey, vault: Address): Promise<LiveState> {
    const client = clientFor(chainKey);
    const calls = [
        "totalAssets",
        "totalSupply",
        "pricePerShare",
        "idleUsdc",
        "coreSpotUsdc",
        "perpWithdrawable",
        "paused",
        "emergencyShutdownActive",
    ] as const;
    try {
        const results = await client.multicall({
            contracts: calls.map(fn => ({address: vault, abi: vaultAbi, functionName: fn})),
            allowFailure: true,
        });
        const get = <T>(i: number, fallback: T): T =>
            results[i].status === "success" ? (results[i].result as T) : fallback;
        return {
            totalAssets: get<bigint>(0, 0n),
            totalSupply: get<bigint>(1, 0n),
            pricePerShare: get<bigint>(2, 0n),
            idleUsdc: get<bigint>(3, 0n),
            coreSpotUsdc: get<bigint>(4, 0n),
            perpWithdrawable: get<bigint>(5, 0n),
            paused: get<boolean>(6, false),
            emergencyShutdownActive: get<boolean>(7, false),
        };
    } catch (e) {
        return {
            totalAssets: 0n, totalSupply: 0n, pricePerShare: 0n,
            idleUsdc: 0n, coreSpotUsdc: 0n, perpWithdrawable: 0n,
            paused: false, emergencyShutdownActive: false,
            rpcError: e instanceof Error ? e.message : String(e),
        };
    }
}

// Formatters
export function fmtUsdc(v: bigint): string {
    return Number(formatUnits(v, 6)).toLocaleString(undefined, {maximumFractionDigits: 2});
}
export function fmtUsdc6(v: bigint): string {
    return Number(formatUnits(v, 6)).toLocaleString(undefined, {maximumFractionDigits: 6});
}
// pricePerShare is mulDiv(totalAssets, WAD, supply); for our 6dp-asset + offset=6
// vault, supply is 12dp so 1 share token represents 1e-6 USDC. We display the
// USDC-value of 1 share token by dividing by 1e12.
export function fmtPps(v: bigint): string {
    return Number(formatUnits(v, 12)).toLocaleString(undefined, {maximumFractionDigits: 8});
}
export function fmtBps(v: number): string {
    return `${(v / 100).toFixed(2)}%`;
}
export function shortAddr(a: string): string {
    return `${a.slice(0, 6)}…${a.slice(-4)}`;
}
