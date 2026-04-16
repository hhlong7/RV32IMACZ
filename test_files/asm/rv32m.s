.eqv SSEG 0x11000040

.text
.globl main

main:
    li s0, SSEG

    li t0, 7
    li t1, -3
    mul t2, t0, t1
    li t3, -21
    bne t2, t3, fail

    li t0, 0x40000000
    li t1, 4
    mulh t2, t0, t1
    li t3, 1
    bne t2, t3, fail

    li t0, -2
    li t1, 0x80000000
    mulhsu t2, t0, t1
    li t3, -1
    bne t2, t3, fail

    li t0, -1
    li t1, -1
    mulhu t2, t0, t1
    li t3, -2
    bne t2, t3, fail

    li t0, -7
    li t1, 3
    div t2, t0, t1
    li t3, -2
    bne t2, t3, fail

    li t0, 7
    li t1, 3
    divu t2, t0, t1
    li t3, 2
    bne t2, t3, fail

    li t0, -7
    li t1, 3
    rem t2, t0, t1
    li t3, -1
    bne t2, t3, fail

    li t0, 7
    li t1, 3
    remu t2, t0, t1
    li t3, 1
    bne t2, t3, fail

    li t0, 123
    li t1, 0
    div t2, t0, t1
    li t3, -1
    bne t2, t3, fail

    li t0, 123
    li t1, 0
    rem t2, t0, t1
    li t3, 123
    bne t2, t3, fail

pass:
    li t0, 101
    sw t0, 0(s0)

pass_loop:
    j pass_loop

fail:
    li t0, -1
    sw t0, 0(s0)

fail_loop:
    j fail_loop
