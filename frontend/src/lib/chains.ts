import {defineChain, type Chain} from "viem";
import type {ChainKey} from "./artifacts";

export const hyperevmMainnet = defineChain({
    id: 999,
    name: "Hyperliquid",
    nativeCurrency: {name: "HYPE", symbol: "HYPE", decimals: 18},
    rpcUrls: {default: {http: ["https://rpc.hyperliquid.xyz/evm"]}},
    blockExplorers: {default: {name: "HyperEVMscan", url: "https://hyperevmscan.io"}},
});

export const hyperevmTestnet = defineChain({
    id: 998,
    name: "Hyperliquid Testnet",
    nativeCurrency: {name: "HYPE", symbol: "HYPE", decimals: 18},
    rpcUrls: {default: {http: ["https://rpc.hyperliquid-testnet.xyz/evm"]}},
    blockExplorers: {default: {name: "HyperEVMscan Testnet", url: "https://testnet.hyperevmscan.io"}},
});

export const hyperevmLocal = defineChain({
    id: 31337,
    name: "Local (anvil fork)",
    nativeCurrency: {name: "HYPE", symbol: "HYPE", decimals: 18},
    rpcUrls: {default: {http: ["http://localhost:8545"]}},
});

export function chainFor(key: ChainKey): Chain {
    switch (key) {
        case "mainnet":
            return hyperevmMainnet;
        case "testnet":
            return hyperevmTestnet;
        case "local":
            return hyperevmLocal;
    }
}
