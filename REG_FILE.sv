`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: California Polytechnic University, San Luis Obispo
// Engineer: Diversity
// Create Date: 01/31/2023 09:24:40 AM
// Module Name: REG_FILE
// Project Name: OTTER
//////////////////////////////////////////////////////////////////////////////////

module REG_FILE(
    input logic CLK,
    input logic EN0, // older in-order writeback port
    input logic EN1, // younger in-order writeback port
    input logic [4:0] ADR1,
    input logic [4:0] ADR2,
    input logic [4:0] ADR3,
    input logic [4:0] ADR4,
    input logic [4:0] WA0, // older write address
    input logic [4:0] WA1, // younger write address
    input logic [31:0] WD0, // older write data
    input logic [31:0] WD1, // younger write data

    output logic [31:0] RS1,
    output logic [31:0] RS2,
    output logic [31:0] RS3,
    output logic [31:0] RS4
    );
    
    //Instantiate 32, 32-bit registers
    logic [31:0] ram[0:31];
    
    //Initialize all registers to 0. 
    initial begin
    static int i = 0;
        for (i = 0; i < 32; i++) begin
        ram[i] = 0;
        end
    end
    
    function automatic logic [31:0] read_port(input logic [4:0] addr);
        begin
            if (addr == 5'd0)
                read_port = 32'b0;
            // Decode sees the same in-order architectural result that WB is
            // about to commit. If both ports target the same register, the
            // younger port wins because it retires after the older one.
            else if (EN1 && (WA1 == addr) && (WA1 != 5'd0))
                read_port = WD1;
            else if (EN0 && (WA0 == addr) && (WA0 != 5'd0))
                read_port = WD0;
            else
                read_port = ram[addr];
        end
    endfunction

    // Two-wide decode needs four architectural source reads every cycle.
    always_comb begin
        RS1 = read_port(ADR1);
        RS2 = read_port(ADR2);
        RS3 = read_port(ADR3);
        RS4 = read_port(ADR4);
    end
   
   // Retire the older write first and the younger write second so same-cycle
   // WAW collisions match sequential in-order commit.
    always_ff@(negedge CLK) begin
        if (EN0 == 1'b1 && WA0 != 5'd0)
            ram[WA0] <= WD0;

        if (EN1 == 1'b1 && WA1 != 5'd0)
            ram[WA1] <= WD1;
    end 
    
endmodule
//i love cpe333
