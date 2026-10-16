#!/bin/bash
# Build FreeRTOS + CoreMark for the core and run it in simulation.
#
#   tools/run_freertos_coremark.sh            quiet: build status + run report
#   VERBOSE=1 tools/run_freertos_coremark.sh  show the full compiler output
#
# Extra testbench options can be appended, e.g. +VERBOSE_MMIO.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/software/freertos_coremark"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/otter_freertos.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "Building FreeRTOS + CoreMark..."
if [[ -n "${VERBOSE:-}" ]]; then
  (cd "$APP" && PATH="$ROOT/.venv/bin:$PATH" make clean all)
elif ! (cd "$APP" && PATH="$ROOT/.venv/bin:$PATH" make clean all) >"$WORK/build.log" 2>&1; then
  cat "$WORK/build.log"
  echo "Build failed."
  exit 1
fi
size_bytes="$(wc -c < "$APP/build/freertos_coremark.bin" | tr -d ' ')"
echo "  built build/freertos_coremark.elf (${size_bytes} byte image)"

echo "Compiling the simulator..."
"$ROOT/tools/build_sim.sh" "$WORK/otter_tb.vvp"

# The testbench loads Test_All.mem from its working directory, so the
# checked-in Test_All.mem is never touched.
cp "$APP/build/freertos_coremark.mem" "$WORK/Test_All.mem"

# Pass/fail codes are surfaced through the MMIO seven-segment register.
echo "Running (this takes a little while)..."
(cd "$WORK" && vvp -n otter_tb.vvp +PASS_SSEG=201 +FAIL_SSEG=901 +MAX_CYCLES=2000000 "$@")
