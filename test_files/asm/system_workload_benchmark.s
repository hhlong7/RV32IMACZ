# Benchmark-oriented version of the integrated workload.
# This file intentionally runs the same functional stages as system_workload.s,
# but it keeps the measured region clean by avoiding intermediate MMIO writes.
# Instead, it snapshots counters before/after the workload, computes deltas in
# RAM, verifies the run, then emits one final result at the end.
.eqv LEDS 0x11000020
.eqv SSEG 0x11000040
.eqv PASS_CODE 119
.eqv PATCH_INSN 0x001c8c93

.data
    .align 2                     # Keep every RAM structure word-aligned.

# RAM log of stage numbers 1..12 so the benchmark can still prove each stage ran.
progress_log:
    .space 52

# Counter snapshot taken immediately before the measured region.
bench_start:
    .space 44

# Counter snapshot taken immediately after the measured region.
bench_end:
    .space 44

# Element-wise end-start deltas for the tracked counters.
bench_delta:
    .space 44

# Scratch area left available if more counter baselines are ever needed.
counter_base:
    .space 44

# Same input arrays as the staged workload.
array_a:
    .word 3, 1, 4, 1, 5, 9, 2, 6

array_b:
    .word 8, 5, 7, 9, 3, 2, 3, 8

array_c:
    .space 32

hazard_words:
    .word 21
    .word 0

dcache_a:
    .word 11
    .space 252
dcache_b:
    .word 22
    .space 252
dcache_c:
    .word 33
    .space 252

# Small software stack for the helper-heavy workload.
stack_space:
    .space 256
stack_top:

.text
.globl main

# Main routine:
# 1. Initialize saved registers and the stack.
# 2. Install the trap handler.
# 3. Snapshot counters into bench_start.
# 4. Run the same integrated workload stages as system_workload.s.
# 5. Snapshot counters into bench_end and compute bench_delta.
# 6. Verify the progress log and the key counter deltas.
# 7. Write only the final benchmark results to MMIO.
main:
    li s0, SSEG                   # Save the seven-segment MMIO address.
    li s8, LEDS                   # Save the LED MMIO address.
    la s1, progress_log           # Point s1 at the progress-log buffer.
    li s2, 0                      # s2 counts how many stages have passed.
    li s5, 0                      # s5 is set by the trap handler when a trap stage succeeds.
    li s6, 0                      # s6 carries the expected mtval for the active trap stage.
    li s9, 0                      # s9 is the register written by the fence.i patch test.
    la sp, stack_top              # Initialize the software stack.

    la t0, trap_handler           # Load the trap handler entry point.
    csrrw x0, 0x305, t0           # Install trap_handler in mtvec.
    csrrw x0, 0x300, x0           # Clear mstatus before re-enabling MIE.
    csrrsi x0, 0x300, 8           # Set MIE so trap entry/return behavior can be checked.

    la a0, bench_start            # Pass the bench_start buffer to the snapshot helper.
    jal ra, snapshot_counters     # Capture all counters before the measured region starts.

    jal ra, stage_alu             # Run the ALU-heavy stage.
    jal ra, stage_branch          # Run the branch-heavy stage.
    jal ra, stage_forwarding      # Run the forwarding dependency chain.
    jal ra, stage_load_use        # Run the load-use hazard stage.
    jal ra, stage_dcache          # Run the D-cache workload.
    jal ra, stage_prefetch        # Run the I-cache/prefetch workload.
    jal ra, stage_rv32m           # Run the RV32M workload.
    jal ra, stage_csr             # Run the CSR workload.
    jal ra, stage_ecall           # Run the ecall trap stage.
    jal ra, stage_ebreak          # Run the ebreak trap stage.
    jal ra, stage_illegal         # Run the illegal-instruction trap stage.
    jal ra, stage_fencei          # Run the self-modifying-code fence.i stage.

    la a0, bench_end              # Pass the bench_end buffer to the snapshot helper.
    jal ra, snapshot_counters     # Capture all counters immediately after the workload ends.
    jal ra, compute_deltas        # Convert the two snapshots into end-start deltas.
    jal ra, verify_progress       # Prove the stage log still says 1..12 in order.
    jal ra, verify_deltas         # Prove the key counters moved in the expected way.

    la t0, bench_delta            # Point at the computed counter deltas.
    lw t1, 0(t0)                  # Read the low 32-bit cycle delta.
    sw t1, 0(s8)                  # Show the cycle delta on the LEDs.
    li t2, PASS_CODE              # Load the benchmark pass code.
    sw t2, 0(s0)                  # Write the pass code to SSEG once everything checks out.

pass_loop:
    j pass_loop                   # Stay here forever after a successful benchmark run.

# Benchmark-mode stage recorder.
# Unlike mark_stage in system_workload.s, this helper only updates RAM and the
# software stage counter so the measured region is not polluted by MMIO writes.
record_stage:
    addi s2, s2, 1                # Increment the software stage counter.
    sw s2, 0(s1)                  # Log the completed stage number in RAM.
    addi s1, s1, 4                # Advance the log pointer.
    jalr x0, 0(ra)                # Return.

# Generic counter-snapshot helper.
# a0 points at the destination buffer, and the helper stores the current values
# of all implemented counters into that buffer in a fixed layout.
snapshot_counters:
    csrrs t1, 0xB00, x0           # Read mcycle.
    sw t1, 0(a0)                  # Store mcycle in the destination buffer.
    csrrs t1, 0xB02, x0           # Read minstret.
    sw t1, 4(a0)                  # Store minstret.
    csrrs t1, 0xB03, x0           # Read branch-flush counter.
    sw t1, 8(a0)                  # Store branch-flush count.
    csrrs t1, 0xB04, x0           # Read load-use stall counter.
    sw t1, 12(a0)                 # Store load-use stall count.
    csrrs t1, 0xB05, x0           # Read I-cache miss counter.
    sw t1, 16(a0)                 # Store I-cache misses.
    csrrs t1, 0xB06, x0           # Read D-cache miss counter.
    sw t1, 20(a0)                 # Store D-cache misses.
    csrrs t1, 0xB07, x0           # Read useful prefetch-hit counter.
    sw t1, 24(a0)                 # Store useful prefetch hits.
    csrrs t1, 0xB08, x0           # Read useless-prefetch counter.
    sw t1, 28(a0)                 # Store useless prefetches.
    csrrs t1, 0xB09, x0           # Read trap-count counter.
    sw t1, 32(a0)                 # Store trap count.
    csrrs t1, 0xB0A, x0           # Read RV32M busy-cycle counter.
    sw t1, 36(a0)                 # Store RV32M busy cycles.
    csrrs t1, 0xB0B, x0           # Read RV32M stall-cycle counter.
    sw t1, 40(a0)                 # Store RV32M stall cycles.
    jalr x0, 0(ra)                # Return.

# Convert bench_start and bench_end into a flat array of deltas.
compute_deltas:
    la t0, bench_start            # Point at the start snapshot.
    la t1, bench_end              # Point at the end snapshot.
    la t2, bench_delta            # Point at the output delta buffer.

    lw t3, 0(t1)                  # Load end mcycle.
    lw t4, 0(t0)                  # Load start mcycle.
    sub t3, t3, t4                # Compute elapsed cycles.
    sw t3, 0(t2)                  # Store cycle delta.

    lw t3, 4(t1)                  # Load end minstret.
    lw t4, 4(t0)                  # Load start minstret.
    sub t3, t3, t4                # Compute retired-instruction delta.
    sw t3, 4(t2)                  # Store retired-instruction delta.

    lw t3, 8(t1)                  # Load end branch-flush count.
    lw t4, 8(t0)                  # Load start branch-flush count.
    sub t3, t3, t4                # Compute branch-flush delta.
    sw t3, 8(t2)                  # Store branch-flush delta.

    lw t3, 12(t1)                 # Load end load-use count.
    lw t4, 12(t0)                 # Load start load-use count.
    sub t3, t3, t4                # Compute load-use delta.
    sw t3, 12(t2)                 # Store load-use delta.

    lw t3, 16(t1)                 # Load end I-cache miss count.
    lw t4, 16(t0)                 # Load start I-cache miss count.
    sub t3, t3, t4                # Compute I-cache miss delta.
    sw t3, 16(t2)                 # Store I-cache miss delta.

    lw t3, 20(t1)                 # Load end D-cache miss count.
    lw t4, 20(t0)                 # Load start D-cache miss count.
    sub t3, t3, t4                # Compute D-cache miss delta.
    sw t3, 20(t2)                 # Store D-cache miss delta.

    lw t3, 24(t1)                 # Load end useful-prefetch count.
    lw t4, 24(t0)                 # Load start useful-prefetch count.
    sub t3, t3, t4                # Compute useful-prefetch delta.
    sw t3, 24(t2)                 # Store useful-prefetch delta.

    lw t3, 28(t1)                 # Load end useless-prefetch count.
    lw t4, 28(t0)                 # Load start useless-prefetch count.
    sub t3, t3, t4                # Compute useless-prefetch delta.
    sw t3, 28(t2)                 # Store useless-prefetch delta.

    lw t3, 32(t1)                 # Load end trap count.
    lw t4, 32(t0)                 # Load start trap count.
    sub t3, t3, t4                # Compute trap-count delta.
    sw t3, 32(t2)                 # Store trap-count delta.

    lw t3, 36(t1)                 # Load end RV32M busy count.
    lw t4, 36(t0)                 # Load start RV32M busy count.
    sub t3, t3, t4                # Compute RV32M busy delta.
    sw t3, 36(t2)                 # Store RV32M busy delta.

    lw t3, 40(t1)                 # Load end RV32M stall count.
    lw t4, 40(t0)                 # Load start RV32M stall count.
    sub t3, t3, t4                # Compute RV32M stall delta.
    sw t3, 40(t2)                 # Store RV32M stall delta.
    jalr x0, 0(ra)                # Return.

# Verify that the software stage log still says 1..12 in order.
verify_progress:
    li t0, 12                     # Expect twelve stages to have completed before verification.
    bne s2, t0, fail_951          # Fail if the software counter is wrong.

    la t1, progress_log           # Start scanning the RAM stage log.
    li t2, 1                      # Expect stage 1 first.
    li t6, 13                     # Stop once stage 12 has been checked.

verify_progress_loop:
    lw t3, 0(t1)                  # Read the next logged stage number.
    bne t3, t2, fail_952          # Fail if it does not match the expected sequence.
    addi t1, t1, 4                # Advance to the next log word.
    addi t2, t2, 1                # Expect the next stage number.
    blt t2, t6, verify_progress_loop  # Continue until all twelve entries are checked.
    jalr x0, 0(ra)                # Return.

# Verify that the benchmark window actually exercised the core meaningfully.
verify_deltas:
    la t0, bench_delta            # Point at the computed delta array.

    lw t1, 0(t0)                  # Read cycle delta.
    beq t1, x0, fail_953          # Fail if the benchmark consumed zero cycles.

    lw t1, 4(t0)                  # Read retired-instruction delta.
    beq t1, x0, fail_954          # Fail if nothing retired.

    lw t1, 8(t0)                  # Read branch-flush delta.
    beq t1, x0, fail_955          # Fail if the branch workload caused no redirects.

    lw t1, 12(t0)                 # Read load-use delta.
    beq t1, x0, fail_956          # Fail if the hazard stage caused no load-use stalls.

    lw t1, 16(t0)                 # Read I-cache miss delta.
    beq t1, x0, fail_957          # Fail if the I-side workload caused no misses.

    lw t1, 20(t0)                 # Read D-cache miss delta.
    beq t1, x0, fail_958          # Fail if the D-side workload caused no misses.

    lw t1, 32(t0)                 # Read trap-count delta.
    li t2, 3                      # Exactly ecall, ebreak, and illegal instruction should trap.
    bne t1, t2, fail_959          # Fail if the trap count is not exactly three.

    lw t1, 36(t0)                 # Read RV32M busy-cycle delta.
    beq t1, x0, fail_960          # Fail if the RV32M stage registered no busy cycles.

    lw t1, 40(t0)                 # Read RV32M stall-cycle delta.
    bne t1, x0, fail_961          # Fail if the single-cycle M path reported stalls.

    jalr x0, 0(ra)                # Return.

# Stage 1 matches system_workload.s: weighted ALU pass over two arrays.
stage_alu:
    addi sp, sp, -4
    sw ra, 0(sp)

    la a0, array_a
    la a1, array_b
    li a2, 8
    jal ra, compute_linear_combo

    li t0, 99
    bne a0, t0, fail_901

    jal ra, record_stage
    lw ra, 0(sp)
    addi sp, sp, 4
    jalr x0, 0(ra)

# Helper for stage_alu; same arithmetic as the staged workload.
compute_linear_combo:
    li t0, 0
    li t1, 0

compute_linear_combo_loop:
    lw t2, 0(a0)
    lw t3, 0(a1)
    slli t4, t2, 1
    add t4, t4, t3
    addi t4, t4, -1
    add t0, t0, t4
    addi a0, a0, 4
    addi a1, a1, 4
    addi t1, t1, 1
    blt t1, a2, compute_linear_combo_loop

    addi a0, t0, 0
    jalr x0, 0(ra)

# Stage 2 matches system_workload.s: branch-heavy array classifier.
stage_branch:
    addi sp, sp, -4
    sw ra, 0(sp)

    jal ra, classify_array_b
    li t0, 16
    bne a0, t0, fail_902

    jal ra, record_stage
    lw ra, 0(sp)
    addi sp, sp, 4
    jalr x0, 0(ra)

# Classify each array_b element through small/medium/large branch paths.
classify_array_b:
    la t5, array_b
    li t0, 0
    li t1, 0
    li t6, 8

classify_loop:
    lw t2, 0(t5)
    li t3, 5
    blt t2, t3, classify_small
    li t3, 8
    blt t2, t3, classify_medium
    addi t0, t0, 3
    j classify_next

classify_small:
    addi t0, t0, 1
    j classify_next

classify_medium:
    addi t0, t0, 2

classify_next:
    addi t5, t5, 4
    addi t1, t1, 1
    blt t1, t6, classify_loop

    addi a0, t0, 0
    jalr x0, 0(ra)

# Stage 3 matches system_workload.s: tight dependency chain for forwarding.
stage_forwarding:
    addi sp, sp, -4
    sw ra, 0(sp)

    li t0, 3
    addi t1, t0, 4
    add t2, t1, t0
    slli t3, t2, 2
    add t4, t3, t2
    xori t5, t4, 3
    srli t6, t5, 1
    addi a0, t6, 7

    li t0, 31
    bne a0, t0, fail_903

    jal ra, record_stage
    lw ra, 0(sp)
    addi sp, sp, 4
    jalr x0, 0(ra)

# Stage 4 matches system_workload.s: explicit load-use hazard plus store/load round-trip.
stage_load_use:
    addi sp, sp, -4
    sw ra, 0(sp)

    la t0, hazard_words
    lw t1, 0(t0)
    add t2, t1, t1
    sw t2, 4(t0)
    lw t3, 4(t0)
    addi t4, t3, 8

    li t5, 50
    bne t4, t5, fail_904

    jal ra, record_stage
    lw ra, 0(sp)
    addi sp, sp, 4
    jalr x0, 0(ra)

# Stage 5 matches system_workload.s: realistic D-cache miss/hit/store pattern.
stage_dcache:
    addi sp, sp, -4
    sw ra, 0(sp)

    la t0, dcache_a
    lw t1, 0(t0)
    la t0, dcache_b
    lw t2, 0(t0)
    la t0, dcache_a
    lw t3, 0(t0)
    la t0, dcache_c
    lw t4, 0(t0)
    la t0, dcache_a
    lw t5, 0(t0)

    add t6, t1, t2
    add t6, t6, t3
    add t6, t6, t4
    add t6, t6, t5

    li a0, 88
    bne t6, a0, fail_905

    la t0, array_c
    sw t6, 0(t0)
    lw t1, 0(t0)
    bne t1, a0, fail_906

    jal ra, record_stage
    lw ra, 0(sp)
    addi sp, sp, 4
    jalr x0, 0(ra)

# Stage 6 matches system_workload.s: aligned instruction blocks to drive I-side prefetch.
stage_prefetch:
    addi sp, sp, -4
    sw ra, 0(sp)

    li t0, 0
    j prefetch_use_entry
    .align 5
prefetch_use_entry:
    addi t0, t0, 1
    addi t0, t0, 1
    addi t0, t0, 1
    addi t0, t0, 1
    addi t0, t0, 1
    addi t0, t0, 1
    addi t0, t0, 1
    addi t0, t0, 1
    addi t0, t0, 1
    addi t0, t0, 1
    addi t0, t0, 1
    addi t0, t0, 1
    addi t0, t0, 1
    addi t0, t0, 1
    addi t0, t0, 1

    li t1, 15
    bne t0, t1, fail_907

    li t2, 0
    j prefetch_skip_seed
    .align 5
prefetch_skip_seed:
    addi t2, t2, 1
    addi t2, t2, 1
    addi t2, t2, 1
    addi t2, t2, 1
    addi t2, t2, 1
    addi t2, t2, 1
    addi t2, t2, 1
    beq x0, x0, prefetch_skip_target

prefetch_skipped_block:
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop

prefetch_skip_target:
    addi t3, x0, 9
    addi t3, t3, 1
    li t4, 10
    bne t3, t4, fail_908

    jal ra, record_stage
    lw ra, 0(sp)
    addi sp, sp, 4
    jalr x0, 0(ra)

# Stage 7 matches system_workload.s: RV32M dot product plus divide/remainder checks.
stage_rv32m:
    addi sp, sp, -4
    sw ra, 0(sp)

    jal ra, dot_product4
    li t0, 66
    bne a0, t0, fail_909

    li t1, 4
    div t2, a0, t1
    rem t3, a0, t1
    li t4, 16
    bne t2, t4, fail_910
    li t4, 2
    bne t3, t4, fail_911

    li t0, 0x40000000
    li t1, 4
    mulh t2, t0, t1
    li t3, 1
    bne t2, t3, fail_912

    jal ra, record_stage
    lw ra, 0(sp)
    addi sp, sp, 4
    jalr x0, 0(ra)

# Helper for stage_rv32m; computes a 4-element dot product.
dot_product4:
    la t0, array_a
    la t1, array_b
    li t2, 0
    li t3, 0
    li t6, 4

dot_product4_loop:
    lw t4, 0(t0)
    lw t5, 0(t1)
    mul a1, t4, t5
    add t2, t2, a1
    addi t0, t0, 4
    addi t1, t1, 4
    addi t3, t3, 1
    blt t3, t6, dot_product4_loop

    addi a0, t2, 0
    jalr x0, 0(ra)

# Stage 8 matches system_workload.s: CSR reads, writes, and monotonic cycle reads.
stage_csr:
    addi sp, sp, -4
    sw ra, 0(sp)

    li t0, 0x13579bdf
    csrrw t1, 0x340, t0
    bne t1, x0, fail_913

    csrrs t2, 0x340, x0
    bne t2, t0, fail_914

    csrrs t3, 0x301, x0
    li t4, 0x40001100
    bne t3, t4, fail_915

    csrrw x0, 0x300, x0
    csrrsi t5, 0x300, 8
    bne t5, x0, fail_916

    csrrci t6, 0x300, 8
    li a0, 8
    bne t6, a0, fail_917

    csrrsi x0, 0x300, 8

    csrrs a1, 0xC00, x0
    csrrs a2, 0xC00, x0
    bgeu a2, a1, stage_csr_ok
    j fail_918

stage_csr_ok:
    jal ra, record_stage
    lw ra, 0(sp)
    addi sp, sp, 4
    jalr x0, 0(ra)

# Stage 9 matches system_workload.s: ecall trap entry/return.
stage_ecall:
    addi sp, sp, -4
    sw ra, 0(sp)

    li s5, 0
    la s3, ecall_site
    li s4, 11
    li s6, 0

ecall_site:
    ecall

after_ecall:
    li t0, 1
    bne s5, t0, fail_919

    jal ra, record_stage
    lw ra, 0(sp)
    addi sp, sp, 4
    jalr x0, 0(ra)

# Stage 10 matches system_workload.s: ebreak trap entry/return.
stage_ebreak:
    addi sp, sp, -4
    sw ra, 0(sp)

    li s5, 0
    la s3, ebreak_site
    li s4, 3
    li s6, 0

ebreak_site:
    ebreak

after_ebreak:
    li t0, 1
    bne s5, t0, fail_920

    jal ra, record_stage
    lw ra, 0(sp)
    addi sp, sp, 4
    jalr x0, 0(ra)

# Stage 11 matches system_workload.s: illegal instruction trap entry/return.
stage_illegal:
    addi sp, sp, -4
    sw ra, 0(sp)

    li s5, 0
    la s3, illegal_site
    li s4, 2
    li s6, -1

illegal_site:
    .word 0xffffffff

after_illegal:
    li t0, 1
    bne s5, t0, fail_921

    csrrs t1, 0x300, x0
    andi t1, t1, 8
    li t2, 8
    bne t1, t2, fail_922

    jal ra, record_stage
    lw ra, 0(sp)
    addi sp, sp, 4
    jalr x0, 0(ra)

# Stage 12 matches system_workload.s: self-modifying code plus fence.i refetch.
stage_fencei:
    addi sp, sp, -4
    sw ra, 0(sp)

    li s9, 0
    la t0, patch_slot
    li t1, PATCH_INSN
    sw t1, 0(t0)
    fence.i

patch_slot:
    nop

    li t2, 1
    bne s9, t2, fail_923

    jal ra, record_stage
    lw ra, 0(sp)
    addi sp, sp, 4
    jalr x0, 0(ra)

# Same trap handler contract as system_workload.s:
# validate mcause/mepc/mtval/mstatus, mark the trap as successful, skip the
# faulting instruction, and return with mret.
trap_handler:
    csrrs t0, 0x342, x0           # Read mcause.
    csrrs t1, 0x341, x0           # Read mepc.
    csrrs t2, 0x343, x0           # Read mtval.
    csrrs t3, 0x300, x0           # Read mstatus.

    bne t1, s3, fail_940          # Fail if mepc did not capture the expected trap PC.
    bne t0, s4, fail_941          # Fail if mcause is wrong for this stage.
    bne t2, s6, fail_942          # Fail if mtval is wrong for this stage.

    andi t4, t3, 8                # Isolate MIE.
    bne t4, x0, fail_943          # MIE must be cleared on trap entry.

    li t5, 0x80                   # Bit mask for MPIE.
    and t4, t3, t5                # Isolate MPIE.
    bne t4, t5, fail_944          # MPIE must preserve the old MIE value.

    li s5, 1                      # Tell the stage code that the trap checks passed.
    addi t1, t1, 4                # Advance mepc to the instruction after the trap source.
    csrrw x0, 0x341, t1           # Write the adjusted return PC back to mepc.
    mret                          # Return from the trap handler.

# Shared benchmark fail path.
# Every fail_NNN below identifies one specific checkpoint that broke.
fail_with_t0:
    sw t0, 0(s8)                  # Show the failure code on the LEDs.
    sw t0, 0(s0)                  # Show the same failure code on SSEG.

fail_loop:
    j fail_loop                   # Stop forever after the first failure.

fail_901:
    li t0, 901
    j fail_with_t0

fail_902:
    li t0, 902
    j fail_with_t0

fail_903:
    li t0, 903
    j fail_with_t0

fail_904:
    li t0, 904
    j fail_with_t0

fail_905:
    li t0, 905
    j fail_with_t0

fail_906:
    li t0, 906
    j fail_with_t0

fail_907:
    li t0, 907
    j fail_with_t0

fail_908:
    li t0, 908
    j fail_with_t0

fail_909:
    li t0, 909
    j fail_with_t0

fail_910:
    li t0, 910
    j fail_with_t0

fail_911:
    li t0, 911
    j fail_with_t0

fail_912:
    li t0, 912
    j fail_with_t0

fail_913:
    li t0, 913
    j fail_with_t0

fail_914:
    li t0, 914
    j fail_with_t0

fail_915:
    li t0, 915
    j fail_with_t0

fail_916:
    li t0, 916
    j fail_with_t0

fail_917:
    li t0, 917
    j fail_with_t0

fail_918:
    li t0, 918
    j fail_with_t0

fail_919:
    li t0, 919
    j fail_with_t0

fail_920:
    li t0, 920
    j fail_with_t0

fail_921:
    li t0, 921
    j fail_with_t0

fail_922:
    li t0, 922
    j fail_with_t0

fail_923:
    li t0, 923
    j fail_with_t0

fail_940:
    li t0, 940
    j fail_with_t0

fail_941:
    li t0, 941
    j fail_with_t0

fail_942:
    li t0, 942
    j fail_with_t0

fail_943:
    li t0, 943
    j fail_with_t0

fail_944:
    li t0, 944
    j fail_with_t0

fail_951:
    li t0, 951
    j fail_with_t0

fail_952:
    li t0, 952
    j fail_with_t0

fail_953:
    li t0, 953
    j fail_with_t0

fail_954:
    li t0, 954
    j fail_with_t0

fail_955:
    li t0, 955
    j fail_with_t0

fail_956:
    li t0, 956
    j fail_with_t0

fail_957:
    li t0, 957
    j fail_with_t0

fail_958:
    li t0, 958
    j fail_with_t0

fail_959:
    li t0, 959
    j fail_with_t0

fail_960:
    li t0, 960
    j fail_with_t0

fail_961:
    li t0, 961
    j fail_with_t0
