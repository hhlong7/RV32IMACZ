`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer: Long Ho
// Create Date: 04/16/2026
// Module Name: DualIssueInOrder
// Description:
//   Encapsulates the conservative in-order dual-issue policy. Slot 0 keeps
//   full architectural ownership while slot 1 may issue only a simple integer
//   register-writing instruction with no LSU, CSR, or control side effects.
//////////////////////////////////////////////////////////////////////////////////

module DualIssueInOrder(
    input  logic        slot0_valid_i,
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
    input  logic [31:0] slot1_pc_i,
    input  logic [31:0] slot1_pc_4_i,
    input  logic [31:0] slot1_ir_i,
    input  logic [31:0] slot1_rs1_i,
    input  logic [31:0] slot1_rs2_i,
    input  logic        slot1_legal_i,
    input  logic        slot1_reg_write_i,
    input  logic        slot1_mem_write_i,
    input  logic        slot1_mem_read_i,
    input  logic        slot1_csr_en_i,
    input  logic        slot1_alu_src_a_i,
    input  logic [1:0]  slot1_alu_src_b_i,
    input  logic [4:0]  slot1_alu_fun_i,
    input  logic [1:0]  slot1_rf_wr_sel_i,

    input  logic        issue_lane0_i,
    input  logic        issue_pair_i,

    output logic        blocks_pair_o,
    output logic        pair_candidate_o,
    output logic        pair_issue_valid_o,
    output logic [31:0] pair_pc_o,
    output logic [31:0] pair_pc_4_o,
    output logic [31:0] pair_ir_o,
    output logic [31:0] pair_rs1_o,
    output logic [31:0] pair_rs2_o,
    output logic        pair_alu_src_a_o,
    output logic [1:0]  pair_alu_src_b_o,
    output logic [4:0]  pair_alu_fun_o,
    output logic [1:0]  pair_rf_wr_sel_o,
    output logic        pair_reg_write_o
);

    // Treat any branch, jump, or jalr as control-flow ownership for slot 0.
    function automatic logic is_control_ir(input logic [31:0] ir);
        begin
            is_control_ir = (ir[6:0] == 7'b1100011) ||
                            (ir[6:0] == 7'b1101111) ||
                            ((ir[6:0] == 7'b1100111) && (ir[14:12] == 3'b000));
        end
    endfunction

    // Slot 1 must also avoid system and fence instructions so the pair lane
    // cannot observe or create architectural side effects by itself.
    function automatic logic is_front_barrier_ir(input logic [31:0] ir);
        begin
            is_front_barrier_ir = is_control_ir(ir) ||
                                  (ir[6:0] == 7'b1110011) ||
                                  (ir[6:0] == 7'b0001111);
        end
    endfunction

    // Anything that can trap, redirect control, touch memory, or own CSR state
    // forces slot 0 to issue alone.
    assign blocks_pair_o = slot0_trap_taken_i || slot0_mret_i || slot0_fence_i || slot0_fence_i_i ||
                           slot0_atomic_valid_i ||
                           slot0_csr_en_i || is_control_ir(slot0_ir_i) ||
                           slot0_mem_write_i || slot0_mem_read_i || ~slot0_reg_write_i || ~slot0_legal_i;

    // The younger lane is intentionally limited to simple ALU-style register
    // writes so the back end can retire both instructions in program order.
    assign pair_candidate_o = slot1_valid_i &&
                              slot1_legal_i &&
                              slot1_reg_write_i &&
                              ~slot1_mem_write_i &&
                              ~slot1_mem_read_i &&
                              ~slot1_csr_en_i &&
                              ~is_front_barrier_ir(slot1_ir_i);

    // Hazard logic decides when a legal pair can actually launch this cycle.
    assign pair_issue_valid_o = issue_lane0_i && issue_pair_i;

    // This module only decides whether slot 1 is allowed; the actual operand
    // bundle is passed through unchanged for the paired ID/EX register write.
    assign pair_pc_o = slot1_pc_i;
    assign pair_pc_4_o = slot1_pc_4_i;
    assign pair_ir_o = slot1_ir_i;
    assign pair_rs1_o = slot1_rs1_i;
    assign pair_rs2_o = slot1_rs2_i;
    assign pair_alu_src_a_o = slot1_alu_src_a_i;
    assign pair_alu_src_b_o = slot1_alu_src_b_i;
    assign pair_alu_fun_o = slot1_alu_fun_i;
    assign pair_rf_wr_sel_o = slot1_rf_wr_sel_i;
    assign pair_reg_write_o = slot1_reg_write_i;
endmodule
