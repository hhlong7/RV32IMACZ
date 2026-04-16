.eqv SSEG 0x11000040
.eqv PATCH_INSN 0x00100493

.text
.globl main

main:
    li s0, SSEG
    li s1, 0

    la t0, patch_site
    li t1, PATCH_INSN
    sw t1, 0(t0)
    fence.i

patch_site:
    nop

    li t2, 1
    bne s1, t2, fail_701

pass:
    li t0, 118
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
