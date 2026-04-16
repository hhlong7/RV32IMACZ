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

    csrrs s1, 0xB06, x0

    la t0, data_a
    lw t1, 0(t0)
    la t0, data_b
    lw t1, 0(t0)
    la t0, data_a
    lw t1, 0(t0)
    la t0, data_c
    lw t1, 0(t0)
    la t0, data_a
    lw t1, 0(t0)

    addi t2, x0, 1
    addi t2, t2, 1
    addi t2, t2, 1
    addi t2, t2, 1
    addi t2, t2, 1
    addi t2, t2, 1
    addi t2, t2, 1
    addi t2, t2, 1
    addi t2, t2, 1
    addi t2, t2, 1
    addi t2, t2, 1
    addi t2, t2, 1
    addi t2, t2, 1
    addi t2, t2, 1
    addi t2, t2, 1
    addi t2, t2, 1

    csrrs s3, 0xB06, x0

    sub s3, s3, s1
    li t3, 3
    bne s3, t3, fail_661

pass:
    li t0, 115
    sw t0, 0(s0)

pass_loop:
    j pass_loop

fail:
    li t0, -1
    sw t0, 0(s0)

fail_loop:
    j fail_loop

fail_661:
    li t0, 661
    sw t0, 0(s0)
    j fail_loop
