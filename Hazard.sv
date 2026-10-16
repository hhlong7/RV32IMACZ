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
    input  logic        usesFrs1_if_id,   // reads FP source registers
    input  logic        usesFrs2_if_id,

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

    // FP state still in flight: an FP register write in EX1 (its result is
    // not ready, and it marks mstatus.FS Dirty as it leaves EX1), and FP
    // arithmetic anywhere from EX1 to WB (its flags reach fflags at WB).
    input  logic        fpWrite_id_ex,
    input  logic        fpFlagsPending,

    output logic stallIF,
    output logic stallID,
    output logic flushEX,
    output logic loadUseStall,
    output logic issuePair
);

    import otter_defs_pkg::*;

    logic uses_rs1_if_id;
    logic uses_rs2_if_id;
    logic uses_rs1_if_pair;
    logic uses_rs2_if_pair;

    logic load_block_if_id;
    logic fp_block_if_id;
    logic fp_state_block_if_id;
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
                OPC_OP: opcode_uses_rs1 = 1'b1; // R-type
                OPC_OP_IMM, // I-type ALU
                OPC_LOAD, // loads
                OPC_AMO, // atomics
                OPC_STORE, // stores
                OPC_LOAD_FP, // flw/fsw base address
                OPC_STORE_FP,
                OPC_BRANCH, // branches
                OPC_JALR: opcode_uses_rs1 = 1'b1; // JALR
                OPC_SYSTEM: opcode_uses_rs1 = (funct3 != 3'b000) && ~funct3[2];
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
                OPC_OP, // R-type
                OPC_AMO, // atomics (LR encodes rs2=x0, which is harmless here)
                OPC_STORE, // stores
                OPC_BRANCH: opcode_uses_rs2 = 1'b1; // branches
                default: opcode_uses_rs2 = 1'b0;
            endcase
        end
    endfunction

    // True when a read of CSR `read` must wait for an older write of CSR
    // `write`: the same CSR, the FP CSRs that alias one another (fcsr holds
    // frm and fflags), or mstatus, whose FS field any FP CSR write sets Dirty.
    function automatic logic csr_conflict(input logic [11:0] read, input logic [11:0] write);
        logic read_fp, write_fp;
        read_fp = (read == 12'h001) || (read == 12'h002) || (read == 12'h003);
        write_fp = (write == 12'h001) || (write == 12'h002) || (write == 12'h003);
        csr_conflict = (read == write) ||
                       (read_fp && write_fp && ((read == 12'h003) || (write == 12'h003))) ||
                       ((read == 12'h300) && write_fp);
    endfunction

    // CSRs that trap entry or MRET read (mstatus, mtvec, mepc) or write
    // (mstatus, mepc, mcause, mtval) directly, bypassing the WB write port.
    function automatic logic is_trap_csr(input logic [11:0] addr);
        is_trap_csr = (addr == 12'h300) || (addr == 12'h305) || (addr == 12'h341) ||
                      (addr == 12'h342) || (addr == 12'h343);
    endfunction

    // True when a consumer of (rs1, rs2) needs the result of an in-flight load
    // to rd that will not be ready in time for EX1.
    function automatic logic needs_load(input logic uses_rs1, input logic [4:0] rs1,
                                        input logic uses_rs2, input logic [4:0] rs2,
                                        input logic load_valid, input logic [4:0] load_rd);
        needs_load = load_valid && (load_rd != 5'd0) &&
                     ((uses_rs1 && (rs1 == load_rd)) || (uses_rs2 && (rs2 == load_rd)));
    endfunction

    // Older CSR writers in either lane, from ID/EX through MEM/WB.
    localparam int CSR_STAGES = 8;
    logic [CSR_STAGES-1:0] older_csr_write;
    logic [CSR_STAGES-1:0][11:0] older_csr_addr;

    assign older_csr_write = {valid_id_ex && csrWrite_id_ex,       valid_id_ex_pair && csrWrite_id_ex_pair,
                              valid_ex1_ex2 && csrWrite_ex1_ex2,   valid_ex1_ex2_pair && csrWrite_ex1_ex2_pair,
                              valid_ex_mem && csrWrite_ex_mem,     valid_ex_mem_pair && csrWrite_ex_mem_pair,
                              valid_mem_wb && csrWrite_mem_wb,     valid_mem_wb_pair && csrWrite_mem_wb_pair};
    assign older_csr_addr = {csrAddr_id_ex,   csrAddr_id_ex_pair,
                             csrAddr_ex1_ex2, csrAddr_ex1_ex2_pair,
                             csrAddr_ex_mem,  csrAddr_ex_mem_pair,
                             csrAddr_mem_wb,  csrAddr_mem_wb_pair};

    assign uses_rs1_if_id = opcode_uses_rs1(opcode_if_id, funct3_if_id);
    assign uses_rs2_if_id = opcode_uses_rs2(opcode_if_id);
    assign uses_rs1_if_pair = opcode_uses_rs1(opcode_if_pair, funct3_if_pair);
    assign uses_rs2_if_pair = opcode_uses_rs2(opcode_if_pair);

    // A load in EX1 (either lane) has no data until MEM: one bubble.
    assign load_block_if_id = valid_if_id &&
        (needs_load(uses_rs1_if_id, rs1_if_id, uses_rs2_if_id, rs2_if_id, valid_id_ex && memRead_id_ex, rd_id_ex) ||
         needs_load(uses_rs1_if_id, rs1_if_id, uses_rs2_if_id, rs2_if_id, valid_id_ex_pair && memRead_id_ex_pair, rd_id_ex_pair));
    assign load_block_if_pair = valid_if_pair &&
        (needs_load(uses_rs1_if_pair, rs1_if_pair, uses_rs2_if_pair, rs2_if_pair, valid_id_ex && memRead_id_ex, rd_id_ex) ||
         needs_load(uses_rs1_if_pair, rs1_if_pair, uses_rs2_if_pair, rs2_if_pair, valid_id_ex_pair && memRead_id_ex_pair, rd_id_ex_pair));

    // CSRs are read in ID but written in WB, so a CSR read waits for older
    // writes to the same CSR; anything that may trap or MRET waits for older
    // writes to the trap CSRs.
    always_comb begin
        csr_block_if_id = 1'b0;
        machine_block_if_id = 1'b0;
        for (int i = 0; i < CSR_STAGES; i++) begin
            if (older_csr_write[i]) begin
                csr_block_if_id |= csr_conflict(csrAddr_if_id, older_csr_addr[i]);
                machine_block_if_id |= is_trap_csr(older_csr_addr[i]);
            end
        end
        csr_block_if_id &= valid_if_id && csrRead_if_id;
        machine_block_if_id &= valid_if_id && machineCtrl_if_id;
    end

    // An FP result is ready in MEM, one stage later than an ALU result, so
    // an FP consumer directly behind its producer waits one cycle (f0 is a
    // real register, unlike x0).
    assign fp_block_if_id = valid_if_id && fpWrite_id_ex && valid_id_ex &&
                            ((usesFrs1_if_id && (rs1_if_id == rd_id_ex)) ||
                             (usesFrs2_if_id && (rs2_if_id == rd_id_ex)));

    // Reads of FP state that is still being produced: mstatus while an FP
    // register write is about to set FS Dirty, fflags/fcsr while older FP
    // arithmetic has not yet recorded its flags.
    assign fp_state_block_if_id = valid_if_id && csrRead_if_id &&
                                  (((csrAddr_if_id == 12'h300) && fpWrite_id_ex) ||
                                   (((csrAddr_if_id == 12'h001) || (csrAddr_if_id == 12'h003)) && fpFlagsPending));

    // Slot 1 cannot consume or overwrite a destination that slot 0 is still
    // producing inside the same issue bundle.
    assign same_bundle_dep = valid_if_pair && regWrite_if_id && (rd_if_id != 5'd0) &&
                             ((uses_rs1_if_pair && (rs1_if_pair == rd_if_id)) ||
                              (uses_rs2_if_pair && (rs2_if_pair == rd_if_id)) ||
                              (regWrite_if_pair && (rd_if_pair == rd_if_id)));

    assign loadUseStall = load_block_if_id;
    assign stallIF = load_block_if_id || csr_block_if_id || machine_block_if_id ||
                     fp_block_if_id || fp_state_block_if_id;
    assign stallID = stallIF;
    assign flushEX = stallIF;

    // Pair only a prequalified simple instruction that is independent of the
    // older slot and not waiting on a load.
    assign issuePair = valid_if_id && valid_if_pair && pairCandidate_if_pair &&
                       ~blocksPair_if_id && ~same_bundle_dep && ~load_block_if_pair && ~stallIF;
endmodule
// i love cpe333
