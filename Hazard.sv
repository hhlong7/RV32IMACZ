`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: California Polytechnic University, San Luis Obispo
// Engineer: Long Ho
// Create Date: 02/23/2023 09:39:49 AM
// Module Name: Hazard
//////////////////////////////////////////////////////////////////////////////////

module Hazard(
    // Oldest decode slot.
    input  logic        valid_if_id,
    input  logic [6:0]  opcode_if_id,
    input  logic [2:0]  funct3_if_id,
    input  logic [4:0]  rs1_if_id,
    input  logic [4:0]  rs2_if_id,
    input  logic        csrRead_if_id,
    input  logic [11:0] csrAddr_if_id,
    input  logic        machineCtrl_if_id,
    input  logic        regWrite_if_id,
    input  logic [4:0]  rd_if_id,
    input  logic        blocksPair_if_id,

    // Younger decode slot that may issue in parallel with the oldest slot.
    input  logic        valid_if_pair,
    input  logic [6:0]  opcode_if_pair,
    input  logic [2:0]  funct3_if_pair,
    input  logic [4:0]  rs1_if_pair,
    input  logic [4:0]  rs2_if_pair,
    input  logic        regWrite_if_pair,
    input  logic [4:0]  rd_if_pair,
    input  logic        pairCandidate_if_pair,

    // ID/EX stage info (one cycle ahead of decode). Either slot can be older.
    input  logic        valid_id_ex,
    input  logic [4:0]  rd_id_ex,
    input  logic        memRead_id_ex,
    input  logic        csrWrite_id_ex,
    input  logic [11:0] csrAddr_id_ex,

    input  logic        valid_id_ex_pair,
    input  logic [4:0]  rd_id_ex_pair,
    input  logic        memRead_id_ex_pair,
    input  logic        csrWrite_id_ex_pair,
    input  logic [11:0] csrAddr_id_ex_pair,

    // Older CSR writers still block decode-time CSR reads and machine-control ops.
    input  logic        valid_ex1_ex2,
    input  logic        csrWrite_ex1_ex2,
    input  logic [11:0] csrAddr_ex1_ex2,
    input  logic        valid_ex1_ex2_pair,
    input  logic        csrWrite_ex1_ex2_pair,
    input  logic [11:0] csrAddr_ex1_ex2_pair,

    input  logic        valid_ex_mem,
    input  logic        csrWrite_ex_mem,
    input  logic [11:0] csrAddr_ex_mem,
    input  logic        valid_ex_mem_pair,
    input  logic        csrWrite_ex_mem_pair,
    input  logic [11:0] csrAddr_ex_mem_pair,

    input  logic        valid_mem_wb,
    input  logic        csrWrite_mem_wb,
    input  logic [11:0] csrAddr_mem_wb,
    input  logic        valid_mem_wb_pair,
    input  logic        csrWrite_mem_wb_pair,
    input  logic [11:0] csrAddr_mem_wb_pair,

    output logic stallIF,
    output logic stallID,
    output logic flushEX,
    output logic loadUseStall,
    output logic issuePair
);

    logic uses_rs1_if_id;
    logic uses_rs2_if_id;
    logic uses_rs1_if_pair;
    logic uses_rs2_if_pair;

    logic load_block_if_id;
    logic load_block_if_pair;
    logic csr_block_if_id;
    logic machine_block_if_id;
    logic same_bundle_dep;

    function automatic logic opcode_uses_rs1(
        input logic [6:0] opcode,
        input logic [2:0] funct3
    );
        begin
            opcode_uses_rs1 = 1'b0;
            unique case (opcode)
                7'b0110011: opcode_uses_rs1 = 1'b1; // R-type
                7'b0010011, // I-type ALU
                7'b0000011, // loads
                7'b0101111, // atomics
                7'b0100011, // stores
                7'b1100011, // branches
                7'b1100111: opcode_uses_rs1 = 1'b1; // JALR
                7'b1110011: opcode_uses_rs1 = (funct3 != 3'b000) && ~funct3[2];
                default: opcode_uses_rs1 = 1'b0;
            endcase
        end
    endfunction

    function automatic logic opcode_uses_rs2(
        input logic [6:0] opcode
    );
        begin
            opcode_uses_rs2 = 1'b0;
            unique case (opcode)
                7'b0110011, // R-type
                7'b0101111, // atomics (LR encodes rs2=x0, which is harmless here)
                7'b0100011, // stores
                7'b1100011: opcode_uses_rs2 = 1'b1; // branches
                default: opcode_uses_rs2 = 1'b0;
            endcase
        end
    endfunction

    always_comb begin
        uses_rs1_if_id = opcode_uses_rs1(opcode_if_id, funct3_if_id);
        uses_rs2_if_id = opcode_uses_rs2(opcode_if_id);
        uses_rs1_if_pair = opcode_uses_rs1(opcode_if_pair, funct3_if_pair);
        uses_rs2_if_pair = opcode_uses_rs2(opcode_if_pair);

        load_block_if_id = 1'b0;
        load_block_if_pair = 1'b0;
        csr_block_if_id = 1'b0;
        machine_block_if_id = 1'b0;
        same_bundle_dep = 1'b0;

        stallIF = 1'b0;
        stallID = 1'b0;
        flushEX = 1'b0;
        loadUseStall = 1'b0;
        issuePair = 1'b0;

        // Either older EX-bound slot can hold a load whose result is not ready
        // for the current decode bundle yet.
        if (valid_if_id && valid_id_ex && memRead_id_ex && (rd_id_ex != 5'd0) &&
            ((uses_rs1_if_id && (rs1_if_id == rd_id_ex)) ||
             (uses_rs2_if_id && (rs2_if_id == rd_id_ex))))
            load_block_if_id = 1'b1;

        if (valid_if_id && valid_id_ex_pair && memRead_id_ex_pair && (rd_id_ex_pair != 5'd0) &&
            ((uses_rs1_if_id && (rs1_if_id == rd_id_ex_pair)) ||
             (uses_rs2_if_id && (rs2_if_id == rd_id_ex_pair))))
            load_block_if_id = 1'b1;

        if (valid_if_pair && valid_id_ex && memRead_id_ex && (rd_id_ex != 5'd0) &&
            ((uses_rs1_if_pair && (rs1_if_pair == rd_id_ex)) ||
             (uses_rs2_if_pair && (rs2_if_pair == rd_id_ex))))
            load_block_if_pair = 1'b1;

        if (valid_if_pair && valid_id_ex_pair && memRead_id_ex_pair && (rd_id_ex_pair != 5'd0) &&
            ((uses_rs1_if_pair && (rs1_if_pair == rd_id_ex_pair)) ||
             (uses_rs2_if_pair && (rs2_if_pair == rd_id_ex_pair))))
            load_block_if_pair = 1'b1;

        if (valid_if_id && csrRead_if_id &&
            ((valid_id_ex && csrWrite_id_ex && (csrAddr_if_id == csrAddr_id_ex)) ||
             (valid_id_ex_pair && csrWrite_id_ex_pair && (csrAddr_if_id == csrAddr_id_ex_pair)) ||
             (valid_ex1_ex2 && csrWrite_ex1_ex2 && (csrAddr_if_id == csrAddr_ex1_ex2)) ||
             (valid_ex1_ex2_pair && csrWrite_ex1_ex2_pair && (csrAddr_if_id == csrAddr_ex1_ex2_pair)) ||
             (valid_ex_mem && csrWrite_ex_mem && (csrAddr_if_id == csrAddr_ex_mem)) ||
             (valid_ex_mem_pair && csrWrite_ex_mem_pair && (csrAddr_if_id == csrAddr_ex_mem_pair)) ||
             (valid_mem_wb && csrWrite_mem_wb && (csrAddr_if_id == csrAddr_mem_wb)) ||
             (valid_mem_wb_pair && csrWrite_mem_wb_pair && (csrAddr_if_id == csrAddr_mem_wb_pair))))
            csr_block_if_id = 1'b1;

        if (valid_if_id && machineCtrl_if_id &&
            ((valid_id_ex && csrWrite_id_ex &&
              ((csrAddr_id_ex == 12'h300) || (csrAddr_id_ex == 12'h305) || (csrAddr_id_ex == 12'h341))) ||
             (valid_id_ex_pair && csrWrite_id_ex_pair &&
              ((csrAddr_id_ex_pair == 12'h300) || (csrAddr_id_ex_pair == 12'h305) || (csrAddr_id_ex_pair == 12'h341))) ||
             (valid_ex1_ex2 && csrWrite_ex1_ex2 &&
              ((csrAddr_ex1_ex2 == 12'h300) || (csrAddr_ex1_ex2 == 12'h305) || (csrAddr_ex1_ex2 == 12'h341))) ||
             (valid_ex1_ex2_pair && csrWrite_ex1_ex2_pair &&
              ((csrAddr_ex1_ex2_pair == 12'h300) || (csrAddr_ex1_ex2_pair == 12'h305) || (csrAddr_ex1_ex2_pair == 12'h341))) ||
             (valid_ex_mem && csrWrite_ex_mem &&
              ((csrAddr_ex_mem == 12'h300) || (csrAddr_ex_mem == 12'h305) || (csrAddr_ex_mem == 12'h341))) ||
             (valid_ex_mem_pair && csrWrite_ex_mem_pair &&
              ((csrAddr_ex_mem_pair == 12'h300) || (csrAddr_ex_mem_pair == 12'h305) || (csrAddr_ex_mem_pair == 12'h341))) ||
             (valid_mem_wb && csrWrite_mem_wb &&
              ((csrAddr_mem_wb == 12'h300) || (csrAddr_mem_wb == 12'h305) || (csrAddr_mem_wb == 12'h341))) ||
             (valid_mem_wb_pair && csrWrite_mem_wb_pair &&
              ((csrAddr_mem_wb_pair == 12'h300) || (csrAddr_mem_wb_pair == 12'h305) || (csrAddr_mem_wb_pair == 12'h341)))))
            machine_block_if_id = 1'b1;

        // Slot 1 cannot consume or overwrite a destination that slot 0 is
        // still producing inside the same issue bundle.
        if (valid_if_pair && regWrite_if_id && (rd_if_id != 5'd0) &&
            (((uses_rs1_if_pair && (rs1_if_pair == rd_if_id)) ||
              (uses_rs2_if_pair && (rs2_if_pair == rd_if_id))) ||
             (regWrite_if_pair && (rd_if_pair == rd_if_id))))
            same_bundle_dep = 1'b1;

        if (load_block_if_id || csr_block_if_id || machine_block_if_id) begin
            stallIF = 1'b1;
            stallID = 1'b1;
            flushEX = 1'b1;
            loadUseStall = load_block_if_id;
        end

        // Younger issue is intentionally conservative: only pair a prequalified
        // simple instruction when it is independent of the older slot and not
        // blocked by a one-cycle-ahead load.
        if (valid_if_id && valid_if_pair && pairCandidate_if_pair &&
            ~blocksPair_if_id && ~same_bundle_dep && ~load_block_if_pair &&
            ~(csr_block_if_id || machine_block_if_id || load_block_if_id))
            issuePair = 1'b1;
    end
endmodule
// i love cpe333
