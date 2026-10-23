#!/usr/bin/env python3
"""Aggregate verification logs into a compact coverage/report summary."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
from collections import Counter

LINE_KV_RE = re.compile(r"([A-Za-z0-9_]+)=(-?[0-9]+)")


def parse_kv_line(line: str) -> dict[str, int]:
    return {k: int(v) for k, v in LINE_KV_RE.findall(line)}


def parse_log(path: pathlib.Path) -> dict[str, Counter]:
    groups = {
        "stats": Counter(),
        "lsu": Counter(),
        "atom": Counter(),
        "ooo": Counter(),
        "rec": Counter(),
        "rand_cov": Counter(),
    }

    text = path.read_text(encoding="ascii", errors="ignore")
    for raw in text.splitlines():
        line = raw.strip()
        if "TB STATS" in line:
            groups["stats"].update(parse_kv_line(line.split("TB STATS", 1)[1]))
        elif "TB LSU" in line:
            groups["lsu"].update(parse_kv_line(line.split("TB LSU", 1)[1]))
        elif "TB ATOM" in line:
            groups["atom"].update(parse_kv_line(line.split("TB ATOM", 1)[1]))
        elif "TB REC" in line:
            groups["rec"].update(parse_kv_line(line.split("TB REC", 1)[1]))
        elif "TB OOO" in line:
            groups["ooo"].update(parse_kv_line(line.split("TB OOO", 1)[1]))
        elif line.startswith("RAND COV "):
            groups["rand_cov"].update(parse_kv_line(line[len("RAND COV ") :]))

    return groups


def merge_groups(items: list[dict[str, Counter]]) -> dict[str, Counter]:
    merged = {
        "stats": Counter(),
        "lsu": Counter(),
        "atom": Counter(),
        "ooo": Counter(),
        "rec": Counter(),
        "rand_cov": Counter(),
    }
    for item in items:
        for key in merged:
            merged[key].update(item[key])
    return merged


def nonzero_bins(values: Counter, keys: list[str]) -> dict[str, bool]:
    return {key: values.get(key, 0) > 0 for key in keys}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--logs", type=pathlib.Path, required=True, help="Directory containing regression/random logs")
    parser.add_argument(
        "--out-json",
        type=pathlib.Path,
        default=pathlib.Path("verification_summary.json"),
        help="Path to write machine-readable summary",
    )
    args = parser.parse_args()

    if not args.logs.exists():
        raise FileNotFoundError(args.logs)

    log_files = sorted(args.logs.glob("*.log"))
    if not log_files:
        raise RuntimeError(f"No .log files found in {args.logs}")

    parsed = [parse_log(path) for path in log_files]
    merged = merge_groups(parsed)

    bins = {
        "ooo_backend": nonzero_bins(
            merged["ooo"],
            ["dual_dispatch", "dual_commit", "dispatch_stall", "rob_full", "lsu_busy", "cdb_conflict"],
        ),
        "branch_recovery": nonzero_bins(merged["stats"], ["mispredicts", "flushes"]),
        # Store-queue, FP-pipeline, and divider squashes are exercised by
        # test_files/lockstep/branch_recovery.s and the random lockstep runs.
        "early_recovery": nonzero_bins(merged["rec"], ["recoveries", "load_squash", "memq_squash", "rs_squash", "nested"]),
        # l2_hit only counts when the L2 is built in (-DOTTER_L2; TB STATS l2=1).
        "cache_behavior": nonzero_bins(merged["stats"], ["ic_fetch", "ic_fill", "ic_prefetch", "dc_hit", "dc_miss"] +
                                       (["l2_hit"] if merged["stats"].get("l2", 0) > 0 else [])),
        "csr_trap": nonzero_bins(merged["ooo"], ["traps", "mrets"]),
        "memory_ordering": nonzero_bins(
            merged["lsu"],
            # No sb_full_stall bin: the store buffer drains as fast as commit
            # retires stores, so it no longer fills in practice (the full
            # check stays in the RTL as a guard).
            ["sb_enq", "sb_fwd", "sq_fwd", "sb_drain", "sb_conflict_stall", "fence_wait"],
        ),
        "atomic_paths": nonzero_bins(
            merged["atom"],
            ["commits", "writes", "sc_success", "sc_fail", "res_set", "res_clear"],
        ),
        "random_instruction_classes": nonzero_bins(
            merged["rand_cov"],
            [
                "base_load_imm",
                "base_alu",
                "base_alui",
                "base_muldiv",
                "base_storeload",
                "base_branch",
                "frontend_branch",
                "frontend_jump",
                "frontend_call",
                "frontend_patch",
                "atomic_amo",
                "atomic_lrsc_success",
                "atomic_lrsc_fail",
                "atomic_fence",
            ],
        ),
    }

    summary = {
        "log_count": len(log_files),
        "totals": {name: dict(counter) for name, counter in merged.items()},
        "bins": bins,
    }

    args.out_json.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="ascii")

    hit = sum(v for group in bins.values() for v in group.values())
    total = sum(len(group) for group in bins.values())
    missing = [f"{group}.{name}" for group, values in bins.items() for name, ok in values.items() if not ok]
    print(f"Coverage: {hit}/{total} bins hit across {len(log_files)} logs" + (f"; missing: {', '.join(missing)}" if missing else ""))
    print(f"Details: {args.out_json}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
