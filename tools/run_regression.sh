#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM="/tmp/otter_sim"

cd "$ROOT"

# Rebuild generated memories from the assembly tests before every regression run.
python3 tools/assemble_tests.py test_files/asm/*.s --out-dir test_files/generated

compile_log="$(mktemp)"
# Keep successful compiles quiet, but surface the full log immediately on failure.
if ! iverilog -g2012 -o "$SIM" \
  otter_defs_pkg.sv \
  ALU.sv \
  AtomicController.sv \
  AtomicDecode.sv \
  BAG.sv \
  BCG.sv \
  BranchPredictor.sv \
  BranchGenerator.sv \
  CSR_FILE.sv \
  CU_DCDR.sv \
  DualIssueInOrder.sv \
  FrontendPacketBuilder.sv \
  FourMux.sv \
  Hazard.sv \
  ImmediateGenerator.sv \
  OTTER_MMIO.sv \
  PC.sv \
  PC_MUX.sv \
  PC_REG.sv \
  REG_FILE.sv \
  RVCExpander.sv \
  StoreBuffer.sv \
  ThreeMux.sv \
  TwoMux.sv \
  cache.sv \
  cachefsm.sv \
  datacache.sv \
  datacachefsm.sv \
  l2cache.sv \
  imem.sv \
  otter_memory_v1_07.sv \
  otter_mcu_pipeline_template_v2.sv \
  tb_core.sv >"$compile_log" 2>&1; then
  cat "$compile_log"
  rm -f "$compile_log"
  exit 1
fi
rm -f "$compile_log"

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

for spec in "${tests[@]}"; do
  IFS=: read -r name pass mem <<< "$spec"
  cp "$mem" Test_All.mem
  echo "== $name =="
  vvp "$SIM" +PASS_SSEG="$pass" +FAIL_SSEG=-1 +MAX_CYCLES=12000 | tail -n 4
done
