`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: Cal Poly San Luis Obispo
// Module Name: ALU
// Description: RV32I integer ALU plus the RV32M multiply/divide unit.
//              ALU_FUN[4] selects the RV32M group; ALU_FUN[2:0] is funct3.
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
    localparam logic [4:0] FUN_MUL    = 5'b10000;
    localparam logic [4:0] FUN_MULH   = 5'b10001;
    localparam logic [4:0] FUN_MULHSU = 5'b10010;
    localparam logic [4:0] FUN_MULHU  = 5'b10011;
    localparam logic [4:0] FUN_DIV    = 5'b10100;
    localparam logic [4:0] FUN_DIVU   = 5'b10101;
    localparam logic [4:0] FUN_REM    = 5'b10110;
    localparam logic [4:0] FUN_REMU   = 5'b10111;

    // One 33x33 signed multiplier serves all four multiplies: each operand is
    // sign- or zero-extended to 33 bits as the operation requires. MUL only
    // uses the low word, which does not depend on the extension.
    logic a_is_signed, b_is_signed;
    logic signed [32:0] mul_a, mul_b;
    logic signed [65:0] product;

    assign a_is_signed = (ALU_FUN == FUN_MULH) || (ALU_FUN == FUN_MULHSU);
    assign b_is_signed = (ALU_FUN == FUN_MULH);
    assign mul_a = {a_is_signed & SRC_A[31], SRC_A};
    assign mul_b = {b_is_signed & SRC_B[31], SRC_B};
    assign product = mul_a * mul_b;

    // One unsigned divider serves all four divides: divide the magnitudes,
    // then restore signs (quotient negative when the signs differ, remainder
    // takes the dividend's sign). Overflow (INT_MIN / -1) falls out naturally:
    // |INT_MIN| / 1 = 0x8000_0000 with remainder 0, as the spec requires.
    logic div_is_signed, a_negative, b_negative;
    logic [31:0] a_magnitude, b_magnitude, quotient_magnitude, remainder_magnitude;
    logic [31:0] quotient, remainder;

    assign div_is_signed = (ALU_FUN == FUN_DIV) || (ALU_FUN == FUN_REM);
    assign a_negative = div_is_signed && SRC_A[31];
    assign b_negative = div_is_signed && SRC_B[31];
    assign a_magnitude = a_negative ? -SRC_A : SRC_A;
    assign b_magnitude = b_negative ? -SRC_B : SRC_B;

    always_comb begin
        if (SRC_B == 32'b0) begin
            // Division by zero: quotient all ones, remainder = dividend.
            quotient_magnitude = 32'hFFFF_FFFF;
            remainder_magnitude = a_magnitude;
            quotient = 32'hFFFF_FFFF;
            remainder = SRC_A;
        end else begin
            quotient_magnitude = a_magnitude / b_magnitude;
            remainder_magnitude = a_magnitude % b_magnitude;
            quotient = (a_negative ^ b_negative) ? -quotient_magnitude : quotient_magnitude;
            remainder = a_negative ? -remainder_magnitude : remainder_magnitude;
        end
    end

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
            FUN_MUL:    RESULT = product[31:0];
            FUN_MULH,
            FUN_MULHSU,
            FUN_MULHU:  RESULT = product[63:32];
            FUN_DIV,
            FUN_DIVU:   RESULT = quotient;
            FUN_REM,
            FUN_REMU:   RESULT = remainder;
            default:    RESULT = 32'b0;
        endcase
    end
endmodule
