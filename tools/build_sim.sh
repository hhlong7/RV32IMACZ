#!/bin/bash
# Compile the core testbench with Icarus Verilog.
#
#   tools/build_sim.sh [output.vvp]      (default: out/otter_tb.vvp)
#
# Extra compiler flags come from IVERILOG_FLAGS, e.g. selecting true-LRU cache
# replacement instead of the default tree pseudo-LRU:
#   IVERILOG_FLAGS=-DOTTER_TRUE_LRU tools/build_sim.sh
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
# shellcheck disable=SC2086  # IVERILOG_FLAGS is a word list on purpose
iverilog -g2012 ${IVERILOG_FLAGS:-} -o "$OUT" -c rtl.f tb_core.sv >"$log" 2>&1 || status=$?

grep -v -e "sorry: constant selects in always_\* processes" \
        -e "sorry: Case unique/unique0 qualities are ignored" "$log" || true
exit "$status"
