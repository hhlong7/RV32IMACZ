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

## Supported ISA

Current software target:

```text
rv32imac_zicsr_zifencei
```

Implemented ISA pieces:

| Extension | Description |
| --- | --- |
| `RV32I` | Base 32-bit integer instruction set |
| `RV32M` | Integer multiply and divide |
| `RV32A` | Atomic instructions including `LR/SC` and AMOs |
| `RV32C` | Compressed 16-bit instruction support |
| `Zicsr` | CSR read/modify/write instructions |
| `Zifencei` | Instruction-stream synchronization with `fence.i` |

Related system support included in the core:

- machine-mode CSR, trap, and `mret` handling (M-only hart: `mstatus.MPP`
  reads as M, `mtvec` is direct mode, `wfi` is a no-op)
- precise address-misaligned exceptions for loads, stores, and atomics
- timer interrupt support
- MMIO-backed software-visible I/O path
- verification workloads covering arithmetic, control flow, cache behavior,
  atomics, compressed instructions, CSR operations, traps, and `fence.i`

## Architecture Diagrams

Top-level block view of the core:

<p align="center">
  <img src="docs/images/otter_mcu_block.svg" alt="OTTER_MCU top-level block diagram" width="800">
</p>

Deeper module hierarchy view extracted from the RTL:

<p align="center">
  <img src="docs/images/otter_mcu_hierarchy.svg" alt="OTTER_MCU module hierarchy diagram" width="800">
</p>

## Learn The Project

1. `otter_mcu_pipeline_template_v2.sv`
   Main core RTL and pipeline behavior.
2. `tb_core.sv`
   Main testbench, pass/fail behavior, and verification checks.
3. `test_files/asm/`
   Directed assembly tests used by the regression flow.
4. `tools/lockstep.py`, `tools/run_regression.sh`, `tools/run_random_tests.py`
   How the project is tested; `lockstep.py` compares the core against Spike.
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
- Optional: `spike` and GNU binutils (`riscv64-unknown-elf-as/ld/objcopy`)
  for the lockstep comparison and the assembler cross-check; both tools
  report `status=skipped` when these are missing
- Optional: `riscv64-unknown-elf-gcc` toolchain for the FreeRTOS + CoreMark
  example

Every flow compiles the RTL listed in `rtl.f` (`iverilog -c rtl.f`,
`verilator -f rtl.f`).

The directed assembly tests use the repo's own assembler script
`tools/assemble_tests.py`, so you do not need an external RISC-V assembler for
the normal regression flow.

### Run The Directed Regression Suite

```bash
bash tools/run_regression.sh
```

This rebuilds memory images from `test_files/asm/*.s`, runs the directed test
suite, and prints the last lines of each simulation run.

### Run The Lockstep Comparison Against Spike

```bash
python3 tools/lockstep.py --random 200
```

Each program in `test_files/lockstep/` (plus N seeded random programs from
`tools/lockstep_random.py`) is assembled with GNU `as` and run on both Spike
and the RTL. The testbench's `+COMMIT_LOG` trace is compared against Spike's
commit log: every retired instruction's PC, destination register and value,
and every memory write's address, data and size. The directed programs cover
every RV32IMAC/Zicsr/Zifencei instruction with edge operands, traps, CSRs,
misaligned accesses, and self-modifying code; the random programs stress
forwarding, dual issue, mixed 16/32-bit streams, store-buffer forwarding and
overflow, atomics, branch prediction, and traps in arbitrary pipeline states.

The checker was validated by mutation: planted bugs in the ALU, the bypass
priority, the load-use stall, the RVC expander, and store-buffer conflict
detection are all reported, and a performance-only predictor change is not.

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

This runs the directed suite, randomized tests, report aggregation, the
assembler cross-check (`tools/check_assembler.py`: the repo's small assembler
against GNU `as`), and the Spike lockstep comparison. Logs and summary files
are written to:

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

Run on October 15, 2026 with `bash tools/run_verification_quality.sh`:

- Directed regression suite: `23 / 23` passed
- Legacy randomized tests: store-buffer unit test plus `16 / 16` seeded programs
- Assembler cross-check: 6,000 random instructions, 0 encoding mismatches
- Lockstep vs Spike: 8 directed + 200 random programs, ~115k retired
  instructions, 0 mismatches (an additional 1,000-seed run also passed)
- Verilator lint: no RTL warnings (only `PROCASSINIT` style warnings in
  `tb_core.sv`)

### Bugs found by the lockstep flow (fixed October 2026)

- D-cache refill wrote zero into word 7 of the line (in L1 and L2) when the
  missing load was a sub-word load at a non-zero byte offset
- Atomics stalled in EX1 lost their forwarded operands once the producer
  retired, so LR/SC/AMO could use a stale address or data value
- `jalr` did not clear bit 0 of a target computed from an odd register
- `mepc` dropped bit 1, so a trap from a 2-byte-aligned PC returned to the
  wrong address under RV32C
- Misaligned loads/stores silently returned 0 or dropped the write, and
  misaligned atomics stopped the simulation; they now trap precisely
- `misa` omitted A and C; `mret` cleared `mstatus.MPP` instead of keeping M;
  writing `misa` and executing `wfi` raised illegal-instruction exceptions
- Reserved `SYSTEM` encodings (funct3=100, non-zero rs1/rd on
  ecall/ebreak/mret) executed instead of trapping
- `mret` and `fence.i` were not counted in `minstret`
- A trap could overtake an older in-flight `csrw` to `mcause`/`mtval`
- `tools/run_regression.sh` printed results but never failed on a failing test

## Project Layout

- Root `*.sv` files: core RTL, caches, MMIO, predictor, and testbenches
- `rtl.f`: the RTL file list shared by every simulation and lint flow
- `test_files/asm/`: hand-written directed assembly tests
- `test_files/lockstep/`: directed programs for the Spike lockstep flow
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

### Post-Verification Snapshot

Rerun on October 15, 2026 after the bug fixes above (MRET and FENCE.I now
retire through the pipe instead of being killed in EX1):

| Workload | Metric | Before | After |
| --- | --- | ---: | ---: |
| `system_workload` | TB completion cycles | 914 | 910 |
| `system_workload` | `flush_ex` | 93 | 88 |
| `system_workload_benchmark` | TB completion cycles | 999 | 993 |
| `system_workload_benchmark` | `flush_ex` | 105 | 98 |

### FreeRTOS + CoreMark Smoke Snapshot

Captured during the April 2026 software bring-up:

- `system_workload`: 914 TB completion cycles
- `system_workload_benchmark`: 999 TB completion cycles
- FreeRTOS/CoreMark simulation pass code: `201`
