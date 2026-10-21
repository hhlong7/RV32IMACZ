# Early branch recovery: branches that resolve late (they depend on a load
# that misses in the D-cache) and mispredict, with younger work already in
# flight on the wrong path: stores in the store queue, pipelined FP add/mul,
# a running FP divide, a waiting load, ALU ops, and a nested younger branch.
# Spike checks that none of the wrong-path work becomes architectural and
# that the correct path's results are right.
.include "harness.inc"

LOCKSTEP_START
    FP_INIT
    la t0, fp_consts
    I32 flw f1, 0(t0)                # 3.0
    I32 flw f2, 4(t0)                # 7.0
    la s0, cold                      # one word per 32-byte line: 0, 1, 0, 1, ...
    la s2, scratch
    li s1, 0
    li s3, 24                        # iterations (more lines than the L1 holds)

loop:
    I32 lw t1, 0(s0)                 # cold line: D-cache miss
    I32 flw f9, 4(s0)                # same line: arrives just after t1
    I32 addi t1, t1, 0               # delay the branch so FP ops that wait
    I32 addi t1, t1, 0               # for f9 are inside their pipelines
    I32 addi t1, t1, 0               # when it resolves
    I32 beq t1, x0, even             # resolves only when the miss returns
    # Odd path.
    fadd.s f10, f9, f1
    fmul.s f11, f9, f2
    I32 sw s1, 0(s2)
    fdiv.s f3, f1, f2
    fadd.s f4, f1, f2
    fmul.s f5, f1, f2
    I32 addi t2, s1, 100
    I32 sh t2, 6(s2)
    I32 lw t3, 0(s2)
    I32 bne t3, x0, nested           # younger branch, squashed with the path
    I32 addi t4, t4, 1
nested:
    I32 j next
even:
    fmul.s f12, f9, f1
    fadd.s f13, f9, f2
    I32 sw s3, 8(s2)
    fmul.s f6, f2, f2
    fdiv.s f7, f2, f1
    fadd.s f8, f6, f7
    I32 sb s1, 12(s2)
    I32 lw t5, 8(s2)
    I32 add t6, t5, s1
next:
    I32 addi s0, s0, 32
    I32 addi s1, s1, 1
    I32 bne s1, s3, loop

    # Results the comparison sees through later instructions.
    I32 lw a0, 0(s2)
    I32 lw a1, 4(s2)
    I32 lw a2, 8(s2)
    I32 lw a3, 12(s2)
    LOCKSTEP_PASS
LOCKSTEP_FOOTER

.data
.balign 4
fp_consts:
    .word 0x40400000, 0x40e00000
scratch:
    .space 16
.balign 32
cold:
    .rept 12
    .word 0
    .space 28
    .word 1
    .space 28
    .endr
