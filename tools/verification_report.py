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
        "cov": Counter(),
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
        elif "TB COV" in line:
            groups["cov"].update(parse_kv_line(line.split("TB COV", 1)[1]))
        elif line.startswith("RAND COV "):
            groups["rand_cov"].update(parse_kv_line(line[len("RAND COV ") :]))

    return groups


def merge_groups(items: list[dict[str, Counter]]) -> dict[str, Counter]:
    merged = {
        "stats": Counter(),
        "lsu": Counter(),
        "atom": Counter(),
        "cov": Counter(),
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
        "hazard_paths": nonzero_bins(
            merged["cov"],
            ["hazard_load_use", "pair_issue", "atomic_wait", "lsu_busy"],
        ),
        "branch_recovery": nonzero_bins(merged["cov"], ["branch_mispredict", "fence_complete"]),
        "cache_behavior": nonzero_bins(merged["stats"], ["ic_hit", "ic_miss", "dc_hit", "dc_miss"]),
        "csr_trap": nonzero_bins(merged["cov"], ["trap_commit", "mret_commit"]),
        "memory_ordering": nonzero_bins(
            merged["lsu"],
            ["sb_enq", "sb_fwd", "sb_drain", "fence_wait"],
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

    print(f"VERIF logs={len(log_files)}")
    print(f"VERIF totals stats={dict(merged['stats'])}")
    print(f"VERIF totals lsu={dict(merged['lsu'])}")
    print(f"VERIF totals atom={dict(merged['atom'])}")
    print(f"VERIF totals cov={dict(merged['cov'])}")
    print(f"VERIF totals rand_cov={dict(merged['rand_cov'])}")
    print(f"VERIF bins={json.dumps(bins, sort_keys=True)}")
    print(f"VERIF summary_json={args.out_json}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
