.eqv SSEG 0x11000040

.data
    .align 2
data_a:
    .word 1
    .space 508
data_b:
    .word 2
    .space 508
data_c:
    .word 3

.text
.globl main

main:
    li s0, SSEG

    la t0, data_a
    lw t1, 0(t0)
    li t2, 1
    bne t1, t2, fail_701

    la t0, data_b
    lw t1, 0(t0)
    li t2, 2
    bne t1, t2, fail_702

    la t0, data_c
    lw t1, 0(t0)
    li t2, 3
    bne t1, t2, fail_703

    la t0, data_a
    li t1, 9
    sw t1, 0(t0)

    fence

    lw t1, 0(t0)
    li t2, 9
    bne t1, t2, fail_704

pass:
    li t0, 125
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

fail_703:
    li t0, 703
    sw t0, 0(s0)
    j fail_loop

fail_704:
    li t0, 704
    sw t0, 0(s0)
    j fail_loop