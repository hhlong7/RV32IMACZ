`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Engineer: Long Ho
// Module Name: DualIssueInOrder
// Description:
//   The conservative in-order dual-issue policy. Slot 0 keeps full
//   architectural ownership; slot 1 may issue alongside it only when it is a
//   simple integer register write with no LSU, CSR, or control side effects.
//   Operand and same-bundle dependency checks live in Hazard.
//////////////////////////////////////////////////////////////////////////////////

module DualIssueInOrder(
    input  logic [31:0] slot0_ir_i,
    input  logic        slot0_trap_taken_i,
    input  logic        slot0_mret_i,
    input  logic        slot0_fence_i,
    input  logic        slot0_fence_i_i,
    input  logic        slot0_atomic_valid_i,
    input  logic        slot0_csr_en_i,
    input  logic        slot0_mem_write_i,
    input  logic        slot0_mem_read_i,
    input  logic        slot0_reg_write_i,
    input  logic        slot0_legal_i,

    input  logic        slot1_valid_i,
    input  logic [31:0] slot1_ir_i,
    input  logic        slot1_legal_i,
    input  logic        slot1_reg_write_i,
    input  logic        slot1_mem_write_i,
    input  logic        slot1_mem_read_i,
    input  logic        slot1_csr_en_i,

    output logic        blocks_pair_o,
    output logic        pair_candidate_o
);

    import otter_defs_pkg::*;

    // Anything that can trap, redirect control, touch memory, or own CSR
    // state forces slot 0 to issue alone.
    assign blocks_pair_o = slot0_trap_taken_i || slot0_mret_i || slot0_fence_i || slot0_fence_i_i ||
                           slot0_atomic_valid_i || slot0_csr_en_i || is_control_ir(slot0_ir_i) ||
                           slot0_mem_write_i || slot0_mem_read_i || ~slot0_reg_write_i || ~slot0_legal_i;

    // The younger lane is limited to ALU-style register writes so the back
    // end can retire both instructions in program order.
    assign pair_candidate_o = slot1_valid_i &&
                              slot1_legal_i &&
                              slot1_reg_write_i &&
                              ~slot1_mem_write_i &&
                              ~slot1_mem_read_i &&
                              ~slot1_csr_en_i &&
                              ~is_front_barrier_ir(slot1_ir_i);
endmodule
