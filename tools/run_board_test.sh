#!/bin/bash
# Simulate the Zybo board top (board/zybo/zybo_top.sv) running the board demo
# (board/zybo/zybo_hello.mem) with a UART terminal model; prints TB_ZYBO
# PASS or FAIL. The memories load Test_All.mem from the working directory,
# so the demo image is copied into a scratch directory.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/otter_board.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT"
iverilog -g2012 -o "$WORK/tb_zybo.vvp" -c rtl.f board/uart.sv board/zybo/zybo_top.sv board/zybo/tb_zybo.sv \
  > "$WORK/build.log" 2>&1 || { grep -i "error" "$WORK/build.log"; echo "TB_ZYBO FAIL (build)"; exit 1; }
cp board/zybo/zybo_hello.mem "$WORK/Test_All.mem"
(cd "$WORK" && vvp -n tb_zybo.vvp) | tee "$WORK/run.log" | grep -v "^VCD" || true
grep -q "TB_ZYBO PASS" "$WORK/run.log"
