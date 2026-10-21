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
    .align 5
# 24 32-byte lines: more than the 16-line L1 D-cache, fewer than the 32-line
# L2, so re-reading the first line after the sweep is an L2 hit.
sweep:
    .space 768

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

    # Tag each sweep line with its index, then read all 24 lines back so the
    # first lines are evicted from L1 and must come from L2.
    la t0, sweep
    li t1, 0
    li t3, 24
tag_lines:
    slli t2, t1, 5
    add t2, t2, t0
    sw t1, 0(t2)
    addi t1, t1, 1
    bne t1, t3, tag_lines
    fence
    li t1, 0
sweep_lines:
    slli t2, t1, 5
    add t2, t2, t0
    lw t4, 0(t2)
    bne t4, t1, fail_705
    addi t1, t1, 1
    bne t1, t3, sweep_lines
    lw t4, 0(t0)                 # line 0 again: L1 miss, L2 hit
    bne t4, x0, fail_705
    lw t4, 32(t0)
    li t2, 1
    bne t4, t2, fail_705

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

fail_705:
    li t0, 705
    sw t0, 0(s0)
    j fail_loop
