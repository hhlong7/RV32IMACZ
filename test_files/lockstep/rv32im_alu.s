# RV32I + RV32M arithmetic: every register-register and register-immediate
# operation over a matrix of edge operands. Spike checks every result.
.include "harness.inc"

.macro RR_MATRIX op
    .irp a, 0, 1, -1, 0x7fffffff, 0x80000000, 0x80000001, 0xfffffffe, 31, 32, 0x12345678
    .irp b, 0, 1, -1, 0x7fffffff, 0x80000000, 2, 31, 32, 0x9abcdef0
    li a0, \a
    li a1, \b
    I32 \op a2, a0, a1
    .endr
    .endr
.endm

.macro RI_MATRIX op
    .irp a, 0, 1, -1, 0x7fffffff, 0x80000000, 0x800, 0x7ff, 0x5555aaaa
    .irp imm, 0, 1, -1, 2047, -2048, 0x555, -0x556
    li a0, \a
    I32 \op a2, a0, \imm
    .endr
    .endr
.endm

.macro SHIFT_MATRIX op
    .irp a, 1, -1, 0x80000000, 0x7fffffff, 0x12345678
    .irp sh, 0, 1, 4, 15, 16, 30, 31
    li a0, \a
    I32 \op a2, a0, \sh
    .endr
    .endr
.endm

LOCKSTEP_START
    .irp op, add, sub, sll, slt, sltu, xor, srl, sra, or, and
    RR_MATRIX \op
    .endr
    .irp op, mul, mulh, mulhsu, mulhu, div, divu, rem, remu
    RR_MATRIX \op
    .endr
    .irp op, addi, slti, sltiu, xori, ori, andi
    RI_MATRIX \op
    .endr
    .irp op, slli, srli, srai
    SHIFT_MATRIX \op
    .endr

    # Register shifts use only rs2[4:0].
    li a0, 0x87654321
    .irp sh, 32, 33, 63, -1, 0xffffffe0
    li a1, \sh
    I32 sll a2, a0, a1
    I32 srl a3, a0, a1
    I32 sra a4, a0, a1
    .endr

    # Upper immediates.
    .irp imm, 0, 1, 0x7ffff, 0x80000, 0xfffff, 0x12345
    I32 lui a0, \imm
    I32 auipc a1, \imm
    .endr

    # Writes to x0 must be discarded, and x0 must read as zero.
    I32 addi x0, x0, 5
    I32 add a0, x0, x0
    I32 lui x0, 0x12345
    I32 mul x0, a0, a0
    I32 addi a1, x0, -1

    # Back-to-back dependent chains (forwarding from every stage, both lanes).
    li a0, 3
    I32 add a0, a0, a0
    I32 add a0, a0, a0
    I32 mul a0, a0, a0
    I32 addi a1, a0, 1
    I32 sub a2, a1, a0
    I32 div a3, a1, a2
    I32 rem a4, a1, a0
    I32 xor a5, a4, a3
    I32 or a6, a5, a1
    I32 and a7, a6, a5
LOCKSTEP_PASS
LOCKSTEP_FOOTER
