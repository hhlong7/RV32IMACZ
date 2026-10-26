# Plan: JTAG Host Bridge and Matrix-Multiply Accelerator (Zybo Z7-20)

Status: step 1 (host bridge) is implemented and verified in simulation
(`board/host_bridge.sv`, `tools/vivado/host.tcl`, `tools/run_board_test.sh
host`); the first board build is next. Step 2 (accelerator) has not started.
Differences from the plan below: the core is not held at power-up (the
bitstream's built-in program still runs), the bridge also reads memory back
(LOAD_DATA reads), console reads return up to three bytes, the console only
makes the core wait while the laptop is attached, and `host=0` builds the
design without the bridge.

Two additions to the board design, in this order:

1. **Host bridge over JTAG** (step 1). From the Vivado Tcl console on the
   laptop, over the board's existing USB cable (J12): hold the OTTER core in
   reset, load a program into its memory, start it, read what it printed,
   and read a cycle count. No bitstream rebuild per program and no
   USB-serial adapter.
2. **Matrix-multiply accelerator** (step 2). An engine on the DSP slices that
   the OTTER core drives through memory-mapped registers, measured on the
   board against the same multiply in plain RISC-V code.

The bridge comes first because it is how the accelerator's test programs get
loaded and how their results and cycle counts get back to the laptop.

Neither step changes the core's pipeline. Step 1 adds a load port to the
core's memory (used only while the core is held in reset); step 2 is a
board-level peripheral on the existing IO bus. Spike lockstep, the
regression, and the seven workloads' cycle counts must stay unchanged, and
are checked at the end of each step.

## Step 1: host bridge over JTAG

### Pieces

| Piece | File | What |
| --- | --- | --- |
| JTAG-to-AXI master | Vivado IP `jtag_axi`, created by the build script | lets Vivado's Hardware Manager issue AXI reads and writes in the design |
| AXI master wrapper | `board/host_axi_master.sv` | the IP in synthesis; in simulation a testbench model with `write(addr, data)` / `read(addr)` tasks, so the same top runs in Icarus |
| Host bridge | `board/host_bridge.sv` | AXI4-Lite slave with the registers below |
| Console FIFOs | in `host_bridge` | 4 KB from the core to the host, 64 bytes from the host to the core |
| Core load port | `otter_mcu_ooo.sv` (new `LOAD_*` ports) | writes a word into the data memory and, through the existing store snoop, both instruction-memory copies; only while RESET is held |
| Board top | `board/zybo/zybo_top.sv` | wires the bridge, adds the console to the UART registers |
| Laptop commands | `tools/vivado/host.tcl` | `otter_load`, `otter_run`, `otter_stop`, `otter_console`, `otter_cycles` |

### Bridge registers (AXI4-Lite, word access)

| Offset | Register | Meaning |
| --- | --- | --- |
| `0x00` | CONTROL | bit 0: hold the core in reset (1 at power-up, so the core waits for a program) |
| `0x04` | STATUS | bit 0: core running; bit 1: console has output; bit 2: console input has room |
| `0x08` | LOAD_ADDR | byte address of the next loaded word |
| `0x0C` | LOAD_DATA | write: store this word at LOAD_ADDR, then LOAD_ADDR += 4 (only while held in reset) |
| `0x10` | CONSOLE_OUT | read: `[8]` valid, `[7:0]` the oldest byte the core printed (the read removes it) |
| `0x14` | CONSOLE_IN | write: one byte for the core to read |
| `0x18`, `0x1C` | CYCLES_LO/HI | core clock cycles since the reset was last released |

BTN0 still resets the core; with CONTROL bit 0 clear it then restarts the
loaded program.

### Console

The core's existing UART registers (`0x11000080`, `0x11000084`) get a
second backend:

- A byte the core sends goes to the Pmod UART (as now) **and** into the
  4 KB console FIFO. "Ready to send" also requires room in the FIFO, so a
  long report waits for the host instead of being lost (4 KB holds the whole
  CoreMark report).
- A byte the host writes to CONSOLE_IN shows up as a received byte, exactly
  as if it came in on the Pmod UART.

So existing programs (the echo demo, CoreMark) print to the laptop with no
software change.

### Program loading

`otter_load file.mem` holds the core in reset and writes the image word by
word through LOAD_DATA, stopping after the last nonzero word (the startup
code clears `.bss`). Each JTAG transaction takes on the order of a
millisecond, so CoreMark (about 4,200 words) loads in roughly 5-15 seconds,
versus a 30-60 minute rebuild today. If that proves too slow, AXI4 bursts
are a later optimization.

### Verification

- `host_bridge` unit testbench: register reads and writes, load
  auto-increment, the console FIFOs at full and empty, reset control.
- Board-level simulation (`tools/run_board_test.sh host`): the AXI model
  loads the echo demo into a core held in reset (the memories start with a
  different program), releases it, reads the banner from CONSOLE_OUT, types
  through CONSOLE_IN, and checks the echo.
- Unchanged core: Spike lockstep (directed, 1,500 random, 800 stress, the
  shrunk build), the 23-test regression, the CI container, and identical
  cycle counts on all seven workloads.
- Board: build, then `otter_load coremark.mem` / `otter_run` /
  `otter_console`, which should finally show the CoreMark score from the
  hardware.

## Step 2: matrix-multiply accelerator

### What it computes

C = A x B for N x N matrices, N from 1 to 32, int16 inputs and int32
results (exact, no overflow for any int16 inputs at N = 32).

### Pieces

| Piece | File | What |
| --- | --- | --- |
| Engine | `board/matmul_accel.sv` | buffers, 8 multiply-accumulate lanes, control |
| Board top | `board/zybo/zybo_top.sv` | maps it at `0x12000000` on the IO bus |
| Test program | `software/zybo_matmul/` | software multiply vs the engine, results, cycle counts |
| Unit testbench | `board/tb_matmul_accel.sv` | random matrices of every size against a reference |

### Memory map (`0x12000000`, uncached IO, so the D-cache never holds stale results)

| Offset | Contents |
| --- | --- |
| `0x0000`-`0x07FF` | A, row-major, two int16 per word (write) |
| `0x0800`-`0x0FFF` | B, row-major, two int16 per word (write) |
| `0x1000`-`0x1FFF` | C, row-major, one int32 per word (read) |
| `0x2000` | N |
| `0x2004` | START (write 1) |
| `0x2008` | STATUS: bit 0 busy, bit 1 done |
| `0x200C` | cycles the last run took |

### How it computes

- Eight lanes, each one DSP48 slice (16 x 16 multiply into a 32-bit
  accumulator), compute eight neighboring results of one row at once:
  C[i][j..j+7] += A[i][k] * B[k][j..j+7] for k = 0..N-1.
- B is stored as 8 values per memory row so one read feeds all eight lanes;
  A is read one value per cycle. Both are block RAM.
- A 32 x 32 product is 32 x 4 x 32 = 4,096 cycles of compute, plus a short
  pipeline drain per row group.

### Expected numbers (to be measured)

- Software, 32 x 32 on this core: about 32,768 multiply-accumulates at
  roughly 4-5 cycles each (load, load, multiply, add, loop), so about
  150,000 cycles.
- Engine: about 4,100 cycles of compute, plus moving A and B in (1,024
  stores) and C out (1,024 IO loads, a few cycles each): roughly 6,000-9,000
  cycles in all, so about 15-25 times faster. Data movement through the IO
  bus, not the arithmetic, will dominate; the program reports both parts
  separately.

### Test program (`software/zybo_matmul`)

For N = 8, 16, and 32: fill A and B from a fixed pseudo-random sequence,
multiply in software (timed with `mcycle`), then with the engine (timing
the transfers and the compute separately), compare every element, and
print the cycle counts and the speedup to the console. LEDs: green when
every result matches, red when any differs (with the console naming the
first mismatch).

### Verification

- Unit testbench: random A and B for every N from 1 to 32, edge values
  (-32768, 32767), back-to-back runs, START while busy ignored, against a
  reference model.
- Board-level simulation of the test program (N = 8 and 16, to keep the
  simulation short) with the bridge loading it.
- Unchanged core checks as in step 1.
- Board: load and run with `otter_load` / `otter_run` / `otter_console`.

## Resources and timing

The design uses 79% of the LUTs today. Expected additions: JTAG-to-AXI and
the debug hub about 1,500-2,500 LUTs, the bridge and console about 300 LUTs
and one block RAM, the engine about 800-1,200 LUTs, 8 DSP slices, and 4-6
block RAMs. That is about 83-85% of the LUTs, still within the device, but
fuller devices are harder to place, and timing at 35.7 MHz has almost no
margin. If a build misses, the fallback is 34.1 MHz (750 / 22) with no
other change; the new blocks themselves are all registered at their
boundaries and are not expected to be the critical paths.

## Order of work

1. Step 1: load port, `host_bridge`, console, `host_axi_master` (IP and
   simulation model), `host.tcl`, tests; you build and try it on the board.
2. Step 2: engine, test program, tests; you build and measure on the board.

Each step ends with the full checks and a report before the next starts.
