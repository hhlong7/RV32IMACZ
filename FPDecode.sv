`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: FPDecode
// Description:
//   Decode for the supported single-precision subset: flw, fsw, fadd.s,
//   fsub.s, fmul.s, fdiv.s (compressed loads/stores arrive already expanded).
//   Resolves the rounding mode (instruction rm, or fcsr.frm for rm=DYN) and
//   reports when an otherwise well-formed FP instruction must trap: FP is
//   disabled (mstatus.FS = Off) or the rounding mode is reserved.
//////////////////////////////////////////////////////////////////////////////////
module FPDecode (
    input  logic [31:0] ir_i,
    input  logic [2:0]  frm_i,        // fcsr.frm
    input  logic [1:0]  fs_i,         // mstatus.FS

    output logic        fp_instr_o,   // one of the supported FP instructions
    output logic        fp_load_o,
    output logic        fp_store_o,
    output logic [1:0]  fp_unit_o,    // FP_UNIT_* (arithmetic only)
    output logic        fp_sub_o,
    output logic        fp_write_o,   // writes an FP register
    output logic        uses_frs1_o,
    output logic        uses_frs2_o,
    output logic        dyn_rm_o,     // reads fcsr.frm
    output logic [2:0]  rm_o,         // resolved rounding mode
    output logic        illegal_o     // FS off, or reserved rounding mode
);
    import otter_defs_pkg::*;
    import fpu_pkg::*;

    logic op_fp, arith;
    logic [2:0] rm_field;

    assign rm_field = ir_i[14:12];
    assign op_fp = (ir_i[6:0] == OPC_OP_FP);

    always_comb begin
        fp_unit_o = FP_UNIT_NONE;
        fp_sub_o = 1'b0;
        if (op_fp) begin
            unique case (ir_i[31:25])   // funct5 + fmt=00 (single)
                7'b0000000: fp_unit_o = FP_UNIT_ADD;
                7'b0000100: begin fp_unit_o = FP_UNIT_ADD; fp_sub_o = 1'b1; end
                7'b0001000: fp_unit_o = FP_UNIT_MUL;
                7'b0001100: fp_unit_o = FP_UNIT_DIV;
                default: fp_unit_o = FP_UNIT_NONE;
            endcase
        end
    end

    assign arith = (fp_unit_o != FP_UNIT_NONE);
    assign fp_load_o = (ir_i[6:0] == OPC_LOAD_FP) && (ir_i[14:12] == 3'b010);
    assign fp_store_o = (ir_i[6:0] == OPC_STORE_FP) && (ir_i[14:12] == 3'b010);
    assign fp_instr_o = fp_load_o || fp_store_o || arith;
    assign fp_write_o = fp_load_o || arith;
    assign uses_frs1_o = arith;
    assign uses_frs2_o = arith || fp_store_o;

    assign dyn_rm_o = arith && (rm_field == RM_DYN);
    assign rm_o = dyn_rm_o ? frm_i : rm_field;

    // Rounding modes 5 and 6 are reserved, and so are 5-7 in frm.
    assign illegal_o = fp_instr_o &&
                       ((fs_i == 2'b00) || (arith && (rm_o > RM_RMM)));
endmodule
