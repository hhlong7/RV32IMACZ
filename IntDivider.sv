`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: IntDivider
// Description:
//   Iterative RV32M divider (div, divu, rem, remu). One operation at a time:
//
//     start   capture the operands; divide-by-zero finishes at once
//     RUN     32 cycles of restoring division on the magnitudes, one
//             quotient bit per cycle (a 33-bit compare-and-subtract)
//     FIX     restore the signs and select quotient or remainder (registered)
//     DONE    hold the result until it is acknowledged
//
//   The divide replaces a 32-level combinational divider in the ALU, which
//   was by far the longest path on an FPGA. Edge cases follow the spec:
//   x / 0 = all ones, x % 0 = x, and INT_MIN / -1 = INT_MIN with remainder 0
//   (|INT_MIN| = 2^31 divides by 1 exactly, and the signs agree).
//   OP: 00 div, 01 divu, 10 rem, 11 remu (funct3[1:0]).
//////////////////////////////////////////////////////////////////////////////////
module IntDivider (
    input  logic        clk,
    input  logic        rst,          // also kills an operation in progress
    input  logic        in_valid,     // start (only when !busy)
    input  logic [1:0]  in_op,
    input  logic [31:0] in_a,
    input  logic [31:0] in_b,
    output logic        busy,         // not idle (running or holding a result)
    output logic        out_valid,
    output logic [31:0] out_result,
    input  logic        ack           // result consumed; return to idle
);
    typedef enum logic [1:0] { IDLE, RUN, FIX, DONE } state_t;
    state_t state;

    logic [5:0]  count;
    logic [32:0] rem_q;               // partial remainder (one guard bit)
    logic [31:0] quo_q;               // dividend bits shift out, quotient in
    logic [31:0] divisor_q;
    logic        neg_quo, neg_rem, want_rem;
    logic [31:0] result_q;

    assign busy = (state != IDLE);
    assign out_valid = (state == DONE);
    assign out_result = result_q;

    // One restoring step: shift the next dividend bit into the remainder and
    // subtract the divisor if it fits.
    logic [32:0] shifted, trial;
    assign shifted = {rem_q[31:0], quo_q[31]};
    assign trial = shifted - {1'b0, divisor_q};

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
        end else begin
            unique case (state)
                IDLE: if (in_valid) begin
                    logic is_signed;
                    is_signed = !in_op[0];
                    want_rem <= in_op[1];
                    if (in_b == 32'b0) begin
                        // x / 0 = all ones; x % 0 = x.
                        result_q <= in_op[1] ? in_a : 32'hFFFF_FFFF;
                        state <= DONE;
                    end else begin
                        neg_quo <= is_signed && (in_a[31] ^ in_b[31]);
                        neg_rem <= is_signed && in_a[31];
                        quo_q <= (is_signed && in_a[31]) ? -in_a : in_a;
                        divisor_q <= (is_signed && in_b[31]) ? -in_b : in_b;
                        rem_q <= '0;
                        count <= 6'd32;
                        state <= RUN;
                    end
                end
                RUN: begin
                    if (!trial[32]) begin
                        rem_q <= trial;
                        quo_q <= {quo_q[30:0], 1'b1};
                    end else begin
                        rem_q <= shifted;
                        quo_q <= {quo_q[30:0], 1'b0};
                    end
                    count <= count - 6'd1;
                    if (count == 6'd1)
                        state <= FIX;
                end
                FIX: begin
                    if (want_rem)
                        result_q <= neg_rem ? -rem_q[31:0] : rem_q[31:0];
                    else
                        result_q <= neg_quo ? -quo_q : quo_q;
                    state <= DONE;
                end
                DONE: if (ack) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
