#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM="/tmp/otter_freertos_coremark_sim"
ORIGINAL_MEM="$(mktemp)"

# Preserve the user's default memory image even though this flow temporarily
# swaps in a FreeRTOS/CoreMark program image.
cp "$ROOT/Test_All.mem" "$ORIGINAL_MEM"
cleanup() {
  cp "$ORIGINAL_MEM" "$ROOT/Test_All.mem"
  rm -f "$ORIGINAL_MEM"
}
trap cleanup EXIT

# Build the software payload inside the dedicated app directory.
cd "$ROOT/software/freertos_coremark"
PATH="$ROOT/.venv/bin:$PATH" make clean all

cd "$ROOT"
cp software/freertos_coremark/build/freertos_coremark.mem Test_All.mem

# The source list is intentionally explicit so simulation runs are reproducible
# even outside a larger project system.
iverilog -g2012 -o "$SIM" \
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
  tb_core.sv

# Pass/fail codes are surfaced through the MMIO seven-segment register.
vvp "$SIM" +PASS_SSEG=201 +FAIL_SSEG=901 +MAX_CYCLES=2000000