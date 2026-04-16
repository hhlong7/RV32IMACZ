`timescale 1ns/1ps

module BranchGenerator(
    input logic [31:0] J,
    input logic [31:0] B,
    input logic [31:0] I,
    input logic [31:0] PC,
    input logic [31:0] rs1,
    input logic [31:0] rs2,
    input logic [6:0] IR_OPCODE,
    input logic [2:0] IR_FUNCT,

    output logic [31:0] branch,
    output logic [31:0] jalr,
    output logic [31:0] jal,
    output logic [2:0] pcsource
    );

    logic beq, blt, bltu;

    BCG branch_comp(
        .RS1(rs1),
        .RS2(rs2),
        .BR_EQ(beq),
        .BR_LT(blt),
        .BR_LTU(bltu)
    );

    BAG branch_addr_gen(
        .RS1(rs1),
        .I_TYPE(I),
        .J_TYPE(J),
        .B_TYPE(B),
        .FROM_PC(PC),
        .JAL(jal),
        .JALR(jalr),
        .BRANCH(branch)
    );

    always_comb begin
        case (IR_OPCODE)
            7'b1101111: pcsource = 3'b011; // JAL
            7'b1100111: pcsource = 3'b001; // JALR
            7'b1100011: begin // Branches
                case (IR_FUNCT)
                    3'b000: pcsource = beq ? 3'b010 : 3'b000; // BEQ
                    3'b001: pcsource = ~beq ? 3'b010 : 3'b000; // BNE
                    3'b100: pcsource = blt ? 3'b010 : 3'b000; // BLT
                    3'b101: pcsource = ~blt ? 3'b010 : 3'b000; // BGE
                    3'b110: pcsource = bltu ? 3'b010 : 3'b000; // BLTU
                    3'b111: pcsource = ~bltu ? 3'b010 : 3'b000; // BGEU
                    default: pcsource = 3'b000;
                endcase
            end
            default: pcsource = 3'b000;
        endcase
    end

endmodule 