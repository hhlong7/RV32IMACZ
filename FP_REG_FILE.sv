`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: FP_REG_FILE
// Description:
//   32 x 32-bit floating-point registers (f0 is an ordinary register). Four
//   read ports for two-wide dispatch and two write ports for two-wide commit;
//   when both writes target one register the younger (port 1) wins. Writes in
//   the current cycle are visible to the read ports immediately (forwarded),
//   and the array updates on the rising edge.
//////////////////////////////////////////////////////////////////////////////////
module FP_REG_FILE (
    input  logic        CLK,
    input  logic        WE0,
    input  logic [4:0]  WA0,
    input  logic [31:0] WD0,
    input  logic        WE1,
    input  logic [4:0]  WA1,
    input  logic [31:0] WD1,
    input  logic [3:0][4:0]  RA,
    output logic [3:0][31:0] RD
);
    logic [31:0] ram [0:31];

    initial begin
        for (int i = 0; i < 32; i++)
            ram[i] = 32'b0;
    end

    always_comb begin
        for (int p = 0; p < 4; p++) begin
            if (WE1 && WA1 == RA[p])
                RD[p] = WD1;
            else if (WE0 && WA0 == RA[p])
                RD[p] = WD0;
            else
                RD[p] = ram[RA[p]];
        end
    end

    always_ff @(posedge CLK) begin
        if (WE0)
            ram[WA0] <= WD0;
        if (WE1)
            ram[WA1] <= WD1;
    end
endmodule
