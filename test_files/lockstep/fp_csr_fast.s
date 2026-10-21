# FP CSR accesses that do not serialize (fflags, frm/fcsr reads): they must
# see exactly the flags of every older FP operation, wake their dependents,
# fall back to serializing when their operand is still in flight, stay
# serializing for frm/fcsr writes, and vanish when squashed on a
# mispredicted path. Spike checks every value.
.include "harness.inc"

LOCKSTEP_START
    FP_INIT
    la s0, vals
    flw f1, 0(s0)                    # 1.0
    flw f2, 4(s0)                    # 3.0
    flw f3, 8(s0)                    # 1e-30 (underflow source)
    flw f4, 12(s0)                   # 3e38 (overflow source)

    # Each read sees the flags of all older FP ops; the result is used at once.
    fdiv.s f5, f1, f2                # inexact
    csrrw a0, fflags, x0
    add a1, a0, a0
    fmul.s f6, f3, f3                # underflow + inexact
    fadd.s f7, f1, f1                # exact
    csrr a2, fflags
    addi a3, a2, 1
    fmul.s f8, f4, f4                # overflow + inexact
    csrr a4, fcsr
    csrr a5, frm
    slli a6, a4, 2

    # A flags write whose source register is still being computed.
    li t0, 7
    li t1, 1000
    div t2, t1, t0
    andi t2, t2, 0x1f
    csrrw t3, fflags, t2
    csrrs t4, fflags, x0
    csrrsi t5, fflags, 0x10
    csrrci t6, fflags, 0x1f
    csrr s1, fflags

    # frm writes still serialize: younger dynamic-rounding ops use the new mode.
    li t0, 2                         # RDN
    csrw frm, t0
    fdiv.s f9, f1, f2
    fsw f9, 16(s0)
    lw s2, 16(s0)
    csrr s3, frm
    li t0, 3                         # RUP
    csrrw s4, frm, t0
    fdiv.s f10, f1, f2
    fsw f10, 20(s0)
    lw s5, 20(s0)
    csrw frm, x0

    # A loop whose exit branch mispredicts: the fast CSR accesses behind it on
    # the wrong path must leave no trace.
    li s6, 0
    li s7, 6
1:  fadd.s f11, f2, f3
    addi s6, s6, 1
    bne s6, s7, 1b
    csrrw s8, fflags, x0             # falls through only on the last trip
    fdiv.s f12, f2, f1
    csrr s9, fflags
    add s10, s8, s9

    # Back-to-back fast accesses with FP ops in between.
    li s6, 0
2:  fmul.s f13, f2, f3
    csrrw a0, fflags, x0
    fdiv.s f14, f2, f1
    csrrw a1, fflags, x0
    add a2, a0, a1
    addi s6, s6, 1
    bne s6, s7, 2b

    LOCKSTEP_PASS
LOCKSTEP_FOOTER

.data
.balign 4
vals:
    .word 0x3f800000                 # 1.0
    .word 0x40400000                 # 3.0
    .word 0x0da24260                 # 1e-30
    .word 0x7f61b1e6                 # 3e38
    .space 8
