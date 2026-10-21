#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/otter_regression.XXXXXX")"
SIM="$WORK/otter_tb.vvp"
LOG_DIR="${VERIF_LOG_DIR:-}"
SIM_WALL_SECONDS="${SIM_WALL_SECONDS:-120}"
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT"

if [[ -n "$LOG_DIR" ]]; then
  mkdir -p "$LOG_DIR"
fi

# Rebuild generated memories from the assembly tests before every regression run.
python3 tools/assemble_tests.py test_files/asm/*.s --out-dir test_files/generated

tools/build_sim.sh "$SIM"

# name:expected-pass-seven-seg:memory-image
tests=(
  "branch_redirect:104:test_files/generated/branch_redirect.mem"
  "hazard_branch:103:test_files/generated/hazard_branch_full.mem"
  "rv32m:101:test_files/generated/rv32m.mem"
  "dcache_lru:107:test_files/generated/dcache_lru_full.mem"
  "l2_cache:125:test_files/generated/l2_cache_full.mem"
  "store_buffer:108:test_files/generated/store_buffer_full.mem"
  "store_buffer_flush:120:test_files/generated/store_buffer_flush_full.mem"
  "store_buffer_mmio:121:test_files/generated/store_buffer_mmio_full.mem"
  "icache_prefetch:105:test_files/generated/icache_prefetch.mem"
  "alu_ops:111:test_files/generated/alu_ops.mem"
  "branches_jumps:112:test_files/generated/branches_jumps.mem"
  "forwarding:113:test_files/generated/forwarding.mem"
  "load_use_hazard:114:test_files/generated/load_use_hazard_full.mem"
  "cache_counters:115:test_files/generated/cache_counters_full.mem"
  "csr_ops:116:test_files/generated/csr_ops.mem"
  "trap_system:117:test_files/generated/trap_system.mem"
  "fence_i:118:test_files/generated/fence_i.mem"
  "timer_interrupt:126:test_files/generated/timer_interrupt.mem"
  "rv32a:122:test_files/generated/rv32a_full.mem"
  "rv32c_control:123:test_files/generated/rv32c_control.mem"
  "rv32c_memory:124:test_files/generated/rv32c_memory.mem"
  "system_workload:13:test_files/generated/system_workload_full.mem"
  "system_workload_benchmark:119:test_files/generated/system_workload_benchmark_full.mem"
)

failed=()
for spec in "${tests[@]}"; do
  IFS=: read -r name pass mem <<< "$spec"
  # The testbench loads Test_All.mem from its working directory; run in the
  # scratch directory so the checked-in Test_All.mem is never overwritten.
  cp "$mem" "$WORK/Test_All.mem"
  # +STATS keeps the machine-readable counters in the logs for
  # tools/verification_report.py.
  # +MAX_CYCLES bounds simulated time; the wall-clock limit (perl alarm, which
  # works on macOS and Linux alike) also catches a simulator stuck in a
  # zero-time loop, which never reaches the cycle limit.
  sim_out="$(cd "$WORK" && perl -e 'alarm shift; exec @ARGV' "$SIM_WALL_SECONDS" \
             vvp -n "$SIM" +STATS +PASS_SSEG="$pass" +FAIL_SSEG=-1 +MAX_CYCLES=12000 2>&1 || true)"
  if [[ -z "$sim_out" ]]; then
    sim_out="TB TIMEOUT wall clock: no output after ${SIM_WALL_SECONDS}s (simulator stuck)"
  fi
  if [[ -n "$LOG_DIR" ]]; then
    printf '%s\n' "$sim_out" > "$LOG_DIR/${name}.log"
  fi
  # A testbench assertion (including the per-cycle invariants) fails the test
  # even if the program itself reported PASS.
  if grep -q "^ASSERT_FAIL" <<< "$sim_out"; then
    printf '  %-28s FAIL (assertion)\n' "$name"
    grep -m5 "^ASSERT_FAIL" <<< "$sim_out" | sed 's/^/      /'
    failed+=("$name")
  elif pass_line="$(grep -m1 "^TB PASS" <<< "$sim_out")"; then
    printf '  %-28s PASS  %6s cycles\n' "$name" "${pass_line##*cycle=}"
  else
    printf '  %-28s FAIL\n' "$name"
    printf '%s\n' "$sim_out" | grep -v "^TB \(STATS\|LSU\|ATOM\|COV\)" | tail -n 8 | sed 's/^/      /'
    failed+=("$name")
  fi
done

echo "Regression: $(( ${#tests[@]} - ${#failed[@]} )) passed, ${#failed[@]} failed"
if (( ${#failed[@]} > 0 )); then
  echo "Failed: ${failed[*]}"
  exit 1
fi
