# Running the core on a Zybo Z7-20

The out-of-order OTTER core runs in the programmable logic of the Zybo
Z7-20 (Zynq-7020, `xc7z020clg400-1`). The ARM processing system is not used.

| Piece | File |
| --- | --- |
| Board top: clock, reset, LEDs, switches, buttons, UART | `board/zybo/zybo_top.sv` |
| Pin constraints (from Digilent's master file) | `board/zybo/zybo.xdc` |
| Serial port, 115200 8N1, 16-byte receive queue | `board/uart.sv` |
| Demo program (source) | `software/zybo_hello/main.c` |
| Demo program (memory image the build loads) | `board/zybo/zybo_hello.mem` |
| FreeRTOS + CoreMark for the board | `board/zybo/coremark.mem` (`make zybo` in `software/freertos_coremark`) |
| Build to bitstream | `tools/vivado/build_zybo.tcl` |
| Load the bitstream onto the board | `tools/vivado/program_zybo.tcl` |
| Board-level simulation | `tools/run_board_test.sh` (`board/zybo/tb_zybo.sv`) |

## What runs

- Core clock: **35.7 MHz**, from the board's 125 MHz oscillator through an
  MMCM (6 x 125 MHz = 750 MHz, / 21). At 37.5 MHz (/ 20) post-route timing
  missed by 0.1 ns on the fetch loop, and CoreMark failed its self-check on
  the board; / 21 leaves about 1.2 ns of margin (see
  [TIMING_CLOSURE_PLAN.md](TIMING_CLOSURE_PLAN.md) for the fetch loop).
- Memory: 64 KB in block RAM, loaded with the program when the bitstream is
  built. Instructions come from two 8-bank copies (the I-cache refill and the
  next-line prefetch each read a whole 32-byte line per cycle); data from a
  third, byte-writable copy. Data stores are mirrored into the instruction
  copies, so self-modifying code works after `fence.i`.
- Reset: **BTN0**.

## Memory map

| Address | Access | Device |
| --- | --- | --- |
| `0x0000_0000`-`0x0000_FFFF` | read/write | RAM (program and data) |
| `0x0200_4000`, `0x0200_BFF8` | read/write | CLINT `mtimecmp`, `mtime` (timer interrupt) |
| `0x1100_0000` | read | `[3:0]` SW3..SW0, `[6:4]` BTN3..BTN1 |
| `0x1100_0020` | write | `[3:0]` LD3..LD0, `[6:4]` LD5 red/green/blue, `[9:7]` LD6 red/green/blue |
| `0x1100_0040` | write | seven-segment register of the test programs (no display on the Zybo) |
| `0x1100_0080` | write | UART: send byte `[7:0]` (only when ready) |
| `0x1100_0080` | read | UART: oldest received byte |
| `0x1100_0084` | read | UART status: `[0]` ready to send, `[1]` byte waiting, `[2]` a byte was lost |
| `0x1100_0084` | write | UART: remove the oldest received byte (and clear `[2]`) |

IO reads have no side effects: the core may issue a load before it knows the
load will execute (after a branch it predicted) and then discard it, so
removing a received byte takes an explicit write.

## Serial terminal

The Zybo's own USB-UART is wired to the ARM side, so the core's UART is on
**Pmod JE** (labelled JE on the board):

- **Digilent PmodUSBUART:** plug it into the top row of JE.
- **3.3 V USB-serial cable** (FTDI TTL-232R-3V3 or similar; never 5 V):
  the cable's **RX to JE2**, its **TX to JE3**, **GND to JE5**.

Open the serial port at **115200 baud, 8 data bits, no parity, 1 stop bit**,
no flow control (PuTTY, Tera Term, `screen /dev/tty.usbserial-* 115200`).

If LD5 is green but the terminal stays empty, the transmit and receive lines
are probably crossed for your adapter: swap the two pins (`W16`, `J15`) of
`uart_tx` and `uart_rx` in `board/zybo/zybo.xdc` and rebuild, or swap the
wires.

## Build and program

On the Vivado machine, from the repository:

1. Set the Zybo's boot-mode jumper **JP5 to JTAG**, connect the PROG/UART
   micro-USB (J12), and power the board on.
2. In the Vivado Tcl Console:

   ```text
   cd C:/Users/hhlon/Documents/RV32IMACZ
   source tools/vivado/build_zybo.tcl
   ```

   This takes a while (synthesis, place and route, bitstream). It ends with a
   summary and `Bitstream: .../build/zybo/zybo_top.bit`.
3. Then:

   ```text
   source tools/vivado/program_zybo.tcl
   ```

LD5 turns green, LD6 blinks blue (on half a second, off half a second), and
the terminal shows:

```text
OTTER RV32IMAC out-of-order core on a Zybo Z7-20
Type to echo; 'i' prints the cycle and instruction counters.
>
```

Typed characters echo back, the switches show on LD3..LD0 (and are reported
when they change), and `i` prints the `mcycle` and `minstret` counters.
BTN0 restarts the program. The design is lost at power-off; program it again.

## Using a saved Vivado project (GUI)

Instead of running `build_zybo.tcl` every time, create a Vivado project once
and then work in the GUI. The project keeps every run's results, so after a
change Vivado re-runs only what that change affects.

**Once**, in the Vivado Tcl Console:

```text
cd C:/Users/hhlon/Documents/RV32IMACZ
set program coremark.mem
source tools/vivado/create_project.tcl
```

(Leave out `set program` for the echo demo.) This creates
`vivado/otter_core/otter_core.xpr` (ignored by git) with the board design,
the pin constraints, and the program in the memories, and opens it.

**Every time after that:**

1. Open Vivado, then **File > Project > Open** (or the Recent Projects list)
   and pick `vivado/otter_core/otter_core.xpr`.
2. In the Flow Navigator on the left: **Run Synthesis**, then **Run
   Implementation**, then **Generate Bitstream** (clicking Generate Bitstream
   alone runs whatever earlier steps are out of date).
3. **Open Hardware Manager > Open Target > Auto Connect**, then **Program
   Device**; the bitstream path is filled in
   (`vivado/otter_core/otter_core.runs/impl_1/zybo_top.bit`).

After pulling new RTL from git, the project sees the changed files and marks
synthesis out of date; clicking Generate Bitstream rebuilds everything that
needs it. To switch programs, run `create_project.tcl` again with the new
`set program` (it replaces the project).

Check **Timing** in the Project Summary after implementation: the design
meets 35.7 MHz with almost no margin, so a different placement can miss it by
a little. If it does, run implementation again or use `build_zybo.tcl`,
which met it.

## Running CoreMark on the board

`board/zybo/coremark.mem` is the FreeRTOS + CoreMark program built for the
board (`make zybo` in `software/freertos_coremark`). CoreMark calibrates
itself to a valid timed run of at least 10 seconds. Build the bitstream with it:

```text
set program C:/Users/hhlon/Documents/RV32IMACZ/board/zybo/coremark.mem
source tools/vivado/build_zybo.tcl
source tools/vivado/program_zybo.tcl
```

| LEDs | Meaning |
| --- | --- |
| LD6 solid blue | CoreMark is running (about 30 seconds: 10 of calibration, then the timed run) |
| Everything blinking (LD0-LD3, LD5 and LD6 green) | finished, and CoreMark validated its results |
| LD5 and LD6 blinking **red**, LD0-LD3 steady | finished, but CoreMark reported errors; LD0-LD3 say which (below) |

When it fails, the steady LD0-LD3 pattern stands in for CoreMark's report:

| LED on | CoreMark reported |
| --- | --- |
| LD0 | a CRC check failed: the benchmark computed wrong results |
| LD1 | the timed run was shorter than 10 seconds |
| LD2 | a data-type size check failed |
| LD3 | "Correct operation validated" (printed anyway) |

With a terminal connected, CoreMark's full report appears, followed by the
score (`CoreMark/MHz`, iterations per second at 35.7 MHz). BTN0 runs it
again. Vivado keeps `program` set for the rest of the session; `unset
program` (or restarting Vivado) returns to the demo.

`tools/run_board_test.sh coremark` simulates this on the board top with a
pretend 20 kHz clock, so the 10-second run fits in a short simulation.

## Running another program

Build a memory image (64 KB, one 32-bit hex word per line, little-endian
words, code at address 0) and pass it to the build:

```text
set program C:/path/to/image.mem
source tools/vivado/build_zybo.tcl
```

`software/zybo_hello` shows the toolchain setup (`make` there rebuilds
`board/zybo/zybo_hello.mem`); the startup code and linker script are shared
with `software/freertos_coremark`.

## Checking it without the board

`tools/run_board_test.sh` simulates `zybo_top` running the demo with a
terminal model (the UART at 16 clocks per bit): it waits for the banner,
types characters and `i`, flips switches, and checks the echo, the counters,
and the LEDs. It is part of `tools/run_verification_quality.sh` (CI).
