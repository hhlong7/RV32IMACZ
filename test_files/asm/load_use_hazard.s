.eqv SSEG 0x11000040

.data
value0:
    .word 21
value1:
    .word 123

.text
.globl main

main:
    li s0, SSEG

    la t0, value0
    lw t1, 0(t0)
    add t2, t1, t1
    li t3, 42
    bne t2, t3, fail_651

    la t0, value1
    lw a0, 0(t0)
    li a1, 123
    beq a0, a1, load_branch_ok
    j fail_652

load_branch_ok:
    lw a2, 0(t0)
    addi a3, a2, -23
    li a4, 100
    bne a3, a4, fail_653

pass:
    li t0, 114
    sw t0, 0(s0)

pass_loop:
    j pass_loop

fail:
    li t0, -1
    sw t0, 0(s0)

fail_loop:
    j fail_loop

fail_651:
    li t0, 651
    sw t0, 0(s0)
    j fail_loop

fail_652:
    li t0, 652
    sw t0, 0(s0)
    j fail_loop

fail_653:
    li t0, 653
    sw t0, 0(s0)
    j fail_loop
