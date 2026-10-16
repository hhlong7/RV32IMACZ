# Misaligned data accesses raise precise address-misaligned exceptions
# (mcause 4 for loads and LR, 6 for stores, SC and AMOs; mtval = address)
# and leave registers and memory untouched.
.include "harness.inc"

LOCKSTEP_START
    la t0, trap_handler
    csrw mtvec, t0
    la s0, buf
    li a3, 0x11223344
    li a4, 0x55667788

    .irp off, 1, 3
    I32 lh a4, \off(s0)
    I32 lhu a4, \off(s0)
    I32 sh a3, \off(s0)
    .endr
    .irp off, 1, 2, 3
    I32 lw a4, \off(s0)
    I32 sw a3, \off(s0)
    .endr
    I32 lw a5, 0(s0)          # memory must be unchanged

    # Compressed load/store with a misaligned base register.
    addi s1, s0, 2
    c.lw a4, 0(s1)
    c.sw a3, 4(s1)

    # Atomics.
    addi s2, s0, 2
    I32 lr.w a4, (s2)
    I32 sc.w a4, a3, (s2)
    I32 amoadd.w a4, a3, (s2)
    I32 amoswap.w a4, a3, (s2)
    I32 lw a5, 0(s0)

    # Misaligned address produced right before the access (forwarded), and
    # an access behind older stores still draining.
    I32 sw a3, 8(s0)
    I32 sw a3, 12(s0)
    I32 addi s3, s0, 6
    I32 lw a4, 0(s3)
    I32 addi s3, s3, -1
    I32 sh a3, 0(s3)
    I32 lw a5, 8(s0)

    # A misaligned access right after a CSR write to mtval / mcause.
    li t1, 0x1234
    csrw mtval, t1
    I32 lw a4, 1(s0)
    csrw mcause, t1
    I32 sw a4, 2(s0)
LOCKSTEP_PASS

    .balign 4
trap_handler:
    csrr a0, mcause
    csrr a1, mepc
    csrr a2, mtval
    lhu t0, 0(a1)
    andi t0, t0, 3
    addi a1, a1, 2
    li t1, 3
    bne t0, t1, 1f
    addi a1, a1, 2
1:  csrw mepc, a1
    mret

LOCKSTEP_FOOTER

    .data
    .balign 16
buf:
    .word 0xa1b2c3d4, 0x01020304, 0, 0, 0, 0, 0, 0
