`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: Cal Poly San Luis Obispo 
// Engineer: Diversity
// Create Date: 02/09/2023 12:41:17 PM
// Module Name: BAG (Branch Address Generator)
//////////////////////////////////////////////////////////////////////////////////

module BAG(
    input logic [31:0] RS1,
    input logic [31:0] I_TYPE,
    input logic [31:0] J_TYPE,
    input logic [31:0] B_TYPE,
    input logic [31:0] FROM_PC,
    output logic [31:0] JAL,
    output logic [31:0] JALR,
    output logic [31:0] BRANCH
    );
    
    //Assign each branch address.
    assign JAL = FROM_PC + J_TYPE;
    assign JALR = I_TYPE + RS1;
    assign BRANCH = FROM_PC + B_TYPE;
    
endmodule
