#!/bin/bash
# Compile the core testbench with Icarus Verilog.
#
#   tools/build_sim.sh [output.vvp]      (default: out/otter_tb.vvp)
#
# Icarus prints two notices about SystemVerilog features it has not
# implemented: "constant selects in always_* processes" (it watches the whole
# vector instead of the selected bits) and "unique/unique0 qualities are
# ignored". Neither changes simulation results, and there is no flag to turn
# them off, so this wrapper hides exactly those two. Every other warning or
# error is printed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/out/otter_tb.vvp}"
mkdir -p "$(dirname "$OUT")"

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

cd "$ROOT"
status=0
iverilog -g2012 -o "$OUT" -c rtl.f tb_core.sv >"$log" 2>&1 || status=$?

grep -v -e "sorry: constant selects in always_\* processes" \
        -e "sorry: Case unique/unique0 qualities are ignored" "$log" || true
exit "$status"
