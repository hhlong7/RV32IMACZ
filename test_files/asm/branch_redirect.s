.eqv SSEG 0x11000040

.text
.globl main

main:
    li s0, SSEG
    li s1, 0

    beq x0, x0, target
    li s1, 99

target:
    bne s1, x0, fail

pass:
    li t0, 104
    sw t0, 0(s0)

pass_loop:
    j pass_loop

fail:
    li t0, -1
    sw t0, 0(s0)

fail_loop:
    j fail_loop
