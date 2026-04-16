# Integrated "realistic computer" workload.
# This version is the visibly staged one: each successful feature check bumps
# the progress counter and writes that count to LEDS/SSEG so the testbench can
# watch the core advance through the scenario.
.eqv LEDS 0x11000020
.eqv SSEG 0x11000040
.eqv PATCH_INSN 0x001c8c93

.data
    .align 2                     # Keep all data word-aligned for simple loads/stores.

# Log of stage numbers 1..13 as each checkpoint passes.
progress_log:
    .space 52

# Baseline counter snapshot used by the final summary stage.
counter_base:
    .space 44

# Two source arrays used by ALU and RV32M helper routines.
array_a:
    .word 3, 1, 4, 1, 5, 9, 2, 6

array_b:
    .word 8, 5, 7, 9, 3, 2, 3, 8

# Scratch array used to confirm cached stores and reloads work.
array_c:
    .space 32

# Tiny memory region used to trigger load-use and store/load ordering cases.
hazard_words:
    .word 21
    .word 0

# Three widely separated cache lines used to force D-cache misses and hits.
dcache_a:
    .word 11
    .space 252
dcache_b:
    .word 22
    .space 252
dcache_c:
    .word 33
    .space 252

# Simple software stack for the subroutine-heavy workload.
stack_space:
    .space 256
stack_top:

.text
.globl main

# Main routine:
# 1. Set up MMIO pointers and saved-state registers.
# 2. Install the trap handler.
# 3. Snapshot counters before any workload runs.
# 4. Execute each feature stage in sequence.
# 5. Run a final summary that validates the whole session.
main:
    li s0, SSEG                   # Cache the seven-segment MMIO address in a saved register.
    li s8, LEDS                   # Cache the LED MMIO address for the same reason.
    la s1, progress_log           # Point s1 at the next free progress-log slot in RAM.
    li s2, 0                      # s2 holds the visible stage counter.
    li s5, 0                      # s5 is a trap-stage completion flag set by the handler.
    li s6, 0                      # s6 carries the expected mtval for the current trap test.
    li s9, 0                      # s9 is the fence.i patch target register.
    la sp, stack_top              # Initialize the software stack pointer.

    la t0, trap_handler           # Load the trap handler entry address.
    csrrw x0, 0x305, t0           # Write mtvec so traps jump to trap_handler.
    csrrw x0, 0x300, x0           # Clear mstatus to a known value before enabling MIE.
    csrrsi x0, 0x300, 8           # Set MIE in mstatus so mret restoration can be checked.

    jal ra, snapshot_counters     # Capture the initial performance-counter baseline.

    jal ra, stage_alu             # Run ALU/dataflow arithmetic work.
    jal ra, stage_branch          # Run branch-heavy classification code.
    jal ra, stage_forwarding      # Run a tight dependency chain to exercise forwarding.
    jal ra, stage_load_use        # Force a true load-use hazard.
    jal ra, stage_dcache          # Exercise realistic D-cache-backed loads/stores.
    jal ra, stage_prefetch        # Drive the I-cache prefetch path.
    jal ra, stage_rv32m           # Exercise multiply/divide/rem behavior.
    jal ra, stage_csr             # Exercise CSR reads, writes, and read-only behavior.
    jal ra, stage_ecall           # Check ecall trap entry/return.
    jal ra, stage_ebreak          # Check ebreak trap entry/return.
    jal ra, stage_illegal         # Check illegal-instruction trap entry/return.
    jal ra, stage_fencei          # Patch code in memory and force a refetch with fence.i.
    jal ra, stage_summary         # Validate the progress log and counter movement.

halt:
    j halt                        # Stay here forever once the workload finishes.

# Common helper used by each passing stage.
# It increments the software progress counter, logs it in RAM, and mirrors the
# current stage number to both LEDS and SSEG so the testbench sees 1,2,3,...
mark_stage:
    addi s2, s2, 1                # Bump the visible stage counter.
    sw s2, 0(s1)                  # Store the new stage number in the RAM log.
    addi s1, s1, 4                # Advance the RAM log pointer to the next word.
    sw s2, 0(s8)                  # Show the stage number on the LEDs.
    sw s2, 0(s0)                  # Show the same stage number on the seven-segment display.
    jalr x0, 0(ra)                # Return to the caller without modifying ra.

# Snapshot all implemented counters into counter_base so the summary stage can
# later check which architectural/microarchitectural events definitely moved.
snapshot_counters:
    la t0, counter_base           # Point t0 at the RAM array that holds the baseline snapshot.

    csrrs t1, 0xB00, x0           # Read mcycle.
    sw t1, 0(t0)                  # Save the cycle baseline.
    csrrs t1, 0xB02, x0           # Read minstret.
    sw t1, 4(t0)                  # Save the retired-instruction baseline.
    csrrs t1, 0xB03, x0           # Read branch-flush counter.
    sw t1, 8(t0)                  # Save the branch-flush baseline.
    csrrs t1, 0xB04, x0           # Read load-use stall counter.
    sw t1, 12(t0)                 # Save the load-use baseline.
    csrrs t1, 0xB05, x0           # Read I-cache miss counter.
    sw t1, 16(t0)                 # Save the I-cache miss baseline.
    csrrs t1, 0xB06, x0           # Read D-cache miss counter.
    sw t1, 20(t0)                 # Save the D-cache miss baseline.
    csrrs t1, 0xB07, x0           # Read useful prefetch-hit counter.
    sw t1, 24(t0)                 # Save the prefetch-hit baseline.
    csrrs t1, 0xB08, x0           # Read useless-prefetch counter.
    sw t1, 28(t0)                 # Save the useless-prefetch baseline.
    csrrs t1, 0xB09, x0           # Read trap-count counter.
    sw t1, 32(t0)                 # Save the trap-count baseline.
    csrrs t1, 0xB0A, x0           # Read RV32M busy-cycle counter.
    sw t1, 36(t0)                 # Save the RV32M busy baseline.
    csrrs t1, 0xB0B, x0           # Read RV32M stall-cycle counter.
    sw t1, 40(t0)                 # Save the RV32M stall baseline.
    jalr x0, 0(ra)                # Return to main.

# Stage 1: do a realistic arithmetic pass over two arrays and compare against a
# known-good scalar result.
stage_alu:
    addi sp, sp, -4               # Make room on the stack for the saved return address.
    sw ra, 0(sp)                  # Save ra because this stage calls a helper routine.

    la a0, array_a                # Pass the base of array_a as argument 0.
    la a1, array_b                # Pass the base of array_b as argument 1.
    li a2, 8                      # Pass the element count as argument 2.
    jal ra, compute_linear_combo  # Compute the weighted linear combination of the arrays.

    li t0, 99                     # Load the expected total for this helper.
    bne a0, t0, fail_901          # Fail if the helper returned the wrong sum.

    jal ra, mark_stage            # Record that the ALU stage passed.
    lw ra, 0(sp)                  # Restore the saved return address.
    addi sp, sp, 4                # Pop the stack slot.
    jalr x0, 0(ra)                # Return to main.

# Helper used by stage_alu.
# For each element, compute (2 * array_a[i] + array_b[i] - 1) and accumulate it.
compute_linear_combo:
    li t0, 0                      # t0 holds the running total.
    li t1, 0                      # t1 holds the loop index.

compute_linear_combo_loop:
    lw t2, 0(a0)                  # Load array_a[i].
    lw t3, 0(a1)                  # Load array_b[i].
    slli t4, t2, 1                # Compute 2 * array_a[i].
    add t4, t4, t3                # Add array_b[i].
    addi t4, t4, -1               # Subtract one to vary the ALU operations used.
    add t0, t0, t4                # Add this term into the running total.
    addi a0, a0, 4                # Advance array_a pointer to the next word.
    addi a1, a1, 4                # Advance array_b pointer to the next word.
    addi t1, t1, 1                # Increment the loop index.
    blt t1, a2, compute_linear_combo_loop  # Keep going until all elements are consumed.

    addi a0, t0, 0                # Move the final total into the return register.
    jalr x0, 0(ra)                # Return to the caller.

# Stage 2: classify values in array_b through several branch paths to make sure
# the branch unit and redirect logic both behave correctly.
stage_branch:
    addi sp, sp, -4               # Reserve stack space for ra.
    sw ra, 0(sp)                  # Save ra across the helper call.

    jal ra, classify_array_b      # Run the branch-heavy classifier.
    li t0, 16                     # Expected score produced by the classifier.
    bne a0, t0, fail_902          # Fail if the branch decisions produced the wrong score.

    jal ra, mark_stage            # Record branch-stage success.
    lw ra, 0(sp)                  # Restore ra.
    addi sp, sp, 4                # Pop the saved stack word.
    jalr x0, 0(ra)                # Return.

# Walk array_b and add:
# 1 for values < 5
# 2 for values in [5, 7]
# 3 for values >= 8
classify_array_b:
    la t5, array_b                # Start t5 at the first array_b element.
    li t0, 0                      # t0 accumulates the classification score.
    li t1, 0                      # t1 is the loop index.
    li t6, 8                      # t6 is the fixed loop bound.

classify_loop:
    lw t2, 0(t5)                  # Load the next array_b value.
    li t3, 5                      # First threshold for the "small" bucket.
    blt t2, t3, classify_small    # Branch to the small bucket if value < 5.
    li t3, 8                      # Second threshold for the "medium" bucket.
    blt t2, t3, classify_medium   # Branch to the medium bucket if value < 8.
    addi t0, t0, 3                # Otherwise the value is large, so add 3.
    j classify_next               # Skip over the smaller-bucket code.

classify_small:
    addi t0, t0, 1                # Count this element as a small value.
    j classify_next               # Jump to loop maintenance.

classify_medium:
    addi t0, t0, 2                # Count this element as a medium value.

classify_next:
    addi t5, t5, 4                # Advance to the next element.
    addi t1, t1, 1                # Increment the loop index.
    blt t1, t6, classify_loop     # Continue until all 8 words are processed.

    addi a0, t0, 0                # Return the classification score in a0.
    jalr x0, 0(ra)                # Return.

# Stage 3: create a tight chain of dependent ALU ops so the forwarding paths
# must feed fresh results without stalling.
stage_forwarding:
    addi sp, sp, -4               # Save ra because this stage still uses the common epilogue.
    sw ra, 0(sp)                  # Store ra to the stack.

    li t0, 3                      # Seed the dependency chain with a small constant.
    addi t1, t0, 4                # Depend on t0 immediately.
    add t2, t1, t0                # Depend on both t1 and t0.
    slli t3, t2, 2                # Shift the fresh t2 result.
    add t4, t3, t2                # Use both shifted and unshifted fresh results.
    xori t5, t4, 3                # Apply another dependent ALU op.
    srli t6, t5, 1                # Finish with a dependent logical shift.
    addi a0, t6, 7                # Produce the final expected answer in a0.

    li t0, 31                     # Expected chain result.
    bne a0, t0, fail_903          # Fail if forwarding produced a bad value.

    jal ra, mark_stage            # Record forwarding-stage success.
    lw ra, 0(sp)                  # Restore ra.
    addi sp, sp, 4                # Pop the stack frame.
    jalr x0, 0(ra)                # Return.

# Stage 4: force a genuine load-use dependency and then a store/load round-trip.
stage_load_use:
    addi sp, sp, -4               # Reserve stack space.
    sw ra, 0(sp)                  # Save ra.

    la t0, hazard_words           # Point at the small hazard-driving data area.
    lw t1, 0(t0)                  # Load the first word.
    add t2, t1, t1                # Use the loaded value immediately to force a load-use hazard.
    sw t2, 4(t0)                  # Store the doubled result to the second word.
    lw t3, 4(t0)                  # Read the just-stored value back.
    addi t4, t3, 8                # Offset it so the final expected value is unique.

    li t5, 50                     # Expected final answer: (21 * 2) + 8.
    bne t4, t5, fail_904          # Fail if hazard handling/store-load behavior is wrong.

    jal ra, mark_stage            # Record load-use-stage success.
    lw ra, 0(sp)                  # Restore ra.
    addi sp, sp, 4                # Pop the stack frame.
    jalr x0, 0(ra)                # Return.

# Stage 5: walk three cache lines in a miss/hit pattern, then confirm a cached
# store and reload through array_c.
stage_dcache:
    addi sp, sp, -4               # Reserve space for ra.
    sw ra, 0(sp)                  # Save ra.

    la t0, dcache_a               # Access cache line A.
    lw t1, 0(t0)                  # Load its first word.
    la t0, dcache_b               # Access cache line B.
    lw t2, 0(t0)                  # Load its first word.
    la t0, dcache_a               # Revisit line A.
    lw t3, 0(t0)                  # This revisit should behave like a hit.
    la t0, dcache_c               # Touch a third distant line.
    lw t4, 0(t0)                  # Load its first word.
    la t0, dcache_a               # Touch line A one more time.
    lw t5, 0(t0)                  # Confirm the mixed miss/hit sequence still returns correct data.

    add t6, t1, t2                # Start summing the loaded values.
    add t6, t6, t3                # Add the revisited A-line value.
    add t6, t6, t4                # Add the C-line value.
    add t6, t6, t5                # Add the final A-line value.

    li a0, 88                     # Expected total from 11 + 22 + 11 + 33 + 11.
    bne t6, a0, fail_905          # Fail if any cached load returned bad data.

    la t0, array_c                # Use array_c as a scratch location.
    sw t6, 0(t0)                  # Store the total to memory.
    lw t1, 0(t0)                  # Read it back through the memory hierarchy.
    bne t1, a0, fail_906          # Fail if the store/reload round-trip is wrong.

    jal ra, mark_stage            # Record D-cache-stage success.
    lw ra, 0(sp)                  # Restore ra.
    addi sp, sp, 4                # Pop the frame.
    jalr x0, 0(ra)                # Return.

# Stage 6: execute through aligned instruction blocks to drive I-cache fills and
# next-line prefetching, then skip a prefetched block to also exercise the
# "prefetch was fetched but not needed" case.
stage_prefetch:
    addi sp, sp, -4               # Reserve stack space.
    sw ra, 0(sp)                  # Save ra.

    li t0, 0                      # Start a simple counter for the sequential-use block.
    j prefetch_use_entry          # Jump into the aligned code block below.
    .align 5                      # Start the next code region on a 32-byte boundary.
prefetch_use_entry:
    addi t0, t0, 1                # Sequential instruction 1 in the aligned block.
    addi t0, t0, 1                # Sequential instruction 2 in the aligned block.
    addi t0, t0, 1                # Sequential instruction 3 in the aligned block.
    addi t0, t0, 1                # Sequential instruction 4 in the aligned block.
    addi t0, t0, 1                # Sequential instruction 5 in the aligned block.
    addi t0, t0, 1                # Sequential instruction 6 in the aligned block.
    addi t0, t0, 1                # Sequential instruction 7 in the aligned block.
    addi t0, t0, 1                # Sequential instruction 8 in the aligned block.
    addi t0, t0, 1                # Sequential instruction 9 in the aligned block.
    addi t0, t0, 1                # Sequential instruction 10 in the aligned block.
    addi t0, t0, 1                # Sequential instruction 11 in the aligned block.
    addi t0, t0, 1                # Sequential instruction 12 in the aligned block.
    addi t0, t0, 1                # Sequential instruction 13 in the aligned block.
    addi t0, t0, 1                # Sequential instruction 14 in the aligned block.
    addi t0, t0, 1                # Sequential instruction 15 in the aligned block.

    li t1, 15                     # Expected result from fifteen increments.
    bne t0, t1, fail_907          # Fail if the sequential block did not execute correctly.

    li t2, 0                      # Reset a second counter for the skip-a-block path.
    j prefetch_skip_seed          # Jump into a second aligned region.
    .align 5                      # Align it so the skipped block interacts with next-line prefetch.
prefetch_skip_seed:
    addi t2, t2, 1                # Seed-block instruction 1 before the forced branch.
    addi t2, t2, 1                # Seed-block instruction 2 before the forced branch.
    addi t2, t2, 1                # Seed-block instruction 3 before the forced branch.
    addi t2, t2, 1                # Seed-block instruction 4 before the forced branch.
    addi t2, t2, 1                # Seed-block instruction 5 before the forced branch.
    addi t2, t2, 1                # Seed-block instruction 6 before the forced branch.
    addi t2, t2, 1                # Seed-block instruction 7 before the forced branch.
    beq x0, x0, prefetch_skip_target  # Unconditionally skip over the next aligned block.

prefetch_skipped_block:
    nop                           # Skipped instruction 1 in the abandoned block.
    nop                           # Skipped instruction 2 in the abandoned block.
    nop                           # Skipped instruction 3 in the abandoned block.
    nop                           # Skipped instruction 4 in the abandoned block.
    nop                           # Skipped instruction 5 in the abandoned block.
    nop                           # Skipped instruction 6 in the abandoned block.
    nop                           # Skipped instruction 7 in the abandoned block.
    nop                           # Skipped instruction 8 in the abandoned block.

prefetch_skip_target:
    addi t3, x0, 9                # Build the expected value after the branch target.
    addi t3, t3, 1                # Increment once more at the taken target.
    li t4, 10                     # Expected result after the two target instructions.
    bne t3, t4, fail_908          # Fail if the skip path executed incorrectly.

    jal ra, mark_stage            # Record prefetch-stage success.
    lw ra, 0(sp)                  # Restore ra.
    addi sp, sp, 4                # Pop the stack frame.
    jalr x0, 0(ra)                # Return.

# Stage 7: run multiply/divide/remainder work that looks like a small numeric
# kernel and also checks a high-half multiply result.
stage_rv32m:
    addi sp, sp, -4               # Reserve stack space.
    sw ra, 0(sp)                  # Save ra.

    jal ra, dot_product4          # Compute a 4-element dot product using mul.
    li t0, 66                     # Expected dot-product result.
    bne a0, t0, fail_909          # Fail if the multiply path produced the wrong answer.

    li t1, 4                      # Divisor used for quotient/remainder checks.
    div t2, a0, t1                # Compute 66 / 4.
    rem t3, a0, t1                # Compute 66 % 4.
    li t4, 16                     # Expected quotient.
    bne t2, t4, fail_910          # Fail if div is wrong.
    li t4, 2                      # Expected remainder.
    bne t3, t4, fail_911          # Fail if rem is wrong.

    li t0, 0x40000000             # Operand chosen so the upper product bits are easy to predict.
    li t1, 4                      # Second multiply operand.
    mulh t2, t0, t1               # Compute the signed high half of the product.
    li t3, 1                      # Expected upper 32 bits of the product.
    bne t2, t3, fail_912          # Fail if mulh is wrong.

    jal ra, mark_stage            # Record RV32M-stage success.
    lw ra, 0(sp)                  # Restore ra.
    addi sp, sp, 4                # Pop the stack frame.
    jalr x0, 0(ra)                # Return.

# Helper used by stage_rv32m.
# It computes the dot product of the first four words in array_a and array_b.
dot_product4:
    la t0, array_a                # Point at the first input vector.
    la t1, array_b                # Point at the second input vector.
    li t2, 0                      # t2 accumulates the dot-product sum.
    li t3, 0                      # t3 is the loop index.
    li t6, 4                      # Use only the first four elements.

dot_product4_loop:
    lw t4, 0(t0)                  # Load the next element from array_a.
    lw t5, 0(t1)                  # Load the next element from array_b.
    mul a1, t4, t5                # Multiply the current pair.
    add t2, t2, a1                # Accumulate the partial product.
    addi t0, t0, 4                # Advance array_a pointer.
    addi t1, t1, 4                # Advance array_b pointer.
    addi t3, t3, 1                # Increment loop index.
    blt t3, t6, dot_product4_loop # Continue until four products have been accumulated.

    addi a0, t2, 0                # Return the dot-product result.
    jalr x0, 0(ra)                # Return.

# Stage 8: use CSR instructions like normal software would: scratch CSR writes,
# mstatus bit manipulation, misa readback, and a monotonic cycle counter read.
stage_csr:
    addi sp, sp, -4               # Reserve stack space.
    sw ra, 0(sp)                  # Save ra.

    li t0, 0x13579bdf             # Test pattern for mscratch.
    csrrw t1, 0x340, t0           # Write mscratch and capture its old value.
    bne t1, x0, fail_913          # The old value should be zero on first write.

    csrrs t2, 0x340, x0           # Read mscratch back without modifying it.
    bne t2, t0, fail_914          # Fail if mscratch did not hold the written value.

    csrrs t3, 0x301, x0           # Read misa.
    li t4, 0x40001100             # Expected ISA bits for RV32IM + Zicsr + Zifencei.
    bne t3, t4, fail_915          # Fail if misa does not match the implemented ISA.

    csrrw x0, 0x300, x0           # Clear mstatus to zero.
    csrrsi t5, 0x300, 8           # Set the MIE bit and read the old value.
    bne t5, x0, fail_916          # The old value should still be zero.

    csrrci t6, 0x300, 8           # Clear the MIE bit and read the old value.
    li a0, 8                      # The old value should have had MIE set.
    bne t6, a0, fail_917          # Fail if the old value from csrrci is wrong.

    csrrsi x0, 0x300, 8           # Re-enable MIE so later trap tests start from the expected state.

    csrrs a1, 0xC00, x0           # Read cycle.
    csrrs a2, 0xC00, x0           # Read cycle again.
    bgeu a2, a1, stage_csr_ok     # The second read should be >= the first read.
    j fail_918                    # Fail if cycle moved backwards.

stage_csr_ok:
    jal ra, mark_stage            # Record CSR-stage success.
    lw ra, 0(sp)                  # Restore ra.
    addi sp, sp, 4                # Pop the frame.
    jalr x0, 0(ra)                # Return.

# Stage 9: provoke an ecall trap, then let the handler patch mepc and mret back.
stage_ecall:
    addi sp, sp, -4               # Reserve stack space.
    sw ra, 0(sp)                  # Save ra.

    li s5, 0                      # Clear the trap-completed flag before triggering the trap.
    la s3, ecall_site             # Tell the handler which PC should appear in mepc.
    li s4, 11                     # Tell the handler the expected mcause for ecall-from-M-mode.
    li s6, 0                      # ecall should write zero into mtval.

ecall_site:
    ecall                         # Trigger the machine-mode environment-call trap.

after_ecall:
    li t0, 1                      # The handler sets s5 to 1 when the trap checks pass.
    bne s5, t0, fail_919          # Fail if the handler did not run correctly.

    jal ra, mark_stage            # Record ecall-stage success.
    lw ra, 0(sp)                  # Restore ra.
    addi sp, sp, 4                # Pop the frame.
    jalr x0, 0(ra)                # Return.

# Stage 10: repeat the same trap/return pattern for ebreak.
stage_ebreak:
    addi sp, sp, -4               # Reserve stack space.
    sw ra, 0(sp)                  # Save ra.

    li s5, 0                      # Clear the trap-completed flag.
    la s3, ebreak_site            # Tell the handler which PC should be captured in mepc.
    li s4, 3                      # Expected mcause for ebreak.
    li s6, 0                      # ebreak should also report mtval = 0.

ebreak_site:
    ebreak                        # Trigger the breakpoint trap.

after_ebreak:
    li t0, 1                      # The handler should again set s5 on success.
    bne s5, t0, fail_920          # Fail if the trap/return path did not complete correctly.

    jal ra, mark_stage            # Record ebreak-stage success.
    lw ra, 0(sp)                  # Restore ra.
    addi sp, sp, 4                # Pop the frame.
    jalr x0, 0(ra)                # Return.

# Stage 11: inject an illegal instruction word and verify the handler sees the
# correct cause, mtval, and mstatus trap-entry state.
stage_illegal:
    addi sp, sp, -4               # Reserve stack space.
    sw ra, 0(sp)                  # Save ra.

    li s5, 0                      # Clear the trap-completed flag.
    la s3, illegal_site           # Tell the handler which PC should fault.
    li s4, 2                      # Expected mcause for illegal instruction.
    li s6, -1                     # Expected mtval for the 0xffffffff instruction word.

illegal_site:
    .word 0xffffffff              # Raw illegal encoding to force an illegal-instruction trap.

after_illegal:
    li t0, 1                      # The handler should set s5 when all trap checks pass.
    bne s5, t0, fail_921          # Fail if the illegal trap path did not complete correctly.

    csrrs t1, 0x300, x0           # Read mstatus after returning with mret.
    andi t1, t1, 8                # Isolate the MIE bit.
    li t2, 8                      # MIE should be restored to 1 after mret.
    bne t1, t2, fail_922          # Fail if mret did not restore interrupt-enable state.

    jal ra, mark_stage            # Record illegal-instruction-stage success.
    lw ra, 0(sp)                  # Restore ra.
    addi sp, sp, 4                # Pop the frame.
    jalr x0, 0(ra)                # Return.

# Stage 12: patch the instruction at patch_slot, execute fence.i, and make sure
# the freshly written instruction is what the CPU actually fetches and runs.
stage_fencei:
    addi sp, sp, -4               # Reserve stack space.
    sw ra, 0(sp)                  # Save ra.

    li s9, 0                      # Clear the register that the patched instruction will update.
    la t0, patch_slot             # Point at the instruction word we are about to overwrite.
    li t1, PATCH_INSN             # Load the replacement instruction encoding.
    sw t1, 0(t0)                  # Store the new instruction word into memory.
    fence.i                       # Drain older stores and invalidate stale fetched instructions.

patch_slot:
    nop                           # This nop is replaced in memory by the PATCH_INSN store above.

    li t2, 1                      # The patched instruction should have written 1 into s9.
    bne s9, t2, fail_923          # Fail if the core kept executing stale code.

    jal ra, mark_stage            # Record fence.i-stage success.
    lw ra, 0(sp)                  # Restore ra.
    addi sp, sp, 4                # Pop the frame.
    jalr x0, 0(ra)                # Return.

# Final stage: prove the whole run behaved like a real benchmark session.
# It checks:
# - the stage counter reached 12 before the summary itself adds stage 13
# - the RAM progress log contains 1..12 in order
# - key counters definitely changed while the workload ran
# - the trap counter increased exactly three times
# - the RV32M stall counter stayed at zero for the current single-cycle M unit
stage_summary:
    li t0, 12                     # Expect twelve workload stages before the summary stage runs.
    bne s2, t0, fail_924          # Fail if the software stage counter is off.

    la t1, progress_log           # Start scanning the progress-log array.
    li t2, 1                      # Expected first stage number in the log.
    li t6, 13                     # Loop upper bound (stop after checking 12 entries).

summary_log_loop:
    lw t3, 0(t1)                  # Read the next logged stage number.
    bne t3, t2, fail_925          # Fail if the log is out of order or missing a stage.
    addi t1, t1, 4                # Advance to the next log entry.
    addi t2, t2, 1                # Expect the next stage number.
    blt t2, t6, summary_log_loop  # Continue until stages 1..12 have been checked.

    la t0, counter_base           # Point at the baseline counter snapshot.

    csrrs t1, 0xB00, x0           # Read current mcycle.
    lw t2, 0(t0)                  # Load baseline mcycle.
    sub t1, t1, t2                # Compute elapsed cycles.
    beq t1, x0, fail_926          # Fail if no cycles elapsed.

    csrrs t1, 0xB02, x0           # Read current minstret.
    lw t2, 4(t0)                  # Load baseline minstret.
    sub t1, t1, t2                # Compute retired instructions during the run.
    beq t1, x0, fail_927          # Fail if no instructions retired.

    csrrs t1, 0xB03, x0           # Read current branch-flush counter.
    lw t2, 8(t0)                  # Load baseline branch-flush counter.
    sub t1, t1, t2                # Compute branch redirects during the run.
    beq t1, x0, fail_928          # Fail if the branch-heavy workload caused no redirects.

    csrrs t1, 0xB04, x0           # Read current load-use stall counter.
    lw t2, 12(t0)                 # Load baseline load-use stall counter.
    sub t1, t1, t2                # Compute load-use stalls during the run.
    beq t1, x0, fail_929          # Fail if the explicit load-use stage caused no stalls.

    csrrs t1, 0xB05, x0           # Read current I-cache miss counter.
    lw t2, 16(t0)                 # Load baseline I-cache miss counter.
    sub t1, t1, t2                # Compute I-cache misses during the run.
    beq t1, x0, fail_930          # Fail if the I-side workload caused no misses.

    csrrs t1, 0xB06, x0           # Read current D-cache miss counter.
    lw t2, 20(t0)                 # Load baseline D-cache miss counter.
    sub t1, t1, t2                # Compute D-cache misses during the run.
    beq t1, x0, fail_931          # Fail if the D-side workload caused no misses.

    csrrs t1, 0xB07, x0           # Read useful prefetch hits.
    lw t2, 24(t0)                 # Load the useful-prefetch baseline.

    csrrs t1, 0xB08, x0           # Read useless prefetches.
    lw t2, 28(t0)                 # Load the useless-prefetch baseline.

    csrrs t1, 0xB09, x0           # Read current trap-count counter.
    lw t2, 32(t0)                 # Load baseline trap count.
    sub t1, t1, t2                # Compute traps taken during the run.
    li t3, 3                      # We expect exactly ecall, ebreak, and illegal instruction.
    bne t1, t3, fail_934          # Fail if the trap count is not exactly three.

    csrrs t1, 0xB0A, x0           # Read current RV32M busy-cycle counter.
    lw t2, 36(t0)                 # Load baseline RV32M busy counter.
    sub t1, t1, t2                # Compute RV32M busy cycles during the run.
    beq t1, x0, fail_935          # Fail if the RV32M stage registered no busy cycles.

    csrrs t1, 0xB0B, x0           # Read current RV32M stall counter.
    lw t2, 40(t0)                 # Load baseline RV32M stall counter.
    sub t1, t1, t2                # Compute RV32M stall cycles during the run.
    bne t1, x0, fail_936          # Fail if the current single-cycle M unit reported stalls.

    jal ra, mark_stage            # Record the summary stage itself as stage 13.

summary_done:
    j summary_done                # Sit here forever after all checks pass.

# Common trap handler used by the ecall, ebreak, and illegal-instruction stages.
# It verifies the trap CSRs, checks the mstatus entry behavior, sets a software
# "trap succeeded" flag, advances mepc to skip the faulting instruction, and
# returns with mret.
trap_handler:
    csrrs t0, 0x342, x0           # Read mcause.
    csrrs t1, 0x341, x0           # Read mepc.
    csrrs t2, 0x343, x0           # Read mtval.
    csrrs t3, 0x300, x0           # Read mstatus.

    bne t1, s3, fail_940          # Fail if mepc did not capture the expected faulting PC.
    bne t0, s4, fail_941          # Fail if mcause is wrong for this trap.
    bne t2, s6, fail_942          # Fail if mtval is wrong for this trap.

    andi t4, t3, 8                # Isolate MIE.
    bne t4, x0, fail_943          # MIE must be cleared on trap entry.

    li t5, 0x80                   # Bit mask for MPIE.
    and t4, t3, t5                # Isolate MPIE.
    bne t4, t5, fail_944          # MPIE must preserve the old MIE value.

    li s5, 1                      # Tell the stage code that the handler checks all passed.
    addi t1, t1, 4                # Advance mepc past the faulting instruction.
    csrrw x0, 0x341, t1           # Write the adjusted return PC back to mepc.
    mret                          # Return to the instruction after the trap source.

# Shared fail path:
# - every fail_NNN loads a unique code into t0
# - fail_with_t0 writes that code to LEDS and SSEG
# - fail_loop spins forever so the testbench can report the first failing code
fail_with_t0:
    sw t0, 0(s8)                  # Mirror the fail code to the LEDs.
    sw t0, 0(s0)                  # Mirror the fail code to the seven-segment display.

fail_loop:
    j fail_loop                   # Stop here permanently after the first failure.

fail_901:
    li t0, 901                    # ALU stage returned the wrong weighted sum.
    j fail_with_t0                # Report the fail code.

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

fail_924:
    li t0, 924
    j fail_with_t0

fail_925:
    li t0, 925
    j fail_with_t0

fail_926:
    li t0, 926
    j fail_with_t0

fail_927:
    li t0, 927
    j fail_with_t0

fail_928:
    li t0, 928
    j fail_with_t0

fail_929:
    li t0, 929
    j fail_with_t0

fail_930:
    li t0, 930
    j fail_with_t0

fail_931:
    li t0, 931
    j fail_with_t0

fail_932:
    li t0, 932
    j fail_with_t0

fail_933:
    li t0, 933
    j fail_with_t0

fail_934:
    li t0, 934
    j fail_with_t0

fail_935:
    li t0, 935
    j fail_with_t0

fail_936:
    li t0, 936
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
    li t0, 944                    # Trap entry did not preserve the old MIE value in MPIE.
    j fail_with_t0                # Report the fail code.
