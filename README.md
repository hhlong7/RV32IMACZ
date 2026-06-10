# RV32IMACZ

This repo contains a simulation-first RISC-V CPU built around a
seven-stage in-order core and a practical verification flow. The current
software target is `rv32imac_zicsr_zifencei`, and the repo includes directed
tests, randomized tests, and a FreeRTOS + CoreMark demo.

## Project Overview

- Seven-stage pipeline: `IF1 -> IF2 -> ID -> EX1 -> EX2 -> MEM -> WB`
- Two-slot front end with restricted dual issue
- ISA support: RV32I, RV32M, RV32A, RV32C, `Zicsr`, `Zifencei`
- Branch prediction with a small BHT, BTB, and RAS
- Cache hierarchy with i-cache prefetch, L1 D-cache, L2 cache, and store buffer
- Trap, CSR, timer-interrupt, and MMIO support
- Verification flows for directed regressions, constrained-random testing, and
  report aggregation

## Learn The Project

1. `otter_mcu_pipeline_template_v2.sv`
   Main core RTL and pipeline behavior.
2. `tb_core.sv`
   Main testbench, pass/fail behavior, and verification checks.
3. `test_files/asm/`
   Directed assembly tests used by the regression flow.
4. `tools/run_regression.sh` and `tools/run_random_tests.py`
   The fastest way to understand how the project is tested.
5. `software/freertos_coremark/`
   A small software workload that boots FreeRTOS and runs CoreMark in
   simulation.

Other useful files:

- `StoreBuffer.sv`, `datacache.sv`, `l2cache.sv` for the memory path
- `BranchPredictor.sv`, `FrontendPacketBuilder.sv`, `RVCExpander.sv` for the
  front end
- `CSR_FILE.sv`, `AtomicController.sv`, `AtomicDecode.sv` for system and
  atomic support
- `OTTER_Wrapper_v1_03.sv` and `Basys3_Master.xdc` for board-level integration

## How To Use It

### Prerequisites

- `python3`
- `iverilog` and `vvp`
- Optional: `verilator` for lint
- Optional: `riscv64-unknown-elf-gcc` toolchain for the FreeRTOS + CoreMark
  example

The directed assembly tests use the repo's own assembler script
`tools/assemble_tests.py`, so you do not need an external RISC-V assembler for
the normal regression flow.

### Run The Directed Regression Suite

```bash
bash tools/run_regression.sh
```

This rebuilds memory images from `test_files/asm/*.s`, runs the directed test
suite, and prints the last lines of each simulation run.

### Run The Randomized Tests

```bash
python3 tools/run_random_tests.py
```

This generates deterministic randomized programs that stress ALU behavior,
control flow, dual issue, store-buffer behavior, and atomic operations.

### Run The Full Verification Flow

```bash
bash tools/run_verification_quality.sh
```

This runs the directed suite, randomized tests, report aggregation, and the
optional Spike scoreboard hook. Logs and summary files are written to:

```text
out/verification_logs/
```

The aggregated machine-readable summary is:

```text
out/verification_logs/verification_summary.json
```

### Run The FreeRTOS + CoreMark Demo

```bash
bash tools/run_freertos_coremark.sh
```

This builds the software image in `software/freertos_coremark/`, temporarily
loads it into `Test_All.mem`, runs simulation, and restores your original
memory image when it finishes.

## Latest Verification Run

The final verification flow was run on June 10, 2026 using the repo's real scripts,
not just listed as an example.

Commands run:

```bash
bash tools/run_verification_quality.sh
verilator --lint-only --timing -Wall -Wno-fatal --top-module tb_core ...
bash tools/run_freertos_coremark.sh
```

Results:

- Directed regression suite: `23 / 23` workloads passed
- Randomized verification: standalone `TB_STORE_BUFFER` test passed
- Seeded randomized RTL runs: `16 / 16` passed
- Aggregate verification summary written to
  `out/verification_logs/verification_summary.json`
- Spike scoreboard hook completed and detected local Spike successfully
- Verilator lint exited with code `0`
- FreeRTOS + CoreMark smoke run passed with `pass_sseg=201` at cycle `373191`

The June 10, 2026 aggregate summary reported:

- all defined summary bins hit for hazard, cache, branch recovery, CSR/trap,
  memory-ordering, atomic, and randomized instruction-class coverage
- `branch_redirects=1272`
- `ic_hit=3178`, `ic_miss=204`
- `dc_hit=574`, `dc_miss=326`
- `sb_enq=682`, `sb_fwd=150`, `fence_wait=380`
- `atomic commits=244`, `sc_success=50`, `sc_fail=46`

Lint note:

- Verilator reported existing `PROCASSINIT` warnings in `tb_core.sv`, but the
  lint command still completed successfully with exit code `0`

## Project Layout

- Root `*.sv` files: core RTL, caches, MMIO, predictor, and testbenches
- `test_files/asm/`: hand-written directed assembly tests
- `test_files/generated/`: generated `.mem` images used in simulation
- `tools/`: build, test, reporting, and helper scripts
- `software/freertos_coremark/`: FreeRTOS + CoreMark software example
- `third_party/`: vendored FreeRTOS and CoreMark sources

## Current Status

The current design is a seven-stage RV32IMAC core with atomics, compressed
instructions, branch prediction, CSR/trap support, a store buffer, and a
two-level data-cache hierarchy. The repo also includes verification scripts and
a software bring-up path so the project is easier to study and extend.

## Performance Snapshots

These snapshots are kept here so the project history stays visible.

### Historical Comparison

Captured on March 27, 2026 before the `IF1` / `IF2` split:

| Workload | Metric | Old 5-stage core | 6-stage predicted core | + store buffer core | 7-stage dual-issue core |
| --- | --- | ---: | ---: | ---: | ---: |
| `system_workload` | TB completion cycles | 1047 | 1034 | 1027 | 952 |
| `system_workload` | `flush_id` | 110 | 54 | 54 | 63 |
| `system_workload` | `flush_ex` | 131 | 111 | 111 | 120 |
| `system_workload_benchmark` | TB completion cycles | 1141 | 1113 | 1113 | 1049 |
| `system_workload_benchmark` | benchmark-window cycle delta (`last_leds`) | 804 | 800 | 800 | 759 |
| `system_workload_benchmark` | `flush_id` | 116 | 56 | 56 | 68 |
| `system_workload_benchmark` | `flush_ex` | 160 | 124 | 124 | 136 |

### 7-Stage Dual-Issue Snapshot

Captured on March 28, 2026:

| Workload | Metric | 7-stage dual-issue core RV32IMA |
| --- | --- | ---: |
| `system_workload` | TB completion cycles | 952 |
| `system_workload` | `flush_id` | 63 |
| `system_workload` | `flush_ex` | 120 |
| `system_workload_benchmark` | TB completion cycles | 1049 |
| `system_workload_benchmark` | benchmark-window cycle delta (`last_leds`) | 759 |
| `system_workload_benchmark` | `flush_id` | 68 |
| `system_workload_benchmark` | `flush_ex` | 136 |

### Current RV32IMAC Snapshot

Rerun on April 15, 2026:

| Workload | Metric | 7-stage RV32IMA core |
| --- | --- | ---: |
| `system_workload` | TB completion cycles | 914 |
| `system_workload` | `flush_id` | 36 |
| `system_workload` | `flush_ex` | 93 |
| `system_workload_benchmark` | TB completion cycles | 999 |
| `system_workload_benchmark` | benchmark-window cycle delta (`last_leds`) | 713 |
| `system_workload_benchmark` | `flush_id` | 37 |
| `system_workload_benchmark` | `flush_ex` | 105 |

### FreeRTOS + CoreMark Smoke Snapshot

Captured during the April 2026 software bring-up:

- `system_workload`: 914 TB completion cycles
- `system_workload_benchmark`: 999 TB completion cycles
- FreeRTOS/CoreMark simulation pass code: `201`
