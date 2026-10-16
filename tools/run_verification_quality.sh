#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="${1:-$ROOT/out/verification_logs}"

mkdir -p "$LOG_DIR"

# Locally, the Spike lockstep and assembler checks skip themselves when the
# tools are missing. In CI (GitHub sets CI=true) a missing tool is a failure.
REQUIRE_TOOLS=()
if [[ -n "${CI:-}" ]]; then
  REQUIRE_TOOLS=(--require)
fi

cd "$ROOT"

echo "[verify] regression"
VERIF_LOG_DIR="$LOG_DIR" bash tools/run_regression.sh | tee "$LOG_DIR/regression.log"

echo "[verify] constrained-random"
VERIF_LOG_DIR="$LOG_DIR" python3 tools/run_random_tests.py | tee "$LOG_DIR/random.log"

echo "[verify] aggregate report"
python3 tools/verification_report.py --logs "$LOG_DIR" --out-json "$LOG_DIR/verification_summary.json" | tee "$LOG_DIR/summary.log"

echo "[verify] assembler cross-check (repo assembler vs GNU as)"
python3 tools/check_assembler.py ${REQUIRE_TOOLS[@]+"${REQUIRE_TOOLS[@]}"} | tee "$LOG_DIR/assembler_check.txt"

echo "[verify] lockstep against Spike (directed + ${LOCKSTEP_RANDOM:-200} random programs)"
python3 tools/lockstep.py --random "${LOCKSTEP_RANDOM:-200}" ${REQUIRE_TOOLS[@]+"${REQUIRE_TOOLS[@]}"} | tee "$LOG_DIR/lockstep.txt"

echo "[verify] done logs=$LOG_DIR"
