# FP system behavior against Spike: mstatus.FS gating and Off/Initial/Clean/
# Dirty transitions, FP CSR aliasing (fcsr = {frm, fflags}), reserved
# rounding modes, compressed FP loads/stores, misaligned FP accesses, f0 as
# an ordinary register, and back-to-back FP dependencies through every
# producer (flw, pipelined add/mul, iterative div).
.include "harness.inc"

LOCKSTEP_START
    la t0, trap_handler
    csrw mtvec, t0
    la s0, fp_data

    # --- FS = Off: every FP instruction and FP CSR access traps ----------
    csrr a0, mstatus
    I32 flw f1, 0(s0)
    I32 fsw f1, 0(s0)
    fadd.s f1, f1, f1
    fdiv.s f1, f1, f1
    csrr a0, fflags
    csrw frm, x0
    c.flw f8, 0(s0)

    # --- FS = Initial, then the transitions ------------------------------
    li t0, 0x2000
    csrs mstatus, t0
    csrr a0, mstatus
    FP_INIT
    csrr a0, mstatus              # flw made FS Dirty
    li t0, 0x6000
    csrc mstatus, t0
    li t0, 0x4000                 # Clean
    csrs mstatus, t0
    I32 fsw f1, 0(s0)
    csrr a0, mstatus              # fsw leaves FS Clean
    csrr a1, fcsr
    csrr a0, mstatus              # CSR reads leave FS Clean
    fadd.s f2, f0, f0
    csrr a0, mstatus              # right behind an FP write: Dirty
    li t0, 0x4000
    csrc mstatus, t0              # FS = Initial (01)
    csrw fflags, x0
    csrr a0, mstatus              # FP CSR write: Dirty

    # --- FP CSR aliasing, read right after write -------------------------
    li t1, 0xff
    csrw fcsr, t1
    csrr a0, frm
    csrr a1, fflags
    csrwi frm, 3
    csrr a2, fcsr
    csrwi fflags, 0x15
    csrr a3, fcsr
    csrrci a4, fcsr, 0x1f
    csrr a5, fcsr

    # --- Dynamic rounding right after a frm write -------------------------
    I32 flw f1, 0(s0)             # 1.0
    I32 flw f2, 4(s0)             # 3.0
    csrwi frm, 1                  # RTZ
    fdiv.s f3, f1, f2, dyn
    csrwi frm, 3                  # RUP
    fdiv.s f4, f1, f2, dyn
    csrwi frm, 4
    fmul.s f5, f3, f4, dyn
    # Flags accrue across operations and are visible right away.
    csrw fflags, x0
    fdiv.s f6, f1, f0             # 1/0: DZ
    fadd.s f7, f3, f4             # inexact
    csrr a0, fflags
    csrr a1, fcsr

    # --- Reserved rounding modes trap ------------------------------------
    .word 0x0020f0d3 | (5 << 12) & ~(7 << 12) | (5 << 12)   # fadd.s rm=101
    .word 0x0020f0d3 & ~(7 << 12) | (6 << 12)               # fadd.s rm=110
    csrwi frm, 5
    fadd.s f8, f1, f2, dyn        # frm=101 with dyn: illegal
    csrwi frm, 7
    fmul.s f8, f1, f2, dyn
    csrwi frm, 0
    fadd.s f8, f1, f2, dyn        # legal again

    # --- Compressed FP loads/stores --------------------------------------
    la s1, fp_data                # x9: compressed base
    la sp, fp_data + 64
    c.flw f8, 0(s1)
    c.flw f9, 4(s1)
    c.fsw f8, 32(s1)
    c.flwsp f10, 0(sp)
    c.flwsp f0, 4(sp)             # f0 is a real register
    c.fswsp f9, 8(sp)
    I32 lw a0, 32(s1)
    I32 lw a1, 72(s1)
    fadd.s f11, f0, f0

    # --- Misaligned FP accesses trap -------------------------------------
    I32 flw f12, 2(s0)
    I32 fsw f12, 1(s0)

    # --- Back-to-back dependencies on every FP producer ------------------
    I32 flw f13, 0(s0)
    fadd.s f14, f13, f13          # load-use
    fmul.s f15, f14, f14          # add-use
    fsub.s f16, f15, f14          # mul-use
    fdiv.s f17, f16, f13          # sub-use
    fadd.s f18, f17, f17          # div-use
    I32 fsw f18, 12(s0)           # store of a just-computed result
    I32 lw a0, 12(s0)
    fdiv.s f19, f18, f13
    fdiv.s f20, f19, f13          # div behind div
    I32 fsw f20, 16(s0)
    I32 flw f21, 16(s0)           # load of a just-stored FP value
    fadd.s f22, f21, f20
    # FP work interleaved with integer work and memory traffic.
    I32 sw a0, 20(s0)
    fmul.s f23, f22, f22
    I32 addi a1, a0, 1
    I32 lw a2, 20(s0)
    fadd.s f24, f23, f22
    I32 fsw f24, 24(s0)
    csrr a3, fflags
    csrr a4, mstatus
LOCKSTEP_PASS

    .balign 4
trap_handler:
    csrr a5, mcause
    csrr a6, mepc
    csrr a7, mtval
    lhu t0, 0(a6)
    andi t0, t0, 3
    addi a6, a6, 2
    li t1, 3
    bne t0, t1, 1f
    addi a6, a6, 2
1:  csrw mepc, a6
    mret

LOCKSTEP_FOOTER

    .data
    .balign 16
fp_data:
    .word 0x3f800000, 0x40400000, 0xc0490fdb, 0x00000001
    .word 0x7f7fffff, 0x00800000, 0x3eaaaaab, 0x7fc00000
    .fill 24, 4, 0
