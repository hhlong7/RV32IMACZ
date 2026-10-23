# Timing Closure Plan

The out-of-order core is functionally verified and fast in cycles (IPC 1.207 on
FreeRTOS + CoreMark), but it was designed for simulation, where a clock cycle
can hold any amount of logic. On an FPGA it does not close timing: Vivado
synthesis for the Artix-7 200T (`xc7a200tsbg484-1`, out of context, memory
models black-boxed) reports:

| Metric | Value |
| --- | --- |
| Clock target | 20 ns (50 MHz) |
| Worst setup slack | **-101.7 ns** (52,739 of 73,438 endpoints fail) |
| Estimated Fmax | **8.2 MHz** |
| Worst path | 337 logic levels, 121.7 ns (282 of them `CARRY4` adder stages) |
| Size | 52,826 LUTs (39%), 33,595 flip-flops, 10 DSPs |

Performance on hardware is IPC x clock, so before this plan the core would
deliver about 1.207 x 8.2 = **10 MIPS**. The goal of this plan is **50 MHz or more after
place and route** with as little IPC loss as possible, which would be roughly
**55-70 MIPS**, a 5-7x gain.

## Why the clock is slow

The worst path is a whole out-of-order step done in one cycle:

```text
ROB head ─► ALU reservation station: pick the oldest ready entry
           (ages = tag - ROB head, a subtraction on every comparison)
        ─► ALU: 32-bit combinational divide (≈280 adder levels) / 33x33 multiply
        ─► CDB arbiter: rank the requests by age (tag - ROB head again)
        ─► CDB broadcast ─► dispatch operand bypass (a value broadcast this
           cycle is forwarded into the instruction being dispatched)
        ─► captured into a memory-queue / reservation-station entry
```

In simulation that costs nothing; on an FPGA every arrow is a few nanoseconds.

## Measurements the plan is built on

Instruction mix (committed instructions):

| Workload | Multiplies / 1k | Divides / 1k |
| --- | ---: | ---: |
| FreeRTOS + CoreMark | 28.6 (9,497) | 0.003 (1 in 332k) |
| `system_workload`, `system_workload_benchmark` | about 6.7 | about 2.7 |
| `rv32im_alu` (directed M-extension test) | 52.9 | 52.9 |
| `cache_stress` | 0 | 0 |

Back-to-back dependences: an ALU or branch instruction that issues in the
cycle right after its producer's result was broadcast.

| Workload | Back-to-back issues | Share of ALU/branch issues |
| --- | ---: | ---: |
| FreeRTOS + CoreMark | 139,080 | **54%** |
| `system_workload` | 245 | 43% |
| `rv32im_alu` | 3,521 | 51% |

Consequences:

- A slow divider costs real software almost nothing; a slow multiplier costs
  a little; but adding a cycle between a producer and its dependent would add
  up to a cycle to more than half of all issues (up to about +50% runtime).
  Step 3 therefore must keep **back-to-back issue of dependent single-cycle
  ALU operations**, which needs speculative (tag-only) wake-up.

## Step 0: post-route timing in the Vivado flow

Synthesis-only timing is optimistic (no wire delays from real placement).
Add an option to `tools/vivado/synth_core.tcl` that also runs `opt_design`,
`place_design`, and `route_design` out of context and reports post-route
slack, so every step below is judged on post-route Fmax.

## Step 1: multi-cycle integer divider

**Change.** Take division out of the ALU and give it its own unit, built like
the FP divider:

- A radix-2 restoring/non-restoring divider: 32 iterations of one 33-bit
  subtract, plus a setup cycle (operand magnitudes, divide-by-zero and
  `INT_MIN / -1` handled up front) and a fix-up cycle (signs of quotient and
  remainder). About 34 cycles, one division at a time.
- The ALU station still holds `div/divu/rem/remu`; an issued divide goes to the
  divider instead of the ALU. The divider requests a CDB when done (like
  `fp_divider`), is killed by a branch recovery that squashes it (`fdiv_kill`
  pattern), and blocks further divides while busy.
- Optional later: radix-4 (2 bits per cycle, about 18 cycles) if division
  turns out to matter.

**Expected.** Removes about 280 of the 337 logic levels. The next limit is the
single-cycle 33x33 multiply plus the select → arbitrate → bypass chain:
roughly **20-25 MHz** after this step.

**IPC cost.** FreeRTOS + CoreMark: about 0% (one divide). `system_workload`:
2 divides, about +60 cycles (~7%). `rv32im_alu`: 362 divides, several times
slower (it is a directed divide test, not a workload).

**Verification.**
- Unit test against a reference model (Python, like `tools/fp_ref.py`):
  millions of random operand pairs plus every edge (`/0`, `INT_MIN / -1`,
  `x / 1`, `x / x`, signed/unsigned mixes), with random `ack` delays.
- Spike lockstep: all directed programs, the default and `ooo` random
  profiles (thousands of programs), plus a new random weight that puts
  divides on wrong paths (squashed mid-division) and back to back.
- Invariant checker: a busy divider holds a live, unfinished ROB entry.
- Regression, CI container (Icarus 12, Verilator 5.020), perf snapshot
  `M5.1 divider`, Vivado rerun.

## Step 2: pipelined multiplier

**Change.** Move multiplication into a pipelined unit (3 stages: operand
registers, DSP multiply with the DSP's internal `MREG`, `PREG` output
register), one multiply per cycle, same live-bit squash scheme as the FP
pipelines. Either one shared multiplier fed by both ALU issue ports or one
per ALU; start with one shared unit (multiplies are 2.9% of instructions).

**Expected.** Removes the DSP cascade from the one-cycle chain. What remains
is select → add/shift → arbitrate → bypass → capture: roughly **30-40 MHz**.

**IPC cost.** Multiply latency 1 → 3 cycles: up to 9,497 x 2 extra cycles on
FreeRTOS + CoreMark if every product were needed at once (≈ 7%); the
out-of-order window hides much of that, so expect **1-3%**.

**Verification.**
- Unit test: random and edge operands for `mul/mulh/mulhsu/mulhu` against a
  reference, with stalls and squashes injected.
- Spike lockstep (multiply-dense random weight), invariants (live-bit
  pipeline stages hold live, unfinished tags), regression, CI container, perf
  snapshot `M5.2 multiplier`, Vivado rerun.

## Step 3: split issue from execute (the main step)

This is the change that brings the cycle down to one stage of work.

**Changes.**

1. **Issue stage, then execute stage.** Select the oldest ready entry in one
   cycle and register it; execute it in the next. A register now separates
   "choose" from "compute".
2. **Speculative (tag-only) wake-up.** When a single-cycle ALU operation is
   selected, its destination tag is broadcast immediately as a wake-up (no
   value yet). Dependents become ready and can be selected in the very next
   cycle, so back-to-back dependent ALU operations still issue every cycle.
   Their operand comes from a **bypass network** off the ALU result
   registers. Because the ALUs have fixed latency and never stall (see 3),
   a speculatively woken consumer can never be left without its value, so
   no replay mechanism is needed.
3. **Dedicated result buses for the ALUs.** ALU 0 drives CDB 0 and ALU 1
   drives CDB 1 directly, with no arbitration, so an ALU result is never
   held back. The branch unit, LSU, FP units, integer divider and multiplier,
   and CSR reads arbitrate for the remaining bus(es). If that contention
   costs IPC, add a fourth CDB (measured with `perf_snapshot.py`).
4. **Age matrices instead of `tag - ROB head`.** Each reservation station
   keeps a small "older-than" bit matrix, filled when entries are inserted, so
   select and arbitration compare stored bits instead of subtracting the ROB
   head on every comparison. This takes the ROB head off the critical path.
5. **No same-cycle CDB → dispatch bypass.** Instead of forwarding a value
   broadcast in the dispatch cycle into the dispatching instruction (a long
   combinational path), a newly inserted entry also checks the previous
   cycle's broadcasts (a registered copy of the CDB tags), so the wake-up is
   never missed.

**Expected.** The longest path becomes one stage of work: wake-up and select
(tag compares, age-matrix lookup, select mux), or execute (bypass mux,
32-bit add/shift, result register). Roughly 10-15 logic levels: about
**70-100 MHz post-synthesis, 50-75 MHz after place and route**.

**IPC cost.** With speculative wake-up, back-to-back dependent ALU operations
keep single-cycle latency. Remaining costs:
- one more cycle from dispatch to the first execution of an instruction;
- one more cycle to resolve branches, so each mispredict costs one more cycle
  (about 4,700 mispredicts on FreeRTOS + CoreMark, ≈ +1.7%);
- load, FP, and branch results now share fewer buses.

Estimate: **3-8%**. Without speculative wake-up it would be up to about +50%
(the 54% back-to-back measurement), which is why it is part of this step.

**Verification.** This step changes the most timing-sensitive logic, so it
gets the most checking:
- New invariants: every executing operand that came from the bypass network
  matches the producer's actual result; no instruction executes before its
  producer; age matrices are consistent (exactly one order between any two
  live entries, matching ROB order).
- Spike lockstep: directed, thousands of default and `ooo` stress programs,
  and the shrunk-structure build (ROB 8, 2-entry stations), where the
  bypass and wake-up timing corners are hit constantly.
- A formal check where practical: the age-matrix selection proven equivalent
  to the current age-subtraction selection with a Yosys SAT miter (as was
  done for the CDB arbiter).
- Regression, CI container, perf snapshot `M5.3 issue/execute split` (IPC
  cost measured, not estimated), Vivado post-route timing.
- Possibly done in two halves (3a: issue register + speculative wake-up +
  dedicated ALU buses; 3b: age matrices + registered dispatch snoop) to keep
  each change reviewable.

## Step 4: cleanup

**Changes.**
- Register files write on the rising edge (now the falling edge, which gives
  those paths half a cycle), with write-to-read forwarding preserved.
- Whatever post-route timing shows next. Likely candidates: the fully
  associative cache tag compare (16-way L1, 32-way L2) and data select; the
  FP adder's normalize/round stage; the ROB head read muxes.
- If the caches limit the clock: register the tag match before the data
  select, or reduce associativity (e.g. 4-way set associative).

**Expected.** Closes the remaining margin to the target clock. IPC cost: about
0% for the register files; a cache change would be measured.

**Verification.** Same flow: lockstep, invariants, regression, CI container,
perf snapshot, Vivado.

## Summary

| Step | Change | Fmax estimate | IPC cost estimate (FreeRTOS + CoreMark) |
| --- | --- | --- | --- |
| Today | | 8 MHz (synthesis) | (IPC 1.207) |
| 0 | Post-route timing in the Vivado script | (measurement only) | 0 |
| 1 | Multi-cycle integer divider | ~20-25 MHz | ~0% |
| 2 | Pipelined multiplier | ~30-40 MHz | 1-3% |
| 3 | Issue/execute split, speculative wake-up, dedicated ALU buses, age matrices | ~50-75 MHz post-route | 3-8% |
| 4 | Rising-edge register files, then whatever timing shows | target 50+ MHz with margin | ~0% |

End state: IPC about **1.05-1.15** at **50-75 MHz**, about **55-85 MIPS**,
versus about **10 MIPS** today.

These Fmax numbers are estimates from logic depth; each step's Vivado run
replaces them with measurements, and the plan should be revised after each
step if the next bottleneck is not the one predicted.

## Process for every step

1. Implement the change.
2. Spike lockstep with the invariant checker: directed programs, default
   random profile, `ooo` stress profile, the shrunk-structure build.
3. Regression, unit tests, coverage, and the CI container (Icarus 12,
   Verilator 5.020).
4. `python3 tools/perf_snapshot.py --label "M5.x ..."` to record the IPC cost.
5. Vivado on the Windows laptop: `source tools/vivado/synth_core.tcl`
   (post-route once step 0 is in), push `reports/vivado/`, and compare the
   summary against the estimate.
6. Report before starting the next step.

## Results (October 2026)

All four steps are implemented. Each passed, before the next began: Spike
lockstep with the invariant checker (directed, default random, the `ooo`
stress profile, and the shrunk-structure build), the regression and unit
tests, coverage, and the CI container (Icarus 12, Verilator 5.020). In total
about 15,000 lockstep programs (about 12 million instructions) ran across the
four steps.

| Step | What was built | FreeRTOS + CoreMark cycles | IPC | Change |
| --- | --- | ---: | ---: | --- |
| Before | | 275,491 | 1.207 | |
| 1 + 2 | `IntDivider` (radix-2, ~35 cycles, killed on squash) and `IntMultiplier` (3 stages, live bits), each with its own 2-entry station; the ALU keeps only RV32I operations | 281,339 | 1.182 | +2.1% (estimate 1-3%) |
| 3 | ALU and branch execute registers (`alu_e`, `alu1_e`, `br_e`); each owns its CDB when executing and the arbiter fills the free buses; tag-only wake-up from ALU selects into the ALU, branch, and multiplier stations; stations wake entries on insertion, replacing the CDB-to-dispatch bypass | 300,374 | 1.107 | +6.8% (estimate 3-8%) |
| 4 | Register files write on the rising edge | 300,374 | 1.107 | 0% (estimate 0%) |

Other workloads after all four steps: `system_workload` 932 cycles (was 805),
`system_workload_benchmark` 1,040 (901), `rv32i_control` 916 (801),
`cache_stress` 4,263 (4,031), `fp_arith` 54,842 (51,620), and the
divide-heavy directed test `rv32im_alu` 14,504 (3,856). Every snapshot is in
`docs/PERFORMANCE.md` (`M5.1-2`, `M5.3`, `M5.4`).

Logic depth (Yosys proxy: generic 6-input LUT mapping, memory models
black-boxed, multiplies modeled as DSP slices, CSR counter adders excluded;
adders count one level per bit, so absolute values overstate FPGA depth):

| Version | Longest path (LUT levels) | Ends at |
| --- | ---: | --- |
| Before | 267 | ALU station (select, divide, arbitrate, broadcast, capture in one cycle) |
| After steps 1 + 2 | 50 | LSU output buffer |
| After step 3 | 44 | LSU output buffer (load address add, store-queue forwarding compare) |

Size (Yosys, Xilinx 7-series): 90,742 → 83,859 LUTs, 25,367 → 27,114
flip-flops, 13 → 6 DSP slices.

Not done in this pass:
- ~~Caches still update on the falling edge~~: done after the first Vivado
  run; see "Second Vivado run" below.
- **Age matrices** (step 3, item 4): the ROB-head age subtraction is a 4-bit
  operation per entry and is no longer on a chain with execution, so it was
  left as is; revisit only if Vivado reports select as critical.
- **A larger ROB**: ROB-full stalls rose from about 9k to 21k cycles on
  FreeRTOS + CoreMark because instructions now stay in flight one cycle
  longer; a 32-entry ROB would likely recover part of the 6.8%.

### First Vivado run after the four steps

Vivado synthesis (before place and route) of the step-4 design reported a
worst setup slack of **-17.1 ns** at 50 MHz (37.0 ns path, 47 logic levels,
about 27 MHz), down from -101.7 ns (8 MHz). The worst path had moved to
instruction selection:

```text
ROB head ─► ALU station: pick the oldest ready entry, then the second-oldest
         ─► speculative wake-up tag ─► "ready" bit of a waiting entry
```

Selection was written as a serial "oldest so far" loop over the 8 entries,
which synthesizes into a chain of compare-and-update stages, and the second
issue port ran a second chain after the first. It is now parallel: each
entry's age is computed once, its rank is the number of older candidates
(ties to the lower index), and the ports take ranks 0 and 1. This is step 3's
age item, done with parallel age compares instead of a stored age matrix.

Verification: a Yosys sequential equivalence proof (`equiv_make`,
`equiv_simple`, `equiv_induct`) shows the new and old stations produce
identical outputs in every cycle from reset, for the 8-entry two-port
station with speculative wake-up, the 8-entry in-order memory queue, and a
2-entry station (3,860 of 3,860 equivalence points proven in each 8-entry
configuration). Spike lockstep (directed, 1,500 random, 800 stress, and the
shrunk build), the CI container, and identical cycle counts on all seven
workloads confirm it.

### Second Vivado run: rising-edge caches and memory

With parallel selection, Vivado synthesis reported **-9.40 ns** at 50 MHz,
but the worst path was no longer in the core:

```text
store buffer head (rising edge) ─► L2 tag compare ─► replacement-tree update
                                   (falling edge: only 10 ns of the 20 ns cycle)
```

All ten listed paths were copies of it (25 logic levels, 19.35 ns). A full
cycle would have just met timing, so the fix was to remove the falling edge:

- **Caches on the rising edge.** `cache_tags`, the L1 I-cache and D-cache,
  and the L2 now update on the rising edge. A refill writes its last beat at
  the end of the stalled cycle, so lines still become visible in the same
  cycle as before.
- **Memory model, imem and MMIO on the rising edge.** Memory read data now
  arrives one full cycle after the request, which is the cycle the D-cache
  refill and uncached-load handshakes already sampled it in. The atomic
  commit record is registered one cycle later; the reservation it sets or
  clears is not needed until the atomic retires, several cycles later.
- **Prefetch HPM events** no longer need a falling-edge capture register.

The second fix was to find the core's own worst full-cycle path, which the
cache path had hidden. The Yosys depth proxy now registers the memory
ports, because a black box let paths run straight through the memory model.
It found three paths, each fixed without an IPC cost:

| Depth (LUT levels) | Path | Fix |
| ---: | --- | --- |
| 50 | ALU result ─► store-forward event ─► 64-bit HPM counter add | HPM events are registered before the counters (counted one cycle late; lockstep excludes counters) |
| 41 | CDB value ─► memory-queue operand ─► address add ─► store-queue forward ─► LSU output | The station's CDB-value mux exists only with `SPEC_WAKE`; the memory queue never sets the speculative bits, but synthesis could not prove it |
| — | load tag lookup ─► `drain_issue` ─► L2 replacement update | `drain_issue` dropped two terms that need an empty store buffer while a drain needs a non-empty one |
| **24** | ALU execute register ─► ALU station wake-up | (current worst) |

Verification on the final RTL: 23/23 regression; Spike lockstep with 1,514
directed + random programs, 800 out-of-order stress programs, and the
shrunk-structure build (14 directed + 500 random), all matching; the CI
container; the cache-tags unit test (its stimulus now changes between clock
edges). Cycle counts: FreeRTOS + CoreMark 300,367 → 300,393 (+0.01%), every
other workload within 2 cycles (snapshot "M5.5").

The Vivado script also reports more now. `summary.txt` is written after
synthesis and again after place and route, so a run stopped early still
leaves current numbers. `path_groups.txt` lists the worst path for each pair
of start and end modules, so one slow block can no longer fill the whole
top-10 list.

### Third Vivado run: first post-route result

The memory stand-ins used to be empty black boxes, which synthesis accepts
but `opt_design` rejects (DRC INBB-3), so no earlier run reached place and
route. They now register their ports like a block RAM (`memory_stubs.sv`).

First post-route numbers (Artix-7 200T, out of context): 51,069 LUTs, 35,529
flip-flops, 6 DSP slices, worst setup slack **-6.38 ns** at 50 MHz, so
**37.9 MHz** (from 8.2 MHz at the start of this plan). Routing is 64% of the
worst path's delay. The failing groups and their fixes:

| Slack (ns) | Path | Fix | Cost |
| ---: | --- | --- | --- |
| -6.38 | FP multiplier product register ─► normalize and round (four carry chains) ─► CDB ─► every station | Rounding gets its own pipeline register (S3); the core tracks a third tag/live stage | fadd/fmul latency 2 → 3 |
| -6.13 | FP divider quotient ─► round ─► CDB | New ROUND state registers the result | fdiv +1 cycle |
| -5.27 | store-buffer head ─► forwarding compare ─► D-cache FSM `busy` ─► `drained` ─► fence commit ─► redirect, GHR, every station | `busy` is the refill and uncached-read registers only; its other terms need a load in flight, which `drained` already excludes | none |
| -5.11 | PC ─► I-cache ─► slot 0 length ─► PC+2/+4 ─► BHT/BTB lookup ─► next PC | Both slot-1 PCs and their predictor lookups are computed in parallel; the length only selects | one extra BHT/BTB read port |
| -4.58 | ROB head ─► LSU output buffer | not yet: the next run's detail report will show the path | |

Verification: 23/23 regression; the FP unit test; Spike lockstep with 1,514
directed + random programs, 800 out-of-order stress programs, and the
shrunk-structure build (14 + 500), all matching; the CI container. Cycle
counts: `fp_arith` 54,842 → 55,497 (+1.2%); every other workload unchanged
(snapshot "M5.6").

`synth_core.tcl` now also writes `path_groups_detail.txt`, the full
cell-by-cell report of the worst path in each of the first 40 module pairs.

**Next:** rerun `source tools/vivado/synth_core.tcl` on the Windows machine
to measure these fixes and see the remaining groups in detail.
