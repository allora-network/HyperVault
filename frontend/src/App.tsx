import {useEffect, useMemo, useState} from "react";
import {VaultCard} from "./components/VaultCard";
import {loadAll, type LoadedArtifacts, type ChainKey} from "./lib/artifacts";
import {fetchLive, type LiveState, shortAddr} from "./lib/fetcher";

type LiveMap = Record<string, LiveState | "loading" | "error">;

export function App() {
    const buckets = useMemo<LoadedArtifacts[]>(() => loadAll(), []);
    const [activeChain, setActiveChain] = useState<ChainKey | "all">("all");
    const [live, setLive] = useState<LiveMap>({});

    // Initialise loading state, then kick off fetches per vault
    useEffect(() => {
        const init: LiveMap = {};
        for (const b of buckets) for (const v of b.vaults) init[v.vault.toLowerCase()] = "loading";
        setLive(init);

        let cancelled = false;
        (async () => {
            for (const b of buckets) {
                await Promise.all(
                    b.vaults.map(async v => {
                        try {
                            const ls = await fetchLive(b.chainKey, v.vault);
                            if (!cancelled) {
                                setLive(prev => ({...prev, [v.vault.toLowerCase()]: ls}));
                            }
                        } catch {
                            if (!cancelled) {
                                setLive(prev => ({...prev, [v.vault.toLowerCase()]: "error"}));
                            }
                        }
                    }),
                );
            }
        })();
        return () => {
            cancelled = true;
        };
    }, [buckets]);

    const totalVaults = buckets.reduce((n, b) => n + b.vaults.length, 0);
    const shown = buckets.filter(b => activeChain === "all" || b.chainKey === activeChain);

    return (
        <div className="app">
            <header className="app-header">
                <div>
                    <h1>HyperCore Vaults</h1>
                    <p className="subtitle">
                        Auto-discovered from <code>deployments/</code> · {totalVaults} vault{totalVaults === 1 ? "" : "s"}
                    </p>
                </div>
                <div className="chain-switcher">
                    {(["all", "mainnet", "testnet", "local"] as const).map(k => (
                        <button
                            key={k}
                            className={activeChain === k ? "active" : ""}
                            onClick={() => setActiveChain(k)}
                        >
                            {k}
                        </button>
                    ))}
                </div>
            </header>

            <main>
                {shown.length === 0 || shown.every(b => b.vaults.length === 0) ? (
                    <p className="status">
                        No vaults found for <strong>{activeChain}</strong>. Run a deploy script (writes
                        artifacts to <code>deployments/&lt;chain&gt;/</code>) and rerun{" "}
                        <code>npm run dev</code>.
                    </p>
                ) : (
                    shown.map(bucket =>
                        bucket.vaults.length === 0 ? null : (
                            <section key={bucket.chainKey} className="chain-section">
                                <header className="chain-header">
                                    <h2>{bucket.chainKey}</h2>
                                    <span className="chain-meta">
                                        chain {bucket.chainId}
                                        {bucket.registry && (
                                            <>
                                                {" · "}registry {shortAddr(bucket.registry.registry)}
                                            </>
                                        )}
                                    </span>
                                </header>
                                <div className="grid">
                                    {bucket.vaults.map(v => (
                                        <VaultCard
                                            key={v.vault}
                                            chainKey={bucket.chainKey}
                                            artifact={v}
                                            live={live[v.vault.toLowerCase()] ?? "loading"}
                                        />
                                    ))}
                                </div>
                            </section>
                        ),
                    )
                )}
            </main>

            <footer className="app-footer">
                <span>Auto-discovery via <code>import.meta.glob('/deployments/*/*.json')</code></span>
                <span>{buckets.length} chain{buckets.length === 1 ? "" : "s"}</span>
            </footer>
        </div>
    );
}
