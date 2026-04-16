.eqv LEDS 0x11000020
.eqv SSEG 0x11000040

.text
.globl main

main:
    li s0, SSEG
    li s1, LEDS

    csrrs t0, 0xB10, x0           # D-cache/MMIO drain counter baseline

    li t2, 0x13579BDF
    sw t2, 0(s1)                  # buffered MMIO store

    # MMIO loads must not forward buffered store data. The testbench drives
    # IOBUS_IN low, so the architecturally correct result is still zero.
    lw t3, 0(s1)
    bne t3, x0, fail_701

    fence.i

    csrrs t4, 0xB10, x0
    sub t4, t4, t0
    beq t4, x0, fail_702

pass:
    li t0, 121
    sw t0, 0(s0)

pass_loop:
    j pass_loop

fail:
    li t0, -1
    sw t0, 0(s0)

fail_loop:
    j fail_loop

fail_701:
    li t0, 701
    sw t0, 0(s0)
    j fail_loop

fail_702:
    li t0, 702
    sw t0, 0(s0)
    j fail_loop
