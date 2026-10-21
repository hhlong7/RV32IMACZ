# Store-to-load forwarding from the store queue. Every load follows its
# store(s) closely enough that they are still uncommitted, so the load must
# take the youngest overlapping store's bytes: full forwards at every size and
# offset (signed and unsigned), partial overlaps that must wait, disjoint
# bytes of the same word, several stores to one word (youngest wins), FP
# stores feeding integer loads and the reverse, and forwarding behind a
# divide that holds up commit. Spike checks every value.
.include "harness.inc"

LOCKSTEP_START
    FP_INIT
    la s0, buf
    li s1, 0x89abcdef
    li s2, 0x12345678
    li s3, 0xfedc8a71

    # Word store -> word, halfword, and byte loads at every offset.
    sw s1, 0(s0)
    lw a0, 0(s0)
    lh a1, 0(s0)
    lh a2, 2(s0)
    lhu a3, 2(s0)
    lb a4, 0(s0)
    lb a5, 1(s0)
    lbu a6, 2(s0)
    lb a7, 3(s0)

    # Halfword stores (data has junk upper bits) -> covered and partial loads.
    sh s3, 4(s0)
    lh t0, 4(s0)
    lhu t1, 4(s0)
    lb t2, 5(s0)
    lw t3, 4(s0)                     # partial: must wait for the sh to commit
    sh s2, 6(s0)
    lhu t4, 6(s0)
    lw t5, 4(s0)                     # two halves from two stores: waits

    # Byte stores -> byte loads, disjoint bytes of the same word, partial word.
    sb s3, 8(s0)
    sb s2, 9(s0)
    lbu t6, 8(s0)
    lb s4, 9(s0)
    lbu s5, 10(s0)                   # same word, untouched byte: no overlap
    lh s6, 8(s0)                     # spans two byte stores: waits
    lw s7, 8(s0)

    # Several stores to one word: the youngest overlapping store wins, and a
    # younger partial store blocks forwarding from an older full one.
    sw s1, 12(s0)
    sw s2, 12(s0)
    lw s8, 12(s0)                    # forwards s2
    sb s3, 13(s0)
    lb s9, 13(s0)                    # forwards the byte
    lw s10, 12(s0)                   # older sw + younger sb: waits
    sw s1, 16(s0)
    sh s2, 16(s0)
    sw s3, 16(s0)
    lhu s11, 18(s0)                  # youngest (sw) covers it

    # FP stores and loads through the same queue.
    la t0, fp_vals
    flw f1, 0(t0)
    fsw f1, 20(s0)
    lw a0, 20(s0)                    # int load from an FP store
    sw s2, 24(s0)
    flw f2, 24(s0)                   # FP load from an int store
    fsw f2, 28(s0)
    lw a1, 28(s0)

    # Forwarding while commit is held up behind a long divide: the stores
    # cannot retire, so these loads can only succeed by forwarding.
    li t0, 1000000
    li t1, 7
    div t2, t0, t1
    fdiv.s f3, f1, f1
    sw t0, 32(s0)
    lw a2, 32(s0)
    sb t1, 36(s0)
    lbu a3, 36(s0)
    add a4, a2, a3

    # A loop: store, load back, branch on the loaded value.
    li t3, 0
    li t4, 12
1:  slli t5, t3, 2
    add t5, t5, s0
    sw t3, 40(t5)
    lw t6, 40(t5)
    bne t6, t3, 2f
    addi t3, t3, 1
    bne t3, t4, 1b
2:  lw a5, 40(s0)
    lw a6, 84(s0)

    LOCKSTEP_PASS
LOCKSTEP_FOOTER

.data
.balign 4
fp_vals:
    .word 0x40490fdb                 # pi
buf:
    .space 96
