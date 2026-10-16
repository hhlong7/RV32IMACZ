# Zifencei: code patched by stores (word, halfword) and by an AMO must be
# visible after FENCE.I, including code that is already resident in the
# I-cache and the next-line prefetch buffer.
.include "harness.inc"

LOCKSTEP_START
    la s0, patch_word
    la s1, patch_half
    la s2, patch_amo
    la s3, new_insns

    # Run every patch site once so the lines are cached.
    li a0, 0
    jal ra, run_sites

    # Patch a 32-bit instruction with a word store.
    I32 lw t0, 0(s3)          # addi a0, a0, 100
    I32 sw t0, 0(s0)
    fence.i
    jal ra, run_sites

    # Patch a compressed instruction with a halfword store.
    I32 lhu t0, 8(s3)         # c.addi a0, 7
    I32 sh t0, 0(s1)
    fence.i
    jal ra, run_sites

    # Patch through an AMO (the I-side mirror must see atomic writes too).
    I32 lw t0, 4(s3)          # addi a0, a0, 1000
    I32 amoswap.w t1, t0, (s2)
    fence.i
    jal ra, run_sites

    # Patch, fence.i, and execute the patched instruction straight away.
    I32 lw t0, 12(s3)         # addi a1, a1, 55
    la s4, 1f
    .balign 4
    I32 sw t0, 0(s4)
    fence.i
1:  I32 addi a1, a1, 1        # word-aligned patch target
    # FENCE.I right behind a store-buffer burst.
    .irp i, 0, 1, 2, 3, 4
    I32 sw t0, (16 + 4 * \i)(s3)
    .endr
    fence.i
    I32 lw a2, 16(s3)
LOCKSTEP_PASS

    .balign 4
run_sites:
patch_word:
    I32 addi a0, a0, 1
patch_half:
    c.addi a0, 2
    c.nop
patch_amo:
    I32 addi a0, a0, 3
    ret

LOCKSTEP_FOOTER

    .data
    .balign 16
new_insns:
    .word 0x06450513          # addi a0, a0, 100
    .word 0x3e850513          # addi a0, a0, 1000
    .half 0x051d, 0x0000      # c.addi a0, 7
    .word 0x03758593          # addi a1, a1, 55
    .fill 8, 4, 0
