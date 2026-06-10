#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="${1:-$ROOT/out/verification_logs}"

mkdir -p "$LOG_DIR"

cd "$ROOT"

echo "[verify] regression"
VERIF_LOG_DIR="$LOG_DIR" bash tools/run_regression.sh | tee "$LOG_DIR/regression.log"

echo "[verify] constrained-random"
VERIF_LOG_DIR="$LOG_DIR" python3 tools/run_random_tests.py | tee "$LOG_DIR/random.log"

echo "[verify] aggregate report"
python3 tools/verification_report.py --logs "$LOG_DIR" --out-json "$LOG_DIR/verification_summary.json" | tee "$LOG_DIR/summary.log"

echo "[verify] spike scoreboard hook"
python3 tools/spike_scoreboard.py | tee "$LOG_DIR/spike_scoreboard.log"

echo "[verify] done logs=$LOG_DIR"
