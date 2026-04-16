`timescale 1ns/1ps

module AtomicDecode(
    input logic instr_valid_i,
    input logic [31:0] ir_i,
    output logic atomic_valid_o,
    output logic [3:0] atomic_op_o,
    output logic atomic_aq_o,
    output logic atomic_rl_o,
    output logic atomic_legal_o
);

    import otter_defs_pkg::*;

    // RV32A uses a dedicated major opcode, so atomic detection is cheap and
    // can happen before the main decode path specializes operands.
    function automatic logic is_atomic_ir(input logic [31:0] ir);
        begin
            is_atomic_ir = (ir[6:0] == 7'b0101111);
        end
    endfunction

    // Map funct5 directly into the internal operation enum shared by the LSU
    // and commit logic.
    function automatic logic [3:0] atomic_ir_op(input logic [31:0] ir);
        begin
            atomic_ir_op = ATOMIC_NONE;

            unique case (ir[31:27])
                5'b00010: atomic_ir_op = ATOMIC_LR;
                5'b00011: atomic_ir_op = ATOMIC_SC;
                5'b00001: atomic_ir_op = ATOMIC_SWAP;
                5'b00000: atomic_ir_op = ATOMIC_ADD;
                5'b00100: atomic_ir_op = ATOMIC_XOR;
                5'b01100: atomic_ir_op = ATOMIC_AND;
                5'b01000: atomic_ir_op = ATOMIC_OR;
                5'b10000: atomic_ir_op = ATOMIC_MIN;
                5'b10100: atomic_ir_op = ATOMIC_MAX;
                5'b11000: atomic_ir_op = ATOMIC_MINU;
                5'b11100: atomic_ir_op = ATOMIC_MAXU;
                default: atomic_ir_op = ATOMIC_NONE;
            endcase
        end
    endfunction

    always_comb begin
        atomic_valid_o = instr_valid_i && is_atomic_ir(ir_i);
        atomic_op_o = atomic_ir_op(ir_i);
        // aq/rl bits are passed through even though the core currently enforces
        // a single conservative ordering point for all atomic traffic.
        atomic_aq_o = atomic_valid_o && ir_i[26];
        atomic_rl_o = atomic_valid_o && ir_i[25];
        // This core only accepts word-sized atomics, and LR additionally requires
        // rs2 to be zero per the ISA encoding rules.
        atomic_legal_o = atomic_valid_o &&
                         (ir_i[14:12] == 3'b010) &&
                         (atomic_op_o != ATOMIC_NONE) &&
                         ((atomic_op_o != ATOMIC_LR) || (ir_i[24:20] == 5'd0));
    end

endmodule
