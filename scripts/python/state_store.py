#!/usr/bin/env python3
"""Resumable checkpoint store for the HyperVault live-spike battle-test kit.

WHY THIS EXISTS
---------------
A funded live battle-test runs many independent scenarios (deposit waves,
redemption races, escape-brake triggers, barrier checks) against REAL money on
HyperEVM mainnet. Any single scenario can leave funds parked on Core, in the
withdrawal queue, or mid-bridge — and the operator may have to stop and resume
hours later. Re-running a scenario that already PASSED would waste gas and risk
double-moving funds. This module is the durable memory that lets `battle_test.py`
skip what's already green, remember where each LP's capital ended up, and print a
resume summary.

It is intentionally PURE: stdlib only, no chain access, no sibling imports. That
keeps it trivially testable and free of any RPC/web3 coupling — the chain-touching
modules read/write it but never live in it. The on-disk form is a single JSON file
(default `.battle_state.json` in the repo root) with this shape:

    {
      "scenarios": {"<scenario_id>": {"status": "PASS", "ts": "<utc-iso>"}},
      "lps":       {"<lp_name>":     {"where": "<free-text>", "ts": "<utc-iso>"}}
    }

`status` is one of PASS / FAIL / SKIP / RUNNING. Only PASS counts as "done" (so a
RUNNING/FAIL scenario re-runs on resume). The `lps` map is free-text bookkeeping
("12.4 USDC parked on Core spot", "queued, overdue", "redeemed, EVM idle") so a
human reading the summary knows where money sits without reading the chain.
"""
from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

DEFAULT_STATE_PATH = ".battle_state.json"

# The only statuses a scenario may carry. PASS is the single "done" terminal.
VALID_STATUSES = {"PASS", "FAIL", "SKIP", "RUNNING"}


def _now_iso() -> str:
    """UTC ISO-8601 timestamp (seconds precision) for audit-friendly journaling."""
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def _empty() -> dict:
    """The canonical empty state — both top-level maps always present."""
    return {"scenarios": {}, "lps": {}}


def load(path: str = DEFAULT_STATE_PATH) -> dict:
    """Load the state file, returning a fresh empty state if it's missing/blank.

    Defensive against a partially-written or hand-edited file: a malformed JSON
    body falls back to an empty state (the battle-test should re-run cleanly
    rather than crash on a corrupt checkpoint). Always normalizes so the
    "scenarios" and "lps" keys exist.
    """
    p = Path(path)
    if not p.exists():
        return _empty()
    text = p.read_text().strip()
    if not text:
        return _empty()
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return _empty()
    if not isinstance(data, dict):
        return _empty()
    data.setdefault("scenarios", {})
    data.setdefault("lps", {})
    return data


def save(path: str, state: dict) -> None:
    """Persist state atomically-ish (write to a temp sibling, then replace).

    Avoids a half-written checkpoint if the process dies mid-write — a corrupt
    `.battle_state.json` would otherwise force a full re-run.
    """
    p = Path(path)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
    tmp.replace(p)


def mark_scenario(state: dict, scenario_id: str, status: str) -> dict:
    """Record a scenario's status (PASS/FAIL/SKIP/RUNNING) with a UTC timestamp.

    Mutates and returns `state` (caller persists with `save`). Rejects unknown
    statuses early — a typo'd status would silently break `is_done` resume logic.
    """
    if status not in VALID_STATUSES:
        raise ValueError(f"invalid status {status!r}; expected one of {sorted(VALID_STATUSES)}")
    state.setdefault("scenarios", {})[scenario_id] = {"status": status, "ts": _now_iso()}
    return state


def scenario_status(state: dict, scenario_id: str) -> Optional[str]:
    """The recorded status for a scenario, or None if never seen."""
    entry = state.get("scenarios", {}).get(scenario_id)
    return entry.get("status") if entry else None


def is_done(state: dict, scenario_id: str) -> bool:
    """True only if the scenario is recorded PASS — the resume-skip predicate.

    FAIL / SKIP / RUNNING all return False so they re-run on the next pass.
    """
    return scenario_status(state, scenario_id) == "PASS"


def set_lp(state: dict, lp: str, where: str) -> dict:
    """Record free-text bookkeeping of where an LP's funds currently sit.

    `where` is human prose ("queued, overdue 2h", "redeemed -> EVM idle"); this
    is operator memory, not machine-parsed. Mutates and returns `state`.
    """
    state.setdefault("lps", {})[lp] = {"where": where, "ts": _now_iso()}
    return state


def get_lp(state: dict, lp: str) -> Optional[str]:
    """The last recorded 'where' note for an LP, or None."""
    entry = state.get("lps", {}).get(lp)
    return entry.get("where") if entry else None


def summary(state: dict) -> str:
    """A compact, human-readable resume report of scenarios + LP fund locations."""
    scenarios = state.get("scenarios", {})
    lps = state.get("lps", {})

    lines: list[str] = []
    lines.append("=== battle-test state ===")

    if scenarios:
        # Count by status for a quick health read at the top.
        counts: dict[str, int] = {}
        for entry in scenarios.values():
            st = entry.get("status", "?")
            counts[st] = counts.get(st, 0) + 1
        tally = "  ".join(f"{k}={counts[k]}" for k in sorted(counts))
        lines.append(f"scenarios ({len(scenarios)}): {tally}")
        for sid in sorted(scenarios):
            entry = scenarios[sid]
            lines.append(f"  [{entry.get('status', '?'):7}] {sid}  ({entry.get('ts', '-')})")
    else:
        lines.append("scenarios: none recorded")

    if lps:
        lines.append(f"LP fund locations ({len(lps)}):")
        for lp in sorted(lps):
            entry = lps[lp]
            lines.append(f"  {lp}: {entry.get('where', '-')}  ({entry.get('ts', '-')})")
    else:
        lines.append("LP fund locations: none recorded")

    return "\n".join(lines)


def main(argv: Optional[list[str]] = None) -> int:
    """Print the summary of a given --state file (read-only inspection)."""
    parser = argparse.ArgumentParser(description="Inspect a battle-test state checkpoint.")
    parser.add_argument("--state", default=DEFAULT_STATE_PATH,
                        help=f"path to the state JSON (default {DEFAULT_STATE_PATH})")
    args = parser.parse_args(argv)
    state = load(args.state)
    print(summary(state))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
