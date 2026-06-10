#!/usr/bin/env python3
"""Optional Spike scoreboard hook for CI/local flows.

This script is intentionally conservative: it checks whether Spike is available
and records a deterministic status line that higher-level scripts can parse.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess


def detect_spike_version(spike: str) -> str:
    # Some Spike builds do not implement --version, but print a banner in --help.
    for args in (["--version"], ["--help"]):
        result = subprocess.run([spike, *args], text=True, capture_output=True, check=False)
        text = (result.stdout or "") + "\n" + (result.stderr or "")
        for line in text.splitlines():
            line = line.strip()
            lower = line.lower()
            if lower.startswith("spike riscv isa simulator") or lower.startswith("spike risc-v isa simulator"):
                return line
    return "unknown"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--require", action="store_true", help="Fail if spike is unavailable")
    args = parser.parse_args()

    spike = shutil.which("spike")
    if spike is None:
        print("SPIKE_SCOREBOARD status=skipped reason=missing_spike")
        return 1 if args.require else 0

    version_line = detect_spike_version(spike)
    print(f"SPIKE_SCOREBOARD status=ready tool={spike} version={version_line}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
