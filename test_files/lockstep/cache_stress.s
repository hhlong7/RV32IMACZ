# Cache hierarchy stress for the fully associative L1 D-cache (16 lines) and
# L2 (32 lines): working sets that fit L1, overflow L1 but fit L2, and
# overflow both; stores into lines that are later evicted and refilled from
# L2 or memory; sub-word loads at every offset after refills; and atomics
# that must invalidate copies in both levels.
.include "harness.inc"

# Walk N lines (32 B apart) starting at base: read word 0 and the last byte,
# store a line-specific value into word 1, then read it back.
.macro WALK base, n, salt
    la t0, \base
    li t1, \n
1:  I32 lw a0, 0(t0)
    I32 lbu a1, 31(t0)
    I32 add a2, a0, t1
    I32 addi a2, a2, \salt
    I32 sw a2, 4(t0)
    I32 lw a3, 4(t0)
    I32 addi t0, t0, 32
    I32 addi t1, t1, -1
    I32 bnez t1, 1b
.endm

LOCKSTEP_START
    # 12 lines: fits L1. Second pass should hit everywhere.
    WALK buf, 12, 1
    WALK buf, 12, 2
    # 24 lines: overflows L1, fits L2. Repeated passes refill from L2 and
    # must see the stores made on the previous pass.
    .rept 3
    WALK buf, 24, 3
    .endr
    # 48 lines: overflows L2 too; refills come from memory.
    .rept 2
    WALK buf, 48, 5
    .endr
    # Back to a small set: lines last written two levels down.
    WALK buf, 8, 7

    # Every byte and halfword of one line right after its refill.
    la s0, buf + 32 * 40
    .irp off, 0, 1, 2, 3, 13, 30, 31
    I32 lb a0, \off(s0)
    .endr
    .irp off, 0, 2, 14, 30
    I32 lhu a1, \off(s0)
    .endr

    # Atomics on lines resident in L1 and L2: both copies must be dropped.
    la s1, buf + 32 * 2
    I32 lw a0, 0(s1)              # bring into L1 (and L2)
    li t2, 0x55
    I32 amoadd.w a1, t2, (s1)
    I32 lw a2, 0(s1)              # must see the AMO result
    WALK buf, 24, 9               # push it out of L1, keep it in L2
    I32 lw a3, 0(s1)
    I32 amoswap.w a4, t2, (s1)
    WALK buf, 24, 11
    I32 lw a5, 0(s1)
LOCKSTEP_PASS
LOCKSTEP_FOOTER

    .data
    .balign 32
buf:
    .set i, 0
    .rept 48 * 8
    .word 0x10000000 + i * 0x01010101
    .set i, i + 1
    .endr
