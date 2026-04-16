.eqv SSEG 0x11000040

.text
.globl main

main:
    li s0, SSEG

    addi t0, x0, 5
    addi t1, t0, 7
    add t2, t1, t0
    li t3, 17
    bne t2, t3, fail_641

    addi t4, t2, 3
    sub t5, t4, t1
    li t6, 8
    bne t5, t6, fail_642

    addi a0, x0, 9
    addi a1, a0, 1
    li a2, 10
    beq a1, a2, branch_forward_ok
    j fail_643

branch_forward_ok:
    auipc a3, 0
    addi a4, a3, 4
    add a5, a4, x0
    bne a5, a4, fail_644

pass:
    li t0, 113
    sw t0, 0(s0)

pass_loop:
    j pass_loop

fail:
    li t0, -1
    sw t0, 0(s0)

fail_loop:
    j fail_loop

fail_641:
    li t0, 641
    sw t0, 0(s0)
    j fail_loop

fail_642:
    li t0, 642
    sw t0, 0(s0)
    j fail_loop

fail_643:
    li t0, 643
    sw t0, 0(s0)
    j fail_loop

fail_644:
    li t0, 644
    sw t0, 0(s0)
    j fail_loop
