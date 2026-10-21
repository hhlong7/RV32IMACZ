#!/usr/bin/env python3
"""Record a performance snapshot of the core on a fixed set of workloads.

Every workload image is built once from this checkout, so different cores
(for example the in-order core on `main` checked out in a worktree) run the
exact same programs. The core under test is whichever tree --rtl-root points
at: its tools/build_sim.sh compiles its own rtl.f and tb_core.sv.

Each run's end-of-simulation report (the human-readable lines both the
in-order and out-of-order testbenches print) is parsed, and the snapshot is
stored under --label in docs/perf_history.json; docs/PERFORMANCE.md is then
regenerated with one column per snapshot.

  python3 tools/perf_snapshot.py --label "OoO M1"
  python3 tools/perf_snapshot.py --label "In-order" --rtl-root ../main-wt
  python3 tools/perf_snapshot.py --render          # only rewrite the table
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
HISTORY = ROOT / "docs" / "perf_history.json"
TABLE = ROOT / "docs" / "PERFORMANCE.md"
FREERTOS = ROOT / "software" / "freertos_coremark"

sys.path.insert(0, str(ROOT / "tools"))
import lockstep  # noqa: E402  (reused to assemble the lockstep programs)

# name -> (kind, source, pass code). Lockstep programs are compute kernels with
# no I/O; they pass through the harness's PASS code.
WORKLOADS = {
    "freertos_coremark": ("freertos", None, 201),
    "system_workload": ("mem", "test_files/generated/system_workload_full.mem", 13),
    "system_workload_benchmark": ("mem", "test_files/generated/system_workload_benchmark_full.mem", 119),
    "rv32im_alu": ("lockstep", "test_files/lockstep/rv32im_alu.s", lockstep.PASS_CODE),
    "rv32i_control": ("lockstep", "test_files/lockstep/rv32i_control.s", lockstep.PASS_CODE),
    "cache_stress": ("lockstep", "test_files/lockstep/cache_stress.s", lockstep.PASS_CODE),
    "fp_arith": ("lockstep", "test_files/lockstep/fp_arith.s", lockstep.PASS_CODE),
}

# (metric key, label shown in the table, regex over the report, group -> value)
REPORT_FIELDS = [
    ("completion_cycles", "cycles to pass", r"Result\s+PASS \(pass code \d+ at cycle (\d+)\)", 1),
    ("cycles", "core cycles (mcycle)", r"Core\s+(\d+) cycles", 1),
    ("retired", "instructions retired", r"Core\s+\d+ cycles, (\d+) instructions retired", 1),
    ("ipc", "IPC", r"IPC ([0-9.]+)", 1),
    ("control", "control-flow instructions", r"Branches\s+(\d+) control-flow", 1),
    ("mispredicts", "mispredicted", r"Branches\s+\d+ control-flow instructions, (\d+) mispredicted", 1),
    ("predict_pct", "branch prediction accuracy %", r"\(([0-9.]+)% predicted correctly\)", 1),
    ("ic_fills", "I-cache line fills", r"I-cache\s+\d+ fetches, (\d+) line fills", 1),
    ("dc_loads", "loads", r"D-cache\s+(\d+) loads", 1),
    ("dc_misses", "D-cache misses", r"D-cache\s+\d+ loads, (\d+) misses", 1),
    ("l2_hits", "misses served by L2", r"served by L2: (\d+)", 1),
    ("sb_stores", "stores", r"Store buffer\s+(\d+) stores", 1),
    ("sb_forwards", "store-buffer forwards to loads", r"Store buffer\s+\d+ stores, (\d+) forwarded", 1),
    ("sb_overlap_stalls", "store-ordering stall cycles", r"forwarded to loads, (\d+) overlap stalls", 1),
    ("sb_full_stalls", "store-buffer full stall cycles", r"overlap stalls, (\d+) full stalls", 1),
    ("mp_br_nt", "mispredict: branch predicted not-taken", r"branch predicted not-taken (\d+)", 1),
    ("mp_br_t", "mispredict: branch predicted taken", r"predicted taken (\d+);", 1),
    ("mp_ret", "mispredict: return", r"return (\d+);", 1),
    ("mp_jalr", "mispredict: other jalr", r"other jalr (\d+)", 1),
    ("dual_dispatch", "two-wide dispatch cycles", r"Dispatch\s+(\d+) two-wide", 1),
    ("stall_recover", "slot-0 stall: flush/recovery", r"slot 0: recover (\d+)", 1),
    ("stall_serial", "slot-0 stall: serializing", r"serialize (\d+)", 1),
    ("stall_rob", "slot-0 stall: ROB full", r", ROB (\d+),", 1),
    ("stall_rs_alu", "slot-0 stall: ALU RS full", r"ALU RS (\d+)", 1),
    ("stall_rs_br", "slot-0 stall: branch RS full", r"branch RS (\d+)", 1),
    ("stall_rs_mem", "slot-0 stall: memory queue full", r"mem queue (\d+)", 1),
    ("stall_rs_fp", "slot-0 stall: FP RS full", r"FP RS (\d+)", 1),
    ("fe_empty", "front end empty cycles", r"Front end\s+(\d+) cycles", 1),
    ("slot1_empty", "slot 1 lost: empty", r"slot 1 lost: (\d+) empty", 1),
    ("slot1_blocked", "slot 1 lost: blocked", r"empty, (\d+) blocked", 1),
]

# Shown in the summary table (workload x snapshot).
SUMMARY_METRICS = ["completion_cycles", "ipc", "mispredicts"]


def run(cmd: list[str], cwd: pathlib.Path | None = None, env: dict | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def build_images(work: pathlib.Path) -> dict[str, pathlib.Path]:
    """Build each workload's Test_All.mem into its own run directory."""
    result = run([sys.executable, "tools/assemble_tests.py", *map(str, sorted((ROOT / "test_files/asm").glob("*.s"))),
                  "--out-dir", "test_files/generated"], cwd=ROOT)
    if result.returncode != 0:
        raise RuntimeError("assemble_tests.py failed:\n" + result.stdout)

    dirs = {}
    for name, (kind, source, _) in WORKLOADS.items():
        d = work / name
        d.mkdir(parents=True)
        if kind == "mem":
            shutil.copy(ROOT / source, d / "Test_All.mem")
        elif kind == "lockstep":
            lockstep.build_program(ROOT / source, d)
        else:
            result = run(["make", "clean", "all"], cwd=FREERTOS)
            if result.returncode != 0:
                raise RuntimeError("FreeRTOS build failed:\n" + result.stdout[-3000:])
            shutil.copy(FREERTOS / "build" / "freertos_coremark.mem", d / "Test_All.mem")
        dirs[name] = d
    return dirs


def parse_report(text: str) -> dict[str, float]:
    metrics: dict[str, float] = {}
    for key, _, pattern, group in REPORT_FIELDS:
        m = re.search(pattern, text)
        if m:
            value = m.group(group)
            metrics[key] = float(value) if "." in value else int(value)
    return metrics


def run_workload(sim: pathlib.Path, name: str, rundir: pathlib.Path) -> tuple[str, dict]:
    _, _, pass_code = WORKLOADS[name]
    result = run(["vvp", "-n", str(sim), f"+PASS_SSEG={pass_code}", "+FAIL_SSEG=-1", "+MAX_CYCLES=2000000"], cwd=rundir)
    metrics = parse_report(result.stdout)
    if "completion_cycles" not in metrics:
        raise RuntimeError(f"{name} did not pass:\n{result.stdout[-2000:]}")
    return name, metrics


def git_describe(tree: pathlib.Path) -> str:
    result = run(["git", "rev-parse", "--short", "HEAD"], cwd=tree)
    if result.returncode != 0:
        return "unknown"
    head = result.stdout.strip()
    dirty = run(["git", "status", "--porcelain", "--untracked-files=no"], cwd=tree).stdout.strip()
    return head + ("+dirty" if dirty else "")


def load_history() -> list[dict]:
    return json.loads(HISTORY.read_text()) if HISTORY.exists() else []


def fmt(value) -> str:
    if value is None:
        return "-"
    if isinstance(value, float):
        return f"{value:.3f}" if value < 10 else f"{value:.1f}"
    return f"{value:,}"


def render(history: list[dict]) -> None:
    labels = [snap["label"] for snap in history]
    lines = [
        "# Performance History",
        "",
        "Generated by `tools/perf_snapshot.py` from `docs/perf_history.json`; do not edit by hand.",
        "Every snapshot runs the same program images. \"cycles to pass\" is the testbench cycle at which",
        "the program reported PASS; the other numbers come from the run report.",
        "",
        "| Snapshot | Date | Commit | Notes |",
        "| --- | --- | --- | --- |",
    ]
    for snap in history:
        lines.append(f"| {snap['label']} | {snap['date']} | `{snap['commit']}` | {snap.get('notes', '')} |")

    lines += ["", "## Summary", ""]
    for metric in SUMMARY_METRICS:
        title = next(t for k, t, _, _ in REPORT_FIELDS if k == metric)
        lines += [f"### {title}", "", "| Workload | " + " | ".join(labels) + " |",
                  "| --- |" + " ---: |" * len(labels)]
        for name in WORKLOADS:
            row = [fmt(snap["workloads"].get(name, {}).get(metric)) for snap in history]
            lines.append(f"| `{name}` | " + " | ".join(row) + " |")
        lines.append("")

    lines += ["## Per-Workload Detail", ""]
    for name in WORKLOADS:
        lines += [f"### `{name}`", "", "| Metric | " + " | ".join(labels) + " |",
                  "| --- |" + " ---: |" * len(labels)]
        for key, title, _, _ in REPORT_FIELDS:
            row = [fmt(snap["workloads"].get(name, {}).get(key)) for snap in history]
            lines.append(f"| {title} | " + " | ".join(row) + " |")
        lines.append("")

    TABLE.write_text("\n".join(lines))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--label", help="snapshot name (replaces an existing snapshot with the same name)")
    parser.add_argument("--notes", default="", help="one-line description shown in the table")
    parser.add_argument("--rtl-root", type=pathlib.Path, default=ROOT, help="tree whose RTL and testbench are measured")
    parser.add_argument("--commit", help="commit to record (default: git HEAD of --rtl-root)")
    parser.add_argument("--only", nargs="+", choices=list(WORKLOADS), help="run a subset of workloads")
    parser.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 4)
    parser.add_argument("--render", action="store_true", help="only regenerate docs/PERFORMANCE.md")
    args = parser.parse_args()

    history = load_history()
    if args.render:
        render(history)
        return 0
    if not args.label:
        parser.error("--label is required unless --render is given")

    rtl_root = args.rtl_root.resolve()
    names = args.only or list(WORKLOADS)
    with tempfile.TemporaryDirectory(prefix="otter_perf.") as tmp:
        work = pathlib.Path(tmp)
        print("Building workload images...")
        dirs = build_images(work)
        print(f"Compiling the simulator from {rtl_root}...")
        sim = work / "otter_tb.vvp"
        result = run([str(rtl_root / "tools" / "build_sim.sh"), str(sim)], cwd=rtl_root)
        if result.returncode != 0:
            raise RuntimeError("simulator build failed:\n" + result.stdout)

        print(f"Running {len(names)} workloads...")
        results = {}
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
            for name, metrics in pool.map(lambda n: run_workload(sim, n, dirs[n]), names):
                results[name] = metrics
                print(f"  {name:28s} {metrics['completion_cycles']:>9,} cycles  IPC {metrics.get('ipc', 0):.3f}")

    snapshot = {
        "label": args.label,
        "date": datetime.date.today().isoformat(),
        "commit": args.commit or git_describe(rtl_root),
        "notes": args.notes,
        "workloads": {name: results[name] for name in WORKLOADS if name in results},
    }
    for i, snap in enumerate(history):
        if snap["label"] == args.label:
            history[i] = snapshot
            break
    else:
        history.append(snapshot)
    HISTORY.parent.mkdir(parents=True, exist_ok=True)
    HISTORY.write_text(json.dumps(history, indent=2) + "\n")
    render(history)
    print(f"Recorded '{args.label}' in {HISTORY.relative_to(ROOT)}; table in {TABLE.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
