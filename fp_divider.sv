`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: fp_divider
// Description:
//   Iterative (non-pipelined) IEEE-754 single-precision divider (fdiv.s).
//   A restoring divider produces one quotient bit per cycle:
//     start   in_valid while idle: special cases, normalize subnormal
//             significands, set up the remainder (1 cycle)
//     run     27 quotient bits, one per cycle
//     done    out_valid stays high with the rounded result until `ack`
//   Special cases (NaN, infinity, zero, divide by zero) skip the run phase.
//////////////////////////////////////////////////////////////////////////////////
module fp_divider (
    input  logic        clk,
    input  logic        rst,

    input  logic        in_valid,   // start; ignored unless idle
    input  logic [31:0] in_a,       // dividend
    input  logic [31:0] in_b,       // divisor
    input  logic [2:0]  in_rm,

    output logic        busy,       // not idle (running or holding a result)
    output logic        out_valid,
    output logic [31:0] out_result,
    output logic [4:0]  out_flags,
    input  logic        ack         // result consumed; return to idle
);
    import fpu_pkg::*;

    localparam int QUOTIENT_BITS = 27;

    typedef enum logic [1:0] { IDLE, RUN, DONE } state_t;
    state_t state;

    logic [2:0] rm;
    logic sign;
    int exp;                        // exponent of quotient bit 26
    logic [25:0] remainder;
    logic [23:0] divisor;
    logic [QUOTIENT_BITS-1:0] quotient;
    int count;
    logic special;
    logic [31:0] special_result;
    logic [4:0] special_flags;

    assign busy = (state != IDLE);
    assign out_valid = (state == DONE);

    // Rounding of the finished quotient (only meaningful in DONE).
    always_comb begin
        logic [36:0] packed_result;
        int msb;
        msb = leading_one(64'(quotient));
        packed_result = round_pack(sign, exp + msb - 26,
                                   to_sig27(64'(quotient), msb, remainder != 0), rm);
        if (special) begin
            out_result = special_result;
            out_flags = special_flags;
        end else begin
            out_result = packed_result[31:0];
            out_flags = packed_result[36:32];
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            special <= 1'b0;
            quotient <= '0;
            remainder <= '0;
        end else begin
            unique case (state)
                IDLE: if (in_valid) begin
                    logic [23:0] sig_a, sig_b;
                    int shift_a, shift_b;
                    logic s;

                    s = in_a[31] ^ in_b[31];
                    sign <= s;
                    rm <= in_rm;
                    special <= 1'b1;
                    special_flags <= 5'b0;
                    state <= DONE;

                    if (is_nan(in_a) || is_nan(in_b)) begin
                        special_result <= CANONICAL_NAN;
                        special_flags[FLAG_NV] <= is_snan(in_a) || is_snan(in_b);
                    end else if ((is_zero(in_a) && is_zero(in_b)) || (is_inf(in_a) && is_inf(in_b))) begin
                        special_result <= CANONICAL_NAN;
                        special_flags[FLAG_NV] <= 1'b1;
                    end else if (is_inf(in_a)) begin
                        special_result <= signed_inf(s);
                    end else if (is_zero(in_b)) begin
                        special_result <= signed_inf(s);
                        special_flags[FLAG_DZ] <= 1'b1;
                    end else if (is_zero(in_a) || is_inf(in_b)) begin
                        special_result <= {s, 31'b0};
                    end else begin
                        // Normalize both significands so bit 23 is set.
                        sig_a = unpack_sig(in_a);
                        sig_b = unpack_sig(in_b);
                        shift_a = 23 - leading_one(64'(sig_a));
                        shift_b = 23 - leading_one(64'(sig_b));
                        special <= 1'b0;
                        exp <= (unpack_exp(in_a) - shift_a) - (unpack_exp(in_b) - shift_b) + 127;
                        remainder <= {2'b0, sig_a << shift_a};
                        divisor <= sig_b << shift_b;
                        quotient <= '0;
                        count <= QUOTIENT_BITS;
                        state <= RUN;
                    end
                end

                RUN: begin
                    // Restoring step: quotient bit weights run from 2^0 down
                    // to 2^-26 relative to a/b.
                    if (remainder >= {2'b0, divisor}) begin
                        quotient <= {quotient[QUOTIENT_BITS-2:0], 1'b1};
                        remainder <= (remainder - {2'b0, divisor}) << 1;
                    end else begin
                        quotient <= {quotient[QUOTIENT_BITS-2:0], 1'b0};
                        remainder <= remainder << 1;
                    end
                    count <= count - 1;
                    if (count == 1)
                        state <= DONE;
                end

                DONE: if (ack) begin
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule
