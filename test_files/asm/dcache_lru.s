.eqv SSEG 0x11000040

.data
    .align 2
data_a:
    .word 1
    .space 252
data_b:
    .word 2
    .space 252
data_c:
    .word 3

.text
.globl main

main:
    li s0, SSEG

    la t0, data_a
    lw t1, 0(t0)
    li t2, 1
    bne t1, t2, fail_401

    la t0, data_b
    lw t1, 0(t0)
    li t2, 2
    bne t1, t2, fail_402

    la t0, data_a
    lw t1, 0(t0)
    li t2, 1
    bne t1, t2, fail_403

    la t0, data_c
    lw t1, 0(t0)
    li t2, 3
    bne t1, t2, fail_404

    la t0, data_a
    lw t1, 0(t0)
    li t2, 1
    bne t1, t2, fail_405

pass:
    li t0, 107
    sw t0, 0(s0)

pass_loop:
    j pass_loop

fail:
    li t0, -1
    sw t0, 0(s0)

fail_loop:
    j fail_loop

fail_401:
    li t0, 401
    sw t0, 0(s0)
    j fail_loop

fail_402:
    li t0, 402
    sw t0, 0(s0)
    j fail_loop

fail_403:
    li t0, 403
    sw t0, 0(s0)
    j fail_loop

fail_404:
    li t0, 404
    sw t0, 0(s0)
    j fail_loop

fail_405:
    li t0, 405
    sw t0, 0(s0)
    j fail_loop
