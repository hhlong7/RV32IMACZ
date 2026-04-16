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
    bne t2, t3, fail_301

    addi t4, x0, 5
    addi t5, t4, 7
    add t6, t5, t4
    li t3, 17
    bne t6, t3, fail_302

    addi a0, x0, 9
    addi a1, a0, 1
    li a2, 10
    beq a1, a2, branch_forward_ok
    j fail_303

branch_forward_ok:
    la t0, value1
    lw a3, 0(t0)
    li a4, 123
    beq a3, a4, pass
    j fail_304

pass:
    li t0, 103
    sw t0, 0(s0)

pass_loop:
    j pass_loop

fail:
    li t0, -1
    sw t0, 0(s0)

fail_loop:
    j fail_loop

fail_301:
    li t0, 301
    sw t0, 0(s0)
    j fail_loop

fail_302:
    li t0, 302
    sw t0, 0(s0)
    j fail_loop

fail_303:
    li t0, 303
    sw t0, 0(s0)
    j fail_loop

fail_304:
    li t0, 304
    sw t0, 0(s0)
    j fail_loop
