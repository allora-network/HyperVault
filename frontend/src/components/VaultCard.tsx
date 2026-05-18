import {hyperevmMainnet, hyperevmTestnet, hyperevmLocal} from "../lib/chains";
import {fmtBps, fmtPps, fmtUsdc, fmtUsdc6, shortAddr} from "../lib/fetcher";
import type {ChainKey, VaultArtifact} from "../lib/artifacts";
import type {LiveState} from "../lib/fetcher";

const CHAIN_EXPLORER: Record<ChainKey, string | undefined> = {
    mainnet: hyperevmMainnet.blockExplorers?.default.url,
    testnet: hyperevmTestnet.blockExplorers?.default.url,
    local: hyperevmLocal.blockExplorers?.default.url,
};

export function VaultCard({chainKey, artifact, live}: {
    chainKey: ChainKey;
    artifact: VaultArtifact;
    live: LiveState | "loading" | "error";
}) {
    const explorer = CHAIN_EXPLORER[chainKey] ?? "";
    const navTotal = live === "loading" || live === "error" ? 0n : live.totalAssets;

    return (
        <article className="vault-card">
            <header>
                <h2>
                    {artifact.name} <span className="symbol">({artifact.symbol})</span>
                </h2>
                <p className="meta">
                    <span className="chain-pill">{chainKey}</span>
                    {" · "}
                    {explorer ? (
                        <a href={`${explorer}/address/${artifact.vault}`} target="_blank" rel="noreferrer">
                            {shortAddr(artifact.vault)}
                        </a>
                    ) : (
                        <span>{shortAddr(artifact.vault)}</span>
                    )}
                </p>
            </header>

            <section className="nav">
                <div className="nav-total">
                    <span className="label">NAV</span>
                    <span className="value">
                        {live === "loading" ? "…" : live === "error" ? "—" : `$${fmtUsdc(navTotal)}`}
                    </span>
                </div>
                {live !== "loading" && live !== "error" && (
                    <div className="nav-breakdown">
                        <NavRow label="Idle (EVM)"  value={live.idleUsdc}        total={navTotal} />
                        <NavRow label="Core spot"   value={live.coreSpotUsdc}    total={navTotal} />
                        <NavRow label="Perp equity" value={live.perpWithdrawable} total={navTotal} />
                    </div>
                )}
            </section>

            <section className="stats">
                <Stat label="Price / share" value={live === "loading" || live === "error" ? "…" : fmtPps(live.pricePerShare)} unit="USDC" />
                <Stat
                    label="Supply"
                    value={live === "loading" || live === "error" ? "…" : fmtUsdc6(live.totalSupply / 1_000_000n)}
                    unit={artifact.symbol}
                />
                <Stat label="Leverage cap" value={fmtBps(artifact.leverageCapBps)} unit="" />
                <Stat label="Perf / Mgmt" value={`${fmtBps(artifact.perfFeeBps)} / ${fmtBps(artifact.mgmtFeeAnnualBps)}`} unit="" />
            </section>

            <section className="whitelist">
                <span className="label">Whitelisted:</span>{" "}
                {artifact.whitelistPerps.length > 0 && (
                    <span>perps [{artifact.whitelistPerps.join(", ")}]</span>
                )}
                {artifact.whitelistSpots.length > 0 && (
                    <span> spots [{artifact.whitelistSpots.join(", ")}]</span>
                )}
                {artifact.whitelistPerps.length === 0 && artifact.whitelistSpots.length === 0 && <em>none</em>}
            </section>

            {live !== "loading" && live !== "error" && (live.paused || live.emergencyShutdownActive) && (
                <section className="status-banner">
                    {live.paused && <span className="warn">PAUSED</span>}
                    {live.emergencyShutdownActive && <span className="warn">SHUTDOWN</span>}
                </section>
            )}

            <footer className="vault-footer">
                <span>
                    Asset:{" "}
                    {explorer ? (
                        <a href={`${explorer}/address/${artifact.asset}`} target="_blank" rel="noreferrer">
                            {shortAddr(artifact.asset)}
                        </a>
                    ) : (
                        shortAddr(artifact.asset)
                    )}
                </span>
                <span>
                    Operator:{" "}
                    {explorer ? (
                        <a href={`${explorer}/address/${artifact.operator}`} target="_blank" rel="noreferrer">
                            {shortAddr(artifact.operator)}
                        </a>
                    ) : (
                        shortAddr(artifact.operator)
                    )}
                </span>
                <span>Block {artifact.deployBlock.toLocaleString()}</span>
            </footer>

            {live !== "loading" && live !== "error" && live.rpcError && (
                <p className="rpc-error">RPC error: {live.rpcError}</p>
            )}
        </article>
    );
}

function NavRow({label, value, total}: {label: string; value: bigint; total: bigint}) {
    const pct = total === 0n ? 0 : Number((value * 10000n) / total) / 100;
    return (
        <div className="nav-row">
            <span className="row-label">{label}</span>
            <span className="row-value">${fmtUsdc(value)}</span>
            <span className="row-pct">{pct.toFixed(1)}%</span>
        </div>
    );
}

function Stat({label, value, unit}: {label: string; value: string; unit: string}) {
    return (
        <div className="stat">
            <span className="stat-label">{label}</span>
            <span className="stat-value">
                {value} <span className="stat-unit">{unit}</span>
            </span>
        </div>
    );
}
