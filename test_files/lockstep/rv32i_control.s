# Control flow: every branch condition taken and not taken in both
# directions, JAL/JALR link semantics, JALR target LSB clearing, calls and
# returns deep enough to overflow the RAS, and 32-bit instructions that
# straddle words and cache lines.
.include "harness.inc"

.macro BRANCH_MATRIX op
    .irp a, 0, 1, -1, 0x7fffffff, 0x80000000
    .irp b, 0, 1, -1, 0x7fffffff, 0x80000000
    li a0, \a
    li a1, \b
    I32 \op a0, a1, 1f
    I32 addi a2, a2, 1        # executed only when not taken
1:
    .endr
    .endr
.endm

LOCKSTEP_START
    .irp op, beq, bne, blt, bge, bltu, bgeu
    BRANCH_MATRIX \op
    .endr

    # Backward branches: a counted loop per condition trains the BHT.
    li a0, 5
1:  I32 addi a0, a0, -1
    I32 bne a0, x0, 1b
    li a0, -4
1:  I32 addi a0, a0, 1
    I32 blt a0, x0, 1b
    li a0, 4
1:  I32 addi a0, a0, -1
    I32 bgeu a0, a0, 2f       # always taken forward out of the loop on 1st pass
    I32 j 1b
2:
    # Branch that alternates taken/not-taken (defeats a 2-bit counter).
    li a0, 8
    li a3, 0
1:  I32 andi a1, a0, 1
    I32 beq a1, x0, 2f
    I32 addi a3, a3, 1
2:  I32 addi a0, a0, -1
    I32 bne a0, x0, 1b

    # JAL / JALR link values and targets.
    I32 jal ra, 1f
    I32 addi a4, a4, 1        # skipped
1:  I32 jal x0, 1f
1:  la t0, 1f
    I32 jalr t1, 0(t0)
1:  la t0, 1f - 1
    I32 jalr t1, 1(t0)        # odd immediate: target LSB is cleared
    I32 addi a4, a4, 1        # skipped
1:  la t0, 1f + 1
    I32 jalr t1, 0(t0)        # odd register: target LSB is cleared
1:  la t0, 1f
    I32 jalr t0, 0(t0)        # rd == rs1: the target uses the old value
1:  la t0, 1f + 8
    I32 jalr t1, -8(t0)
1:
    # Nested calls deeper than the 4-entry RAS, then unwind.
    la sp, stack_top
    I32 jal ra, call_depth_6
    # Call through t0 (alternate link register) and return through t0.
    I32 jal t0, alt_link_func
    # Indirect call whose target changes (BTB must not keep stale targets).
    la s1, leaf_a
    la s2, leaf_b
    li s3, 6
1:  I32 jalr ra, 0(s1)
    I32 xor s1, s1, s2        # swap s1 <-> s2 with xor
    I32 xor s2, s1, s2
    I32 xor s1, s1, s2
    I32 addi s3, s3, -1
    I32 bne s3, x0, 1b

    # A 32-bit instruction starting at offset 30 of a 32-byte line straddles
    # two I-cache lines; also follow it with a branch target there.
    .balign 32
    .rept 15
    c.nop
    .endr
    I32 addi a5, a5, 17       # spans the line boundary
    I32 jal x0, straddle_target
    .balign 32
    .rept 15
    c.nop
    .endr
straddle_target:
    I32 addi a5, a5, 3
    I32 lui a6, 0x12345
LOCKSTEP_PASS

# call_depth_N calls call_depth_(N-1); depth 6 overflows the 4-entry RAS.
.macro CALL_LEVEL n, next
call_depth_\n:
    addi sp, sp, -4
    I32 sw ra, 0(sp)
    I32 addi a7, a7, \n
    I32 jal ra, call_depth_\next
    I32 lw ra, 0(sp)
    addi sp, sp, 4
    ret
.endm
    CALL_LEVEL 6, 5
    CALL_LEVEL 5, 4
    CALL_LEVEL 4, 3
    CALL_LEVEL 3, 2
    CALL_LEVEL 2, 1
    CALL_LEVEL 1, 0
call_depth_0:
    ret

alt_link_func:
    I32 addi a6, a6, 7
    I32 jalr x0, 0(t0)

leaf_a:
    I32 addi a6, a6, 1
    ret
leaf_b:
    I32 addi a6, a6, 100
    ret

LOCKSTEP_FOOTER

    .data
    .balign 16
    .fill 64, 4, 0
stack_top:
