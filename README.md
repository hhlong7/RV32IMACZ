# RISC-V-MCPU

## Verification-Quality Flow

This repo now includes a verification-oriented flow that layers assertions,
constrained-random stress, functional coverage aggregation, and CI automation
on top of the existing directed regressions.

### What was added

- In-testbench assertion checks in `tb_core.sv` for:
	- hazard control consistency (`loadUseStall_hz` -> `stallIF_hz/stallID_hz/flushEX_hz`)
	- branch recovery correctness (`branch_mispredict_ex1` must redirect)
	- cache handshake consistency (`hit/miss` mutual exclusion, miss->stall)
	- CSR/trap correctness (no simultaneous trap+mret commit, interrupt acceptance path)
	- memory-ordering and atomic invariants (`fence*_wait` implies LSU busy, SC write/success consistency)
- Functional coverage counters printed as `TB COV ...` at end of simulation.
- Random-test instruction class coverage emitted as `RAND COV ...`.
- Log aggregation tool: `tools/verification_report.py`.
- One-command verification run: `tools/run_verification_quality.sh`.
- Optional Spike scoreboard hook: `tools/spike_scoreboard.py` (gracefully skips if Spike is missing).
- CI flow: `.github/workflows/verification.yml` (Verilator lint + regression + random + artifact upload).

### Run locally

```bash
bash tools/run_verification_quality.sh
```

This writes logs and a machine-readable summary JSON under `out/verification_logs`.
The summary file is:

```text
out/verification_logs/verification_summary.json
```

### Notes on Spike scoreboard

The repository now includes a Spike-check integration point (`tools/spike_scoreboard.py`).
If `spike` is not installed locally, the step is reported as skipped and the
rest of the verification suite still runs to completion.

## Benchmark tables comparing cycles after adding new functionalities

Historical benchmark comparison (captured on March 27, 2026 before the IF1/IF2 split):

| Workload | Metric | Old 5-stage core | 6-stage predicted core | + store buffer core | 7-stage dual-issue core |
| --- | --- | ---: | ---: | ---: | ---: |
| `system_workload` | TB completion cycles | 1047 | 1034 | 1027 | 952 |
| `system_workload` | `flush_id` | 110 | 54 | 54 | 63 |
| `system_workload` | `flush_ex` | 131 | 111 | 111 | 120 |
| `system_workload_benchmark` | TB completion cycles | 1141 | 1113 | 1113 | 1049 |
| `system_workload_benchmark` | benchmark-window cycle delta (`last_leds`) | 804 | 800 | 800 | 759 |
| `system_workload_benchmark` | `flush_id` | 116 | 56 | 56 | 68 |
| `system_workload_benchmark` | `flush_ex` | 160 | 124 | 124 | 136 |

7-stage dual-issue snapshot (captured on March 28, 2026):

| Workload | Metric | 7-stage dual-issue core RV32IMA |
| --- | --- | ---: |
| `system_workload` | TB completion cycles | 952 |
| `system_workload` | `flush_id` | 63 |
| `system_workload` | `flush_ex` | 120 |
| `system_workload_benchmark` | TB completion cycles | 1049 |
| `system_workload_benchmark` | benchmark-window cycle delta (`last_leds`) | 759 |
| `system_workload_benchmark` | `flush_id` | 68 |
| `system_workload_benchmark` | `flush_ex` | 136 |

Current RV32IMAC snapshot (rerun on April 15, 2026):

| Workload | Metric | 7-stage RV32IMA core |
| --- | --- | ---: |
| `system_workload` | TB completion cycles | 914 |
| `system_workload` | `flush_id` | 36 |
| `system_workload` | `flush_ex` | 93 |
| `system_workload_benchmark` | TB completion cycles | 999 |
| `system_workload_benchmark` | benchmark-window cycle delta (`last_leds`) | 713 |
| `system_workload_benchmark` | `flush_id` | 37 |
| `system_workload_benchmark` | `flush_ex` | 105 |

New added features:
- Smarter hazard handling
- Reducing branch penalties
- 2-way associative caches with LRU:
--- prefetch buffer for i-cache
--- one entry posted write buffer in FSM
- 2-level data hierarchy: 2-way L1 D$ backed by a 2-way set-associative L2
- RV32M multiplication and division
- RV32C compressed instructions with front-end decompression and halfword PC sequencing
- RV32A atomics with reservation tracking and stronger fence/ordering behavior
- CSR system instructions
- memory-side verification for atomic commits and coherence-sensitive self-modifying code
=> Passed all the testbench tests, using RISCV Assembly

# Stage 3:
A-extension / memory-ordering update completed:
- 7-stage RV32IMA in-order core: `IF1 -> IF2 -> ID -> EX1 -> EX2 -> MEM -> WB`
- RV32A word-size atomics: `lr.w`, `sc.w`, `amoswap.w`, `amoadd.w`, `amoxor.w`, `amoand.w`, `amoor.w`, `amomin.w`, `amomax.w`, `amominu.w`, `amomaxu.w`
- reservation tracking with same-word store invalidation and explicit SC success/fail behavior
- stronger LSU ordering for `fence`, `fence.i`, and atomic traffic so the store buffer, cache path, and backing memory observe one serialized point
- memory-side atomic commit verification in the testbench plus mirrored I-side updates for self-modifying atomic writes
- expanded directed and randomized atomic coverage, including mixed ordering and reservation-clear scenarios
- fetch-queue prediction carry-through for buffered slot-1 instructions, improving benchmark time without changing in-order retirement

# Stage 2:
Core upgrade completed:
- 7-stage RV32IMA in-order core: `IF1 -> IF2 -> ID -> EX1 -> EX2 -> MEM -> WB`
- 2-slot front-end queue with 2-wide fetch/decode when the next sequential word is already available
- restricted in-order dual issue: older slot keeps full architectural behavior, younger slot issues simple integer work under pairing rules
- structural hazard control that keeps control/CSR/LSU behavior single-owner while still widening safe arithmetic issue
- ordered dual register writeback / retirement so architectural commit stays in program order
- valid/stall/flush-based pipeline control
- widened forwarding + hazard logic redesigned around EX1 resolution
- correct EX1 control resolution for branches/jumps with full-pipe stall protection on load misses
- 2-bit branch predictor
- small BTB
- small RAS
- multi-entry store buffer with youngest-first store-to-load forwarding
- regression + randomized self-checking tests
- added dual-issue-focused randomized coverage for independent pairable ops plus younger-slot control redirects
- expanded randomized front-end/control-flow testing for branches, jumps, call/return, `fence.i`, and RV32A atomic sequences

Validation commands:
- `bash tools/run_regression.sh` for the directed suite, including `rv32a` and `rv32c_*`
- `python3 tools/run_random_tests.py` for randomized store-buffer, frontend, dual-issue, and atomic coverage

Store-buffer load hazard rules:
- Cacheable loads search buffered stores from youngest older entry to oldest.
- If the youngest overlapping store fully covers the requested bytes, the load forwards from that store.
- If the youngest overlapping store covers only part of the requested bytes, the load stalls until the ambiguous store drains.
- If no buffered store overlaps the load bytes, a D-cache hit may proceed normally.
- Cache misses and uncached/MMIO loads wait until all older buffered stores drain before using the memory side.
- Uncached/MMIO loads never forward from the store buffer.

Additional memory-behavior counters:
- `mhpmcounter12` (`0xB0C`): store-buffer enqueues
- `mhpmcounter13` (`0xB0D`): store-buffer full stall cycles
- `mhpmcounter14` (`0xB0E`): store-to-load forwards
- `mhpmcounter15` (`0xB0F`): load stall cycles on unresolved store overlap
- `mhpmcounter16` (`0xB10`): drained stores sent to memory
- `mhpmcounter17` (`0xB11`): `fence.i` wait cycles


# Stage 3:
Added FIFO 4 way entry store-buffer

Store-buffer load hazard rules:
- Cacheable loads search buffered stores from youngest older entry to oldest.
- If the youngest overlapping store fully covers the requested bytes, the load forwards from that store.
- If the youngest overlapping store covers only part of the requested bytes, the load stalls until the ambiguous store drains.
- If no buffered store overlaps the load bytes, a D-cache hit may proceed normally.
- Cache misses and uncached/MMIO loads wait until all older buffered stores drain before using the memory side.
- Uncached/MMIO loads never forward from the store buffer.

Additional memory-behavior counters:
- `mhpmcounter12` (`0xB0C`): store-buffer enqueues
- `mhpmcounter13` (`0xB0D`): store-buffer full stall cycles
- `mhpmcounter14` (`0xB0E`): store-to-load forwards
- `mhpmcounter15` (`0xB0F`): load stall cycles on unresolved store overlap
- `mhpmcounter16` (`0xB10`): drained stores sent to memory
- `mhpmcounter17` (`0xB11`): `fence.i` wait cycles


# Stage 2:
Core upgrade completed:
- 6-stage RV32IM in-order core: `IF -> ID -> EX1 -> EX2 -> MEM -> WB`
- valid/stall/flush-based pipeline control
- forwarding + hazard logic redesigned around EX1 resolution
- correct EX1 control resolution for branches/jumps with full-pipe stall protection on load misses
- 2-bit branch predictor
- small BTB
- small RAS
- multi-entry store buffer with youngest-first store-to-load forwarding
- regression + randomized self-checking tests


# Stage 1:
Finishing up the current core: 
- performance counters the mcpu (cycle counts, retired instruction count, branch flushes/mispredict, load-use stall, icahce and dcache misses, prefetch hits, prefetch useless hits, trap count, M-extension busy/stall cycles)
- finish the system side: traps, exceptions, ecall, ebreak, mepc, mcause, mtvec, mstatus, mret, the rest of useful CSR instructions; prove that its right by 
	- ecall goes to trap handler
	- ebreak goes to trap handler
	- illegal opcode sets the right cause
	- mepc captures the right PC
	- mret returns correctly
- added fence.i
- random testing: Write small assembly tests for:
	•	ALU ops
	•	branches and jumps
	•	forwarding
	•	load-use hazards
	•	cache hits/misses
	•	RV32M ops
	•	CSR ops
	•	ecall, ebreak, illegal instruction
	•	mret
	•	fence.i

# Initials:
New added features:
- Smarter hazard handling
- Reducing branch penalties
- 2-way associative caches with LRU:
--- prefetch buffer for i-cache
--- one entry posted write buffer in FSM
- RV32M multiplication and division
- CSR system instructions
=> Passed all the testbench tests, using RISCV Assembly

# April 2026 FreeRTOS + Refactor Update:
Recent bring-up and cleanup work added software-boot capability on top of the existing RV32IMAC pipeline and also split some of the larger RTL blocks into clearer submodules.

FreeRTOS / CoreMark bring-up:
- Added a FreeRTOS + CoreMark simulation target under `software/freertos_coremark/`
- The core now boots FreeRTOS in simulation and reaches the CoreMark payload successfully
- `bash tools/run_freertos_coremark.sh` builds the software image, loads `Test_All.mem`, runs the RTL simulation, and restores the original memory image on exit
- Current smoke-pass condition is MMIO seven-segment code `201`

Machine timer + interrupt support:
- Added CLINT-style machine timer registers for `mtime` and `mtimecmp`
- Timer MMIO addresses now include:
	- `0x02004000` / `0x02004004` for `mtimecmp`
	- `0x0200BFF8` / `0x0200BFFC` for `mtime`
- Timer compare now raises the machine timer interrupt path used by the CSR/trap logic
- Interrupt acceptance was tightened so asynchronous interrupts are only taken at a clean architectural boundary, avoiding stale pipeline snapshots during entry to the trap handler

RTL modularization:
- Added `DualIssueInOrder.sv` to isolate the conservative in-order dual-issue policy
- Slot 0 remains the full architectural owner; slot 1 is still restricted to simple integer register-writing work with no LSU, CSR, trap, or control-flow side effects
- Added `OTTER_MMIO.sv` to isolate external MMIO handling and the CLINT-style timer block from `otter_memory_v1_07.sv`
- `otter_mcu_pipeline_template_v2.sv` now instantiates `DualIssueInOrder.sv`
- `otter_memory_v1_07.sv` now instantiates `OTTER_MMIO.sv`

Validation status:
- Directed regressions pass with `bash tools/run_regression.sh`
- Randomized regressions pass with `python3 tools/run_random_tests.py`
- FreeRTOS/CoreMark smoke simulation passes with `bash tools/run_freertos_coremark.sh`
- Recent rerun snapshot:
	- `system_workload`: 914 TB completion cycles
	- `system_workload_benchmark`: 999 TB completion cycles
	- FreeRTOS/CoreMark simulation: pass code `201`

Maintenance note:
- The simulation/build scripts manually enumerate RTL source files, so any new module addition must also be added to the relevant script source lists