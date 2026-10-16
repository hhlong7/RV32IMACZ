# RV32A: every AMO over signed/unsigned edge operands, all aq/rl variants,
# LR/SC success and the deterministic failure cases, and atomics whose address
# or data come straight from the forwarding network while the LSU is busy.
.include "harness.inc"

.macro AMO_MATRIX op
    .irp old, 0, 1, -1, 0x7fffffff, 0x80000000
    .irp src, 0, -1, 0x7fffffff, 0x80000000, 5
    li t1, \old
    I32 sw t1, 0(s0)
    li t2, \src
    I32 \op a0, t2, (s0)
    I32 lw a1, 0(s0)
    .endr
    .endr
.endm

LOCKSTEP_START
    la s0, amo_word
    .irp op, amoswap.w, amoadd.w, amoxor.w, amoand.w, amoor.w, amomin.w, amomax.w, amominu.w, amomaxu.w
    AMO_MATRIX \op
    .endr

    # Ordering-bit variants decode the same operation.
    li t2, 3
    .irp sfx, .aq, .rl, .aqrl
    I32 amoadd.w\sfx a0, t2, (s0)
    I32 lr.w\sfx a1, (s0)
    I32 sc.w\sfx a2, t2, (s0)
    .endr

    # LR/SC success, then SC without a live reservation fails.
    I32 lr.w a0, (s0)
    I32 addi a0, a0, 1
    I32 sc.w a1, a0, (s0)
    I32 sc.w a2, a0, (s0)
    I32 lw a3, 0(s0)

    # SC to a different word than the reservation fails.
    I32 addi s1, s0, 4
    I32 lr.w a0, (s0)
    I32 sc.w a1, a0, (s1)
    I32 lw a2, 4(s0)

    # Address and data produced immediately before the atomic, with older
    # loads/stores still in flight so the atomic waits in EX1.
    .rept 4
    I32 sw t2, 8(s0)
    I32 lw t3, 12(s0)
    I32 addi s2, s0, 16
    I32 addi t4, t3, 7
    I32 amoadd.w a0, t4, (s2)
    I32 add a1, a0, a0        # consumes the AMO result immediately
    .endr
    I32 sw t2, 8(s0)
    I32 addi s2, s0, 20
    I32 lr.w a0, (s2)
    I32 addi a0, a0, 9
    I32 sc.w a1, a0, (s2)
    I32 lw a2, 20(s0)

    # A plain store after an atomic to the same word is not lost.
    I32 amoswap.w a0, t2, (s0)
    I32 sw t4, 0(s0)
    I32 lw a1, 0(s0)
    I32 amoor.w a2, x0, (s0)

    # Atomics on a word that sits in the D-cache: the line must be refreshed.
    I32 addi s3, s0, 24
    I32 lw a0, 24(s0)
    I32 amoadd.w a1, t2, (s3)
    I32 lw a2, 24(s0)
LOCKSTEP_PASS
LOCKSTEP_FOOTER

    .data
    .balign 32
amo_word:
    .word 0, 0x11111111, 0x22222222, 0x33333333, 0x44444444, 0x55555555, 0x66666666, 0x77777777
