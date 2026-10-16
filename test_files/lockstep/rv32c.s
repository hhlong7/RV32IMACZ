# RV32C: every compressed instruction with minimum, maximum and sign-edge
# immediates, mixed 16/32-bit streams, and compressed control flow.
.include "harness.inc"

LOCKSTEP_START
    la s1, cbuf               # x9: compressed load/store base
    la sp, cbuf + 256         # x2: stack-relative base
    li s0, 0x12345678
    li a0, 0x0f0f0f0f
    li a1, -7
    li a2, 0x80000000
    li a3, 3
    li a4, -1
    li a5, 0x7fffffff

    # Quadrant 0: c.addi4spn (min/max), c.lw / c.sw (min/max offsets).
    c.addi4spn a0, sp, 4
    c.addi4spn a1, sp, 1020
    c.sw s0, 0(s1)
    c.sw a5, 124(s1)
    c.lw a2, 0(s1)
    c.lw a3, 124(s1)

    # Quadrant 1: immediates at both sign extremes.
    c.nop
    c.addi a4, 1
    c.addi a4, -32
    c.addi a4, 31
    c.li a5, -32
    c.li a5, 31
    c.li a5, 0
    c.lui a0, 1
    c.lui a0, 0x1f
    c.lui a0, 0xfffe0         # largest negative nzimm
    c.lui a0, 0xfffff
    c.addi16sp sp, -512
    c.addi16sp sp, 496
    c.addi16sp sp, 16
    li a1, 0x80000001
    mv s0, a1
    c.srli s0, 1
    c.srli s0, 31
    mv s0, a1
    c.srai s0, 1
    c.srai s0, 31
    c.andi s0, -1
    c.andi s0, -32
    c.andi s0, 31
    li a2, 0x0ff00ff0
    li a3, 0x00ffff00
    c.sub a2, a3
    c.xor a2, a3
    c.or a2, a3
    c.and a2, a3

    # Quadrant 2: c.slli, c.lwsp/c.swsp min/max, c.mv, c.add.
    c.slli a4, 1
    c.slli a4, 31
    c.swsp s0, 0(sp)
    c.swsp a2, 252(sp)
    c.lwsp a5, 0(sp)
    c.lwsp ra, 252(sp)
    c.mv a0, a5
    c.mv t6, s0
    c.add a0, a5
    c.add t6, t6

    # Compressed control flow: c.j, c.jal, c.jr, c.jalr, c.beqz, c.bnez.
    c.j 1f
    c.addi a0, 1              # skipped
1:  c.jal cfunc
    la t0, 2f
    c.jr t0
    c.addi a0, 1              # skipped
2:  la t1, cfunc
    c.jalr t1
    li s0, 0
    c.beqz s0, 3f
    c.addi a0, 1              # skipped
3:  c.bnez s0, 4f             # not taken
    c.addi a0, 2
4:  li s0, 5
5:  c.addi s0, -1
    c.bnez s0, 5b             # backward compressed loop
    c.beqz s0, 6f
6:
    # Odd halfword alignment: a 32-bit instruction after a single 16-bit one.
    c.nop
    I32 addi a1, a1, 1234
    c.nop
    I32 jal ra, cfunc_far     # 32-bit jal starting on a halfword boundary
    c.nop
    I32 beq x0, x0, 7f        # 32-bit branch starting on a halfword boundary
    c.addi a0, 1
7:  c.mv a0, a1
LOCKSTEP_PASS

    .balign 4
cfunc:
    c.addi a0, 5
    c.jr ra
    c.nop
cfunc_far:
    I32 addi a0, a0, 9
    ret

LOCKSTEP_FOOTER

    .data
    .balign 32
cbuf:
    .fill 512, 4, 0xa5a5a5a5
