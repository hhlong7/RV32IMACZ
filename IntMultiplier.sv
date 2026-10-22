`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: IntMultiplier
// Description:
//   Pipelined RV32M multiplier (mul, mulh, mulhsu, mulhu), one operation per
//   cycle, three stages:
//
//     S1  operand registers (sign/zero-extended to 33 bits)
//     S2  product register (the multiply happens between S1 and S2)
//     S3  output register
//
//   Vivado maps S1/S2/S3 onto the DSP48 slices' own A/B, M, and P pipeline
//   registers, so the 33x33 multiply is no longer a single-cycle path.
//   The pipeline advances unless a finished result is still waiting for a
//   common data bus (advance = 0); the caller tracks tags and squashes.
//   OP: 00 mul, 01 mulh, 10 mulhsu, 11 mulhu (funct3[1:0]).
//////////////////////////////////////////////////////////////////////////////////
module IntMultiplier (
    input  logic        clk,
    input  logic        rst,
    input  logic        advance,
    input  logic        in_valid,
    input  logic [1:0]  in_op,
    input  logic [31:0] in_a,
    input  logic [31:0] in_b,
    output logic        out_valid,
    output logic [31:0] out_result
);
    logic        s1_valid, s2_valid, s3_valid;
    logic        s1_hi, s2_hi;
    logic signed [32:0] s1_a, s1_b;
    logic signed [65:0] s2_product;
    logic [31:0] s3_result;

    always_ff @(posedge clk) begin
        if (rst) begin
            s1_valid <= 1'b0;
            s2_valid <= 1'b0;
            s3_valid <= 1'b0;
        end else if (advance) begin
            s1_valid <= in_valid;
            s2_valid <= s1_valid;
            s3_valid <= s2_valid;
        end
    end

    always_ff @(posedge clk) begin
        if (advance) begin
            // mulh: both signed; mulhsu: a signed; mulhu, mul: unsigned
            // (mul only uses the low word, which the extension cannot change).
            s1_a <= {(in_op == 2'b01 || in_op == 2'b10) & in_a[31], in_a};
            s1_b <= {(in_op == 2'b01) & in_b[31], in_b};
            s1_hi <= (in_op != 2'b00);
            s2_product <= s1_a * s1_b;
            s2_hi <= s1_hi;
            s3_result <= s2_hi ? s2_product[63:32] : s2_product[31:0];
        end
    end

    assign out_valid = s3_valid;
    assign out_result = s3_result;
endmodule
