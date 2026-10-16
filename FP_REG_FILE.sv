`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: FP_REG_FILE
// Description:
//   32 x 32-bit floating-point registers (f0 is an ordinary register). Two
//   read ports for decode, one write port at writeback. Like REG_FILE, a
//   write in the current cycle is visible to the read ports immediately, and
//   the array updates on the falling edge.
//////////////////////////////////////////////////////////////////////////////////
module FP_REG_FILE (
    input  logic        CLK,
    input  logic        WE,
    input  logic [4:0]  WA,
    input  logic [31:0] WD,
    input  logic [4:0]  RA1,
    input  logic [4:0]  RA2,
    output logic [31:0] RD1,
    output logic [31:0] RD2
);
    logic [31:0] ram [0:31];

    initial begin
        for (int i = 0; i < 32; i++)
            ram[i] = 32'b0;
    end

    assign RD1 = (WE && WA == RA1) ? WD : ram[RA1];
    assign RD2 = (WE && WA == RA2) ? WD : ram[RA2];

    always_ff @(negedge CLK) begin
        if (WE)
            ram[WA] <= WD;
    end
endmodule
