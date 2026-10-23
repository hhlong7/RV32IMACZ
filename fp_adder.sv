`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: fp_adder
// Description:
//   Pipelined IEEE-754 single-precision adder/subtractor (fadd.s / fsub.s).
//   Three stages, one new operation per cycle:
//     S1  unpack, special cases, order operands by magnitude, align
//     S2  add or subtract, normalize
//     S3  round, into the output register
//   An operation presented while in_valid is high produces out_valid,
//   result, and flags three `advance` edges later. Rounding has its own
//   cycle so the carry chains of normalize-and-round never share a cycle
//   with the common data bus. When advance is low every
//   stage holds, so the unit can stall in lockstep with the pipeline.
//////////////////////////////////////////////////////////////////////////////////
module fp_adder (
    input  logic        clk,
    input  logic        rst,
    input  logic        advance,

    input  logic        in_valid,
    input  logic        in_sub,     // fsub: negate b
    input  logic [31:0] in_a,
    input  logic [31:0] in_b,
    input  logic [2:0]  in_rm,

    output logic        out_valid,
    output logic [31:0] out_result,
    output logic [4:0]  out_flags
);
    import fpu_pkg::*;

    // Aligned operands carry 30 extra low bits plus one sticky bit, which is
    // more than enough for correct rounding after any cancellation.
    localparam int WIDE = 55;

    typedef struct packed {
        logic valid;
        logic [2:0] rm;
        logic special;           // result decided in S1
        logic [31:0] special_result;
        logic [4:0] special_flags;
        logic sign_big;
        logic sign_small;
        logic eff_sub;
        int exp_big;
        logic [WIDE-1:0] big_sig;
        logic [WIDE-1:0] small_sig;
    } s1_t;

    typedef struct packed {
        logic valid;
        logic [2:0] rm;
        logic special;
        logic [31:0] special_result;
        logic [4:0] special_flags;
        logic zero;              // exact zero result
        logic zero_sign;
        logic sign;
        int exp;
        logic [26:0] sig;
    } s2_t;

    s1_t s1_d, s1_q;
    s2_t s2_d, s2_q;

    // ---- S1 ------------------------------------------------------------------
    // always @* rather than always_comb: Icarus 12 makes an always_comb block
    // sensitive to the local variables of the functions it calls, so blocks
    // sharing the fpu_pkg helpers re-trigger each other forever at time 0.
    always @* begin
        logic [31:0] a, b, big_op, small_op;
        logic [23:0] sig_big, sig_small;
        int exp_small, distance;
        logic [WIDE-1:0] small_full;
        logic sticky;
        s1_t n;               // built locally and assigned once: the block never
                              // reads its own output

        a = in_a;
        b = {in_b[31] ^ in_sub, in_b[30:0]};

        n = '0;
        n.valid = in_valid;
        n.rm = in_rm;

        if (is_nan(a) || is_nan(b)) begin
            n.special = 1'b1;
            n.special_result = CANONICAL_NAN;
            n.special_flags[FLAG_NV] = is_snan(in_a) || is_snan(in_b);
        end else if (is_inf(a) && is_inf(b) && (a[31] != b[31])) begin
            n.special = 1'b1;
            n.special_result = CANONICAL_NAN;
            n.special_flags[FLAG_NV] = 1'b1;
        end else if (is_inf(a) || is_inf(b)) begin
            n.special = 1'b1;
            n.special_result = is_inf(a) ? a : b;
        end

        // Order by magnitude (exponent field, then fraction) so that
        // big - small never goes negative.
        if (a[30:0] >= b[30:0]) begin
            big_op = a;
            small_op = b;
        end else begin
            big_op = b;
            small_op = a;
        end

        sig_big = unpack_sig(big_op);
        sig_small = unpack_sig(small_op);
        n.exp_big = unpack_exp(big_op);
        exp_small = unpack_exp(small_op);
        n.sign_big = big_op[31];
        n.sign_small = small_op[31];
        n.eff_sub = big_op[31] ^ small_op[31];

        n.big_sig = {sig_big, 31'b0};
        small_full = {sig_small, 31'b0};
        distance = n.exp_big - exp_small;
        sticky = 1'b0;
        if (distance >= WIDE) begin
            n.small_sig = '0;
            sticky = (sig_small != 0);
        end else begin
            n.small_sig = small_full >> distance;
            for (int i = 0; i < WIDE; i++)
                if (i < distance && small_full[i]) sticky = 1'b1;
        end
        n.small_sig[0] = n.small_sig[0] | sticky;
        s1_d = n;
    end

    // ---- S2 ------------------------------------------------------------------
    // always @* rather than always_comb: Icarus 12 makes an always_comb block
    // sensitive to the local variables of the functions it calls, so blocks
    // sharing the fpu_pkg helpers re-trigger each other forever at time 0.
    always @* begin
        logic [WIDE:0] sum;
        int msb;

        s2_d = '0;
        s2_d.valid = s1_q.valid;
        s2_d.rm = s1_q.rm;
        s2_d.special = s1_q.special;
        s2_d.special_result = s1_q.special_result;
        s2_d.special_flags = s1_q.special_flags;
        s2_d.sign = s1_q.sign_big;

        sum = s1_q.eff_sub ? ({1'b0, s1_q.big_sig} - {1'b0, s1_q.small_sig})
                           : ({1'b0, s1_q.big_sig} + {1'b0, s1_q.small_sig});

        if (sum == 0) begin
            // Exact zero: like signs keep their sign (+0 + +0, -0 + -0);
            // otherwise +0, except -0 when rounding down.
            s2_d.zero = 1'b1;
            s2_d.zero_sign = (s1_q.sign_big == s1_q.sign_small) ? s1_q.sign_big : (s1_q.rm == RM_RDN);
        end else begin
            msb = leading_one(64'(sum));
            s2_d.sig = to_sig27(64'(sum), msb, 1'b0);
            // big holds the hidden bit at position WIDE-1 (= 54).
            s2_d.exp = s1_q.exp_big + msb - (WIDE - 1);
        end
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
        packed_result = round_pack(s2_q.sign, s2_q.exp, s2_q.sig, s2_q.rm);

        s3_valid_d = s2_q.valid;
        if (s2_q.special) begin
            s3_result_d = s2_q.special_result;
            s3_flags_d = s2_q.special_flags;
        end else if (s2_q.zero) begin
            s3_result_d = {s2_q.zero_sign, 31'b0};
            s3_flags_d = 5'b0;
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
