#!/bin/bash
# Simulate the Zybo board top (board/zybo/zybo_top.sv) with a UART terminal
# model. The memories load Test_All.mem from the working directory, so the
# program image is copied into a scratch directory.
#
#   tools/run_board_test.sh            the board demo (board/zybo/zybo_hello.mem);
#                                      prints TB_ZYBO PASS or FAIL (part of CI)
#   tools/run_board_test.sh coremark   FreeRTOS + CoreMark as built for the board,
#                                      with a 20 kHz pretend clock and one iteration so the
#                                      run fits in a short simulation (needs the RISC-V
#                                      compiler; takes several minutes)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/otter_board.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
MODE="${1:-hello}"

cd "$ROOT"
if [[ "$MODE" == "coremark" ]]; then
  TB=board/zybo/tb_zybo_coremark.sv
  MARK="TB_ZYBO_COREMARK PASS"
  # One iteration (about 325,000 cycles) is 16 "seconds" at the pretend
  # 20 kHz clock, so it passes CoreMark's 10-second rule without calibrating.
  make -s -C software/freertos_coremark BOARD=zybo ZYBO_CLOCK_HZ=20000 ITERATIONS=1 BUILD="$WORK/sw" all \
    > "$WORK/sw.log" 2>&1 || { cat "$WORK/sw.log"; exit 1; }
  cp "$WORK/sw/freertos_coremark.mem" "$WORK/Test_All.mem"
else
  TB=board/zybo/tb_zybo.sv
  MARK="TB_ZYBO PASS"
  cp board/zybo/zybo_hello.mem "$WORK/Test_All.mem"
fi

iverilog -g2012 -o "$WORK/tb.vvp" -c rtl.f board/uart.sv board/zybo/zybo_top.sv "$TB" \
  > "$WORK/build.log" 2>&1 || { grep -i "error" "$WORK/build.log"; echo "board test FAIL (build)"; exit 1; }
(cd "$WORK" && vvp -n tb.vvp) | tee "$WORK/run.log" | grep -v "^VCD" || true
grep -q "$MARK" "$WORK/run.log"
