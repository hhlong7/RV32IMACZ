#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="${1:-$ROOT/out/verification_logs}"

mkdir -p "$LOG_DIR"
# Start from a clean log directory so the coverage report only counts this run.
rm -f "$LOG_DIR"/*.log "$LOG_DIR"/*.txt "$LOG_DIR"/verification_summary.json

# Locally, the Spike lockstep and assembler checks skip themselves when the
# tools are missing. In CI (GitHub sets CI=true) a missing tool is a failure.
REQUIRE_TOOLS=()
if [[ -n "${CI:-}" ]]; then
  REQUIRE_TOOLS=(--require)
fi

cd "$ROOT"

echo "== 1/5 Directed regression =="
VERIF_LOG_DIR="$LOG_DIR" bash tools/run_regression.sh | tee "$LOG_DIR/regression.log"

echo; echo "== 2/5 Legacy random tests =="
VERIF_LOG_DIR="$LOG_DIR" python3 tools/run_random_tests.py | tee "$LOG_DIR/random.log"

echo; echo "== 3/5 Coverage report =="
python3 tools/verification_report.py --logs "$LOG_DIR" --out-json "$LOG_DIR/verification_summary.json" | tee "$LOG_DIR/summary.log"

echo; echo "== 4/5 Assembler cross-check (repo assembler vs GNU as) =="
python3 tools/check_assembler.py ${REQUIRE_TOOLS[@]+"${REQUIRE_TOOLS[@]}"} | tee "$LOG_DIR/assembler_check.txt"

echo; echo "== 5/5 Lockstep vs Spike (directed + ${LOCKSTEP_RANDOM:-200} random programs) =="
python3 tools/lockstep.py --random "${LOCKSTEP_RANDOM:-200}" ${REQUIRE_TOOLS[@]+"${REQUIRE_TOOLS[@]}"} | tee "$LOG_DIR/lockstep.txt"

echo; echo "All checks passed. Logs: $LOG_DIR"
