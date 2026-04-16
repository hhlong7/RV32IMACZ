`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: California Polytechnic University, San Luis Obispo
// Engineer: Diversity
// Create Date: 01/24/2023 09:30:07 AM
// Module Name: PC_MUX
//////////////////////////////////////////////////////////////////////////////////

module PC_MUX(
    input logic [31:0] PC_OUT_PLUS_FOUR,
    input logic [31:0] JALR,
    input logic [31:0] BRANCH,
    input logic [31:0] JAL,
    input logic [31:0] MTVEC,
    input logic [31:0] MEPC,
    input logic [2:0] PC_SOURCE,
    output logic [31:0] PC_MUX_OUT
    );
    
    //Case statement depending on PC_SOURCE
    always_comb begin
        case(PC_SOURCE)
            3'b000: begin PC_MUX_OUT = PC_OUT_PLUS_FOUR;
            end
            3'b001: begin PC_MUX_OUT = JALR;
            end
            3'b010: begin PC_MUX_OUT = BRANCH;
            end
            3'b011: begin PC_MUX_OUT = JAL;
            end
            3'b100: begin PC_MUX_OUT = MTVEC;
            end
            3'b101: begin PC_MUX_OUT = MEPC;
            end
            3'b110: begin PC_MUX_OUT = 32'h00000006; //Set to 6 to know what the select is, shouldn't happen
            end                                     //shouldn't happen
            3'b111: begin PC_MUX_OUT = 32'h00000007; //Set to 7 to know what the select is, shouldn't happen
            end                                      //shouldn't happen
            default: begin PC_MUX_OUT = 32'h00000000; //Set to 8 to know what the select is, shouldn't happen
            end                                       //shouldn't happen
        endcase
    end
endmodule
// i love cpe333