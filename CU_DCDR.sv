`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: California Polytechnic University, San Luis Obispo
// Engineer: Long Ho
// Create Date: 02/23/2023 09:39:49 AM
// Module Name: CU_DCDR
//////////////////////////////////////////////////////////////////////////////////
module CU_DCDR(
    input logic IR_30,
    input logic [6:0] IR_OPCODE,
    input logic [2:0] IR_FUNCT,
    // IR_FUNCT3 is the 3-bit funct3 field in the instruction, which is used to further specify the operation for certain opcodes.
    input logic [6:0] IR_FUNCT7,
    // IR_FUNCT7 is the 7-bit funct7 field in the instruction, which is used to further specify the operation for certain opcodes, especially R-type instructions.
    input rst, clk, 
    
    output logic reset,

    output logic [4:0] ALU_FUN,
    output logic ALU_SRCA,
    output logic [1:0] ALU_SRCB,

    output logic [1:0] RF_WR_SEL,
    output logic MEM_WR_EN2,
    output logic MEM_RD_EN2,
    output logic REGWRITE,

    output logic CSR_EN,
    output logic CSR_USE_IMM, // CSR_USE_IMM is 1 if the instruction uses the I-type immediate encoding for the CSR address (e.g., CSRRWI), and 0 if it uses the standard rs1 encoding (e.g., CSRRW).
    output logic [1:0] CSR_CMD, // 00 = read, 01 = write, 10 = set bits, 11 = clear bits
    output logic LEGAL_INSTR // 1 if the instruction is legal and was successfully decoded
                             // 0 if the instruction is illegal or unsupported
    );
    
    always_ff @(posedge clk) reset <= rst ? 1 : 0;
    
    always_comb begin
        // Instantiate all outputs to 0 so as to avoid
        // unwanted leftovers from previous operations
        // and maintain direct control of outputs through
        // case statement below
        ALU_FUN = 5'b00000;
        ALU_SRCA = 1'b0;
        ALU_SRCB = 2'b00;

        MEM_WR_EN2 = 1'b0;
        MEM_RD_EN2 = 1'b0;
        RF_WR_SEL = 2'b11;
        REGWRITE = 1'b1;
        CSR_EN = 1'b0;
        CSR_USE_IMM = 1'b0;
        CSR_CMD = 2'b00;
        // The top level turns this into an illegal-instruction trap instead of
        // letting unsupported encodings fall through as harmless NOPs.
        LEGAL_INSTR = 1'b1; // assume legal until proven otherwise by case statement
        
        // Case statement depending on the opcode for the 
        // instruction, or the last seven bits of each instruction
        case(IR_OPCODE)
            7'b0110011: begin //R-type
                ALU_SRCA = 1'b0; //Select RS1 for ALU source A
                ALU_SRCB = 2'b00; //Select RS2 for ALU source B
                RF_WR_SEL = 2'b11; //Select ALU output for register file write data

                // funct7 = 0000001 selects the RV32M multiply/divide family.
                if (IR_FUNCT7 == 7'b0000001) begin
                    unique case (IR_FUNCT)
                        3'b000: ALU_FUN = 5'b10000; // mul
                        3'b001: ALU_FUN = 5'b10001; // mulh
                        3'b010: ALU_FUN = 5'b10010; // mulhsu
                        3'b011: ALU_FUN = 5'b10011; // mulhu
                        3'b100: ALU_FUN = 5'b10100; // div
                        3'b101: ALU_FUN = 5'b10101; // divu
                        3'b110: ALU_FUN = 5'b10110; // rem
                        3'b111: ALU_FUN = 5'b10111; // remu
                        default: ALU_FUN = 5'b00000;
                    endcase
                end else if ((IR_FUNCT7 == 7'b0000000) ||
                             ((IR_FUNCT7 == 7'b0100000) &&
                              ((IR_FUNCT == 3'b000) || (IR_FUNCT == 3'b101)))) begin 
                    // Standard RV32I ALU encoding covers most instructions, but the SUB and SRA instructions use funct7=0100000 to distinguish from ADD and SRL.
                    ALU_FUN = {1'b0, IR_30, IR_FUNCT}; // Base RV32I ALU encoding
                end else begin
                    LEGAL_INSTR = 1'b0; // Any other funct7 value is illegal for R-type instructions
                    REGWRITE = 1'b0; // Don't write to the register file if the instruction is illegal
                end
            end

            7'b0010011: begin // I-type ALU operations
                ALU_SRCA = 1'b0; // Select RS1 for ALU source A
                ALU_SRCB = 2'b01; // Select immediate for ALU source B
                RF_WR_SEL = 2'b11; // Select ALU output for register file write data
                unique case (IR_FUNCT) 
                    3'b001: begin // slliw, slli, srliw, srli, sraiw, srai
                        if (IR_FUNCT7 == 7'b0000000)
                            ALU_FUN = 5'b00001;
                        else begin
                            LEGAL_INSTR = 1'b0; // Only the shift-left-immediate instructions use funct7=0000000, so any other funct7 value is illegal for these operations.
                            REGWRITE = 1'b0;
                        end
                    end
                    3'b101: begin
                        if ((IR_FUNCT7 == 7'b0000000) || (IR_FUNCT7 == 7'b0100000)) begin // srli and srai share the same encoding except for bit 30, which is 0 for srli and 1 for srai
                            ALU_FUN[4] = 1'b0;
                            ALU_FUN[3] = IR_30;
                            ALU_FUN[2:0] = IR_FUNCT;
                        end else begin
                            LEGAL_INSTR = 1'b0; // same logic to above coding
                            REGWRITE = 1'b0;
                        end
                    end
                    3'b000, 3'b010, 3'b011, 3'b100, 3'b110, 3'b111: begin // addi, slti, sltiu, xori, ori, andi
                        ALU_FUN[4] = 1'b0;
                        ALU_FUN[3] = 1'b0;
                        ALU_FUN[2:0] = IR_FUNCT;
                    end
                    default: begin
                        LEGAL_INSTR = 1'b0; // Any funct3 value other than the six listed above is illegal for I-type ALU instructions
                        REGWRITE = 1'b0;
                    end
                endcase
            end

            7'b0000011: begin // I-type load instructions
                ALU_SRCA = 1'b0; // Select RS1 for ALU source A
                ALU_SRCB = 2'b01; // Select immediate for ALU source B
                RF_WR_SEL = 2'b10; // Select memory output for register file write data
                MEM_RD_EN2 = 1'b1; // Enable memory read
                ALU_FUN = 5'b00000; // Use ALU to calculate memory address (base + offset)
                if ((IR_FUNCT != 3'b000) && (IR_FUNCT != 3'b001) &&
                    (IR_FUNCT != 3'b010) && (IR_FUNCT != 3'b100) &&
                    (IR_FUNCT != 3'b101)) begin // Only LB, LH, LW, LBU, and LHU are legal load instructions, so any other funct3 value is illegal.
                    LEGAL_INSTR = 1'b0;
                    MEM_RD_EN2 = 1'b0;
                    REGWRITE = 1'b0;
                end
            end

            7'b0100011: begin // S-type store instructions
                ALU_SRCA = 1'b0; // Select RS1 for ALU source A
                ALU_SRCB = 2'b10; // Select immediate for ALU source B
                MEM_WR_EN2 = 1'b1; // Enable memory write
                ALU_FUN = 5'b00000; // Use ALU to calculate memory address (base + offset)
                REGWRITE = 1'b0; // No register write for store instructions
                if ((IR_FUNCT != 3'b000) && (IR_FUNCT != 3'b001) &&
                    (IR_FUNCT != 3'b010)) begin // same logic as above coding
                    LEGAL_INSTR = 1'b0;
                    MEM_WR_EN2 = 1'b0;
                end
            end

            7'b1100011: begin // B-type branch instructions
                ALU_SRCA = 1'b0; // Select RS1 for ALU source A
                ALU_SRCB = 2'b00; // Select RS2 for ALU source B
                RF_WR_SEL = 2'b11; // Select ALU output for register file write data (though it won't be written)
                ALU_FUN = 5'b00000; // Use ADD operation in ALU to compare RS1 and RS2 for branch decision
                REGWRITE = 1'b0; // No register write for branch instructions
                if ((IR_FUNCT != 3'b000) && (IR_FUNCT != 3'b001) &&
                    (IR_FUNCT != 3'b100) && (IR_FUNCT != 3'b101) &&
                    (IR_FUNCT != 3'b110) && (IR_FUNCT != 3'b111)) // same logic
                    LEGAL_INSTR = 1'b0;
            end

            7'b1101111: begin // J-type JAL instruction
                RF_WR_SEL = 2'b00; // Select PC+4 for register file write data
            end

            7'b1100111: begin // I-type JALR instruction
                RF_WR_SEL = 2'b00; // Select PC+4 for register file write data
                if (IR_FUNCT != 3'b000) begin
                    LEGAL_INSTR = 1'b0;
                    REGWRITE = 1'b0;
                end
            end

            7'b0110111: begin //U-type LUI instruction
                ALU_SRCA = 1'b1; //Select PC for ALU source A (though it won't actually be used)
                RF_WR_SEL = 2'b11; //Select ALU output for register file write data
                ALU_FUN = 5'b01001; //Use ALU to pass through the immediate value (since LUI just loads the immediate into the register)
            end

            7'b0010111: begin //U-type AUIPC instruction
                ALU_SRCA = 1'b1; //Select PC for ALU source A
                ALU_SRCB = 2'b11; //Select U-type immediate for ALU source B
                RF_WR_SEL = 2'b11; //Select ALU output for register file write data
                ALU_FUN = 5'b00000; //Use ALU to calculate address (PC + immediate)
            end

            7'b0001111: begin // FENCE / FENCE.I
                REGWRITE = 1'b0;
                // Plain FENCE is a no-op here, but FENCE.I must still decode cleanly
                // so the top level can drain memory traffic and invalidate the I$.
                if ((IR_FUNCT != 3'b000) && (IR_FUNCT != 3'b001))
                    LEGAL_INSTR = 1'b0;
            end

            7'b1110011: begin // SYSTEM / CSR
                if (IR_FUNCT != 3'b000) begin
                    // CSR instructions return the old CSR value via the normal "ALU result" writeback path.
                    RF_WR_SEL = 2'b11;
                    REGWRITE = 1'b1;
                    CSR_EN = 1'b1; 
                    CSR_USE_IMM = IR_FUNCT[2]; // The CSRRWI instruction uses the I-type immediate encoding for the CSR address, while CSRRW, CSRRS, and CSRRC use the standard rs1 encoding, so we can directly use funct3 bit 2 to determine this.
                    CSR_CMD = IR_FUNCT[1:0]; // The four CSR commands (read, write, set bits, clear bits) are encoded in funct3 bits 1:0, so we can directly assign those to the CSR_CMD output.
                end else begin
                    // ECALL/EBREAK/MRET stay in ID because they redirect control and/or
                    // update trap CSRs before the instruction would reach WB.
                    REGWRITE = 1'b0;
                end
            end

            default: begin
                LEGAL_INSTR = 1'b0; // Any opcode not explicitly handled above is illegal
                REGWRITE = 1'b0; // Don't write to the register file if the instruction is illegal
            end
        endcase
    end
    
endmodule
// i love cpe333
