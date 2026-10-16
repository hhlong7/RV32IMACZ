# Loads and stores of every width at every legal alignment, sign/zero
# extension edges, cache-line boundaries, and store-to-load forwarding.
.include "harness.inc"

LOCKSTEP_START
    la s0, buf

    # Every load width at every naturally aligned offset of a patterned line
    # pair (first touch misses in L1 and L2; second pass hits).
    .rept 2
    .irp off, 0, 1, 2, 3, 28, 29, 30, 31, 32, 33, 62, 63
    I32 lb a0, \off(s0)
    I32 lbu a1, \off(s0)
    .endr
    .irp off, 0, 2, 28, 30, 32, 62
    I32 lh a2, \off(s0)
    I32 lhu a3, \off(s0)
    .endr
    .irp off, 0, 4, 28, 32, 60
    I32 lw a4, \off(s0)
    .endr
    .endr

    # Byte and halfword stores into every lane, then read the word back.
    li t1, 0x8180ff7f
    .irp off, 64, 65, 66, 67
    I32 sb t1, \off(s0)
    I32 lw a0, 64(s0)
    .endr
    .irp off, 68, 70
    I32 sh t1, \off(s0)
    I32 lw a0, 68(s0)
    I32 lh a1, \off(s0)
    I32 lhu a2, \off(s0)
    .endr

    # Store-buffer forwarding: full overlap, partial overlap, and no overlap.
    li t1, 0xdeadbeef
    I32 sw t1, 96(s0)
    I32 lw a0, 96(s0)
    I32 lb a1, 97(s0)
    I32 sb t1, 100(s0)
    I32 lw a2, 100(s0)
    I32 sh t1, 102(s0)
    I32 lhu a3, 102(s0)
    I32 lw a4, 104(s0)

    # Fill the store buffer, then load the oldest and youngest entries.
    .irp i, 0, 1, 2, 3, 4, 5, 6, 7
    I32 addi t2, t1, \i
    I32 sw t2, (128 + 4 * \i)(s0)
    .endr
    I32 lw a5, 128(s0)
    I32 lw a6, 156(s0)

    # Load-use hazards with every consumer type.
    I32 lw a0, 0(s0)
    I32 add a1, a0, a0
    I32 lw a2, 4(s0)
    I32 sw a2, 160(s0)
    I32 lw a3, 160(s0)
    I32 beq a3, a2, 1f
    I32 addi a4, a4, 1
1:  la t3, 2f
    I32 sw t3, 164(s0)
    I32 lw t3, 164(s0)        # load-use straight into a jump target
    I32 jalr x0, 0(t3)
    I32 addi a4, a4, 1        # skipped
2:
    # Walk enough lines to force L1 evictions and L2 hits on re-reference.
    li t2, 0
    I32 addi s1, s0, 2047
3:  I32 lw a0, 0(s0)
    I32 lw a1, 1024(s0)
    I32 lw a2, 1(s1)          # s0 + 2048
    I32 lw a3, 1536(s0)
    I32 lw a4, 512(s0)
    I32 lw a5, 1025(s1)       # s0 + 3072
    I32 addi t2, t2, 1
    li t4, 3
    I32 blt t2, t4, 3b

    # Loads from the uncached MMIO window (switches read back as zero).
    li t5, 0x11000000
    I32 lw a0, 0(t5)
LOCKSTEP_PASS

LOCKSTEP_FOOTER

    .data
    .balign 32
buf:
    .word 0x80ff7f01, 0xfedcba98, 0x01234567, 0x7fff8000
    .word 0x8000ffff, 0x00ff00ff, 0xa5a5a5a5, 0x5a5a5a5a
    .word 0xcafef00d, 0x80000000, 0x7fffffff, 0xffffffff
    .word 0x00000000, 0x13579bdf, 0x2468ace0, 0x89abcdef
    .fill 1024, 4, 0x6b6b6b6b
