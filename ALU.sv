`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: Cal Poly San Luis Obispo
// Module Name: ALU
// Description: RV32I integer ALU. RV32M multiplies and divides run in their
//              own units (IntMultiplier, IntDivider), so the ALU stays a
//              single, short combinational stage.
//////////////////////////////////////////////////////////////////////////////////

module ALU(
    input logic [31:0] SRC_A,
    input logic [31:0] SRC_B,
    input logic [4:0] ALU_FUN,
    output logic [31:0] RESULT
    );

    localparam logic [4:0] FUN_ADD    = 5'b00000;
    localparam logic [4:0] FUN_SLL    = 5'b00001;
    localparam logic [4:0] FUN_SLT    = 5'b00010;
    localparam logic [4:0] FUN_SLTU   = 5'b00011;
    localparam logic [4:0] FUN_XOR    = 5'b00100;
    localparam logic [4:0] FUN_SRL    = 5'b00101;
    localparam logic [4:0] FUN_OR     = 5'b00110;
    localparam logic [4:0] FUN_AND    = 5'b00111;
    localparam logic [4:0] FUN_SUB    = 5'b01000;
    localparam logic [4:0] FUN_COPY_A = 5'b01001; // LUI and atomic address pass-through
    localparam logic [4:0] FUN_SRA    = 5'b01101;

    always_comb begin
        unique case (ALU_FUN)
            FUN_ADD:    RESULT = SRC_A + SRC_B;
            FUN_SUB:    RESULT = SRC_A - SRC_B;
            FUN_OR:     RESULT = SRC_A | SRC_B;
            FUN_AND:    RESULT = SRC_A & SRC_B;
            FUN_XOR:    RESULT = SRC_A ^ SRC_B;
            FUN_SRL:    RESULT = SRC_A >> SRC_B[4:0];
            FUN_SLL:    RESULT = SRC_A << SRC_B[4:0];
            FUN_SRA:    RESULT = $signed(SRC_A) >>> SRC_B[4:0];
            FUN_SLT:    RESULT = {31'b0, $signed(SRC_A) < $signed(SRC_B)};
            FUN_SLTU:   RESULT = {31'b0, SRC_A < SRC_B};
            FUN_COPY_A: RESULT = SRC_A;
            default:    RESULT = 32'b0;
        endcase
    end
endmodule
