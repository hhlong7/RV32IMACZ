`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: fp_multiplier
// Description:
//   Pipelined IEEE-754 single-precision multiplier (fmul.s). Three stages,
//   one new operation per cycle:
//     S1  unpack, special cases, sign and exponent
//     S2  24x24 significand multiply (exact 48-bit product)
//     S3  normalize and round, into the output register
//   Same timing (three `advance` edges) and stall behavior as fp_adder.
//////////////////////////////////////////////////////////////////////////////////
module fp_multiplier (
    input  logic        clk,
    input  logic        rst,
    input  logic        advance,

    input  logic        in_valid,
    input  logic [31:0] in_a,
    input  logic [31:0] in_b,
    input  logic [2:0]  in_rm,

    output logic        out_valid,
    output logic [31:0] out_result,
    output logic [4:0]  out_flags
);
    import fpu_pkg::*;

    typedef struct packed {
        logic valid;
        logic [2:0] rm;
        logic special;
        logic [31:0] special_result;
        logic [4:0] special_flags;
        logic sign;
        int exp;                 // exponent of the product of the two hidden bits
        logic [23:0] sig_a;
        logic [23:0] sig_b;
    } s1_t;

    typedef struct packed {
        logic valid;
        logic [2:0] rm;
        logic special;
        logic [31:0] special_result;
        logic [4:0] special_flags;
        logic sign;
        int exp;
        logic [47:0] product;
    } s2_t;

    s1_t s1_d, s1_q;
    s2_t s2_d, s2_q;

    // ---- S1 ------------------------------------------------------------------
    // always @* rather than always_comb: Icarus 12 makes an always_comb block
    // sensitive to the local variables of the functions it calls, so blocks
    // sharing the fpu_pkg helpers re-trigger each other forever at time 0.
    always @* begin
        s1_t n;               // built locally and assigned once: the block never
                              // reads its own output
        n = '0;
        n.valid = in_valid;
        n.rm = in_rm;
        n.sign = in_a[31] ^ in_b[31];

        if (is_nan(in_a) || is_nan(in_b)) begin
            n.special = 1'b1;
            n.special_result = CANONICAL_NAN;
            n.special_flags[FLAG_NV] = is_snan(in_a) || is_snan(in_b);
        end else if ((is_inf(in_a) && is_zero(in_b)) || (is_zero(in_a) && is_inf(in_b))) begin
            n.special = 1'b1;
            n.special_result = CANONICAL_NAN;
            n.special_flags[FLAG_NV] = 1'b1;
        end else if (is_inf(in_a) || is_inf(in_b)) begin
            n.special = 1'b1;
            n.special_result = signed_inf(n.sign);
        end else if (is_zero(in_a) || is_zero(in_b)) begin
            n.special = 1'b1;
            n.special_result = {n.sign, 31'b0};
        end

        n.sig_a = unpack_sig(in_a);
        n.sig_b = unpack_sig(in_b);
        n.exp = unpack_exp(in_a) + unpack_exp(in_b) - 127;
        s1_d = n;
    end

    // ---- S2 ------------------------------------------------------------------
    always_comb begin
        s2_d.valid = s1_q.valid;
        s2_d.rm = s1_q.rm;
        s2_d.special = s1_q.special;
        s2_d.special_result = s1_q.special_result;
        s2_d.special_flags = s1_q.special_flags;
        s2_d.sign = s1_q.sign;
        s2_d.exp = s1_q.exp;
        s2_d.product = s1_q.sig_a * s1_q.sig_b;
    end

    // ---- S3 ------------------------------------------------------------------
    logic        s3_valid_d, s3_valid_q;
    logic [31:0] s3_result_d, s3_result_q;
    logic [4:0]  s3_flags_d, s3_flags_q;

    // always @* rather than always_comb: Icarus 12 makes an always_comb block
    // sensitive to the local variables of the functions it calls, so blocks
    // sharing the fpu_pkg helpers re-trigger each other forever at time 0.
    always @* begin
        logic [36:0] packed_result;
        int msb;

        msb = leading_one(64'(s2_q.product));
        // Two hidden bits multiply to bit 46 of the product.
        packed_result = round_pack(s2_q.sign, s2_q.exp + msb - 46,
                                   to_sig27(64'(s2_q.product), msb, 1'b0), s2_q.rm);

        s3_valid_d = s2_q.valid;
        if (s2_q.special) begin
            s3_result_d = s2_q.special_result;
            s3_flags_d = s2_q.special_flags;
        end else begin
            s3_result_d = packed_result[31:0];
            s3_flags_d = packed_result[36:32];
        end
    end

    assign out_valid = s3_valid_q;
    assign out_result = s3_result_q;
    assign out_flags = s3_flags_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            s1_q <= '0;
            s2_q <= '0;
            s3_valid_q <= 1'b0;
            s3_result_q <= '0;
            s3_flags_q <= '0;
        end else if (advance) begin
            s1_q <= s1_d;
            s2_q <= s2_d;
            s3_valid_q <= s3_valid_d;
            s3_result_q <= s3_result_d;
            s3_flags_q <= s3_flags_d;
        end
    end
endmodule
