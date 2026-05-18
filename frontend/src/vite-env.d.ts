/// <reference types="vite/client" />

interface ImportMetaEnv {
    readonly VITE_REGISTRY_MAINNET?: string;
    readonly VITE_REGISTRY_TESTNET?: string;
}

interface ImportMeta {
    readonly env: ImportMetaEnv;
}
