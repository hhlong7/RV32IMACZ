`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: DispatchDecode
// Description:
//   Full decode of one dispatch slot for the out-of-order core: which unit
//   executes it, which registers it reads and writes, whether it serializes
//   (executes at the ROB head with the ROB otherwise empty), and whether it
//   raises an exception at commit (illegal instruction, ecall, ebreak).
//////////////////////////////////////////////////////////////////////////////////
module DispatchDecode
    import otter_defs_pkg::*;
    import ooo_pkg::*;
(
    input  logic [31:0] ir,
    input  logic [31:0] raw_ir,       // as fetched (mtval for illegal instructions)
    input  logic [31:0] pc,
    input  logic [2:0]  frm,
    input  logic [1:0]  fs,
    input  logic        csr_illegal,  // CSR file's verdict for this slot's CSR address

    output logic [3:0]  cls,          // CLS_* execution unit
    output logic [2:0]  sys,          // SYS_* serializing kind
    output logic        exception,
    output logic [31:0] cause,
    output logic [31:0] tval,
    output logic [1:0]  dst,          // DST_* destination register file
    output logic [4:0]  rd,
    output logic [1:0]  src1_kind,    // DST_* encoding: none, x register, f register
    output logic [1:0]  src2_kind,
    output logic        alu_src_a,
    output logic [1:0]  alu_src_b,
    output logic [4:0]  alu_fun,
    output logic        mem_load,
    output logic        mem_store,
    output logic        mem_atomic,
    output logic [3:0]  atomic_op,
    output logic        fp_sub,
    output logic        fp_arith,
    output logic [2:0]  fp_rm,
    output logic        is_control,
    output logic        csr_write_attempt,
    // An FP CSR access that need not serialize: any fflags access, or a read
    // of frm/fcsr. It reads its CSR at the ROB head (after every older FP op
    // has accrued its flags) without draining the ROB or blocking younger
    // dispatch. Writes to frm/fcsr still serialize: younger instructions
    // read frm at decode for dynamic rounding.
    output logic        csr_nonserial
);
    localparam logic [31:0] MCAUSE_ILLEGAL = 32'd2;
    localparam logic [31:0] MCAUSE_BREAKPOINT = 32'd3;
    localparam logic [31:0] MCAUSE_ECALL_M = 32'd11;

    logic regwrite, mem_rd, mem_wr, legal, csr_en, csr_use_imm;
    logic [1:0] csr_cmd, rf_wr_sel;
    logic atomic_valid, atomic_legal, atomic_aq, atomic_rl;
    logic fp_instr, fp_load, fp_store, fp_write, uses_frs1, uses_frs2, fp_dyn_rm, fp_illegal;
    logic [1:0] fp_unit;
    logic ecall, ebreak, mret, wfi, fence, fence_i, system_priv;
    logic [6:0] opcode;

    CU_DCDR BASE (
        .IR_30(ir[30]),
        .IR_OPCODE(ir[6:0]),
        .IR_FUNCT(ir[14:12]),
        .IR_FUNCT7(ir[31:25]),
        .ALU_SRCA(alu_src_a),
        .ALU_SRCB(alu_src_b),
        .ALU_FUN(alu_fun),
        .RF_WR_SEL(rf_wr_sel),
        .MEM_WR_EN2(mem_wr),
        .MEM_RD_EN2(mem_rd),
        .REGWRITE(regwrite),
        .CSR_EN(csr_en),
        .CSR_USE_IMM(csr_use_imm),
        .CSR_CMD(csr_cmd),
        .LEGAL_INSTR(legal)
    );

    FPDecode FP (
        .ir_i(ir),
        .frm_i(frm),
        .fs_i(fs),
        .fp_instr_o(fp_instr),
        .fp_load_o(fp_load),
        .fp_store_o(fp_store),
        .fp_unit_o(fp_unit),
        .fp_sub_o(fp_sub),
        .fp_write_o(fp_write),
        .uses_frs1_o(uses_frs1),
        .uses_frs2_o(uses_frs2),
        .dyn_rm_o(fp_dyn_rm),
        .rm_o(fp_rm),
        .illegal_o(fp_illegal)
    );

    AtomicDecode AMO (
        .instr_valid_i(1'b1),
        .ir_i(ir),
        .atomic_valid_o(atomic_valid),
        .atomic_op_o(atomic_op),
        .atomic_aq_o(atomic_aq),
        .atomic_rl_o(atomic_rl),
        .atomic_legal_o(atomic_legal)
    );

    assign opcode = ir[6:0];
    // Privileged SYSTEM instructions are fully specified encodings.
    assign ecall = (ir == 32'h0000_0073);
    assign ebreak = (ir == 32'h0010_0073);
    assign mret = (ir == 32'h3020_0073);
    assign wfi = (ir == 32'h1050_0073);
    assign system_priv = (opcode == OPC_SYSTEM) && (ir[14:12] == 3'b000);
    assign fence = (opcode == OPC_MISC_MEM) && (ir[14:12] == 3'b000);
    assign fence_i = (opcode == OPC_MISC_MEM) && (ir[14:12] == 3'b001);
    assign rd = ir[11:7];
    assign fp_arith = (fp_unit != FP_UNIT_NONE);
    assign is_control = (opcode == OPC_BRANCH) || (opcode == OPC_JAL) ||
                        ((opcode == OPC_JALR) && (ir[14:12] == 3'b000));
    // CSRRS/CSRRC with rs1 = x0 (or a zero uimm) read without writing.
    assign csr_write_attempt = csr_en && ((csr_cmd == 2'b01) || (ir[19:15] != 5'd0));
    assign csr_nonserial = csr_en && ((ir[31:20] == 12'h001) ||
                                      (((ir[31:20] == 12'h002) || (ir[31:20] == 12'h003)) && !csr_write_attempt));

    always_comb begin
        logic illegal;

        illegal = atomic_valid ? !atomic_legal : !legal;
        illegal |= csr_en && csr_illegal;
        illegal |= system_priv && !(ecall || ebreak || mret || wfi);
        illegal |= fp_illegal;

        exception = illegal || ecall || ebreak;
        cause = illegal ? MCAUSE_ILLEGAL : ebreak ? MCAUSE_BREAKPOINT : MCAUSE_ECALL_M;
        tval = illegal ? raw_ir : ebreak ? pc : 32'b0;

        // Execution unit.
        cls = CLS_ALU;
        if (exception || system_priv || fence || fence_i || csr_en)
            cls = CLS_NONE;
        else if (atomic_valid || mem_rd || mem_wr)
            cls = CLS_MEM;
        else if (is_control)
            cls = CLS_BRANCH;
        else if (opcode == OPC_OP && ir[31:25] == 7'b0000001)
            cls = ir[14] ? CLS_IDIV : CLS_IMUL;   // RV32M: funct3[2] = divide
        else if (fp_unit == FP_UNIT_ADD)
            cls = CLS_FPADD;
        else if (fp_unit == FP_UNIT_MUL)
            cls = CLS_FPMUL;
        else if (fp_unit == FP_UNIT_DIV)
            cls = CLS_FPDIV;

        sys = SYS_NONE;
        if (!exception) begin
            if (csr_en) sys = SYS_CSR;
            else if (mret) sys = SYS_MRET;
            else if (wfi) sys = SYS_WFI;
            else if (fence) sys = SYS_FENCE;
            else if (fence_i) sys = SYS_FENCE_I;
            else if (atomic_valid) sys = SYS_ATOMIC;
        end

        // Destination.
        dst = DST_NONE;
        if (!exception) begin
            if (fp_write)
                dst = DST_FP;
            else if ((regwrite || atomic_valid || csr_en) && rd != 5'd0)
                dst = DST_INT;
        end

        // Sources.
        src1_kind = DST_NONE;
        src2_kind = DST_NONE;
        unique case (opcode)
            OPC_OP: begin src1_kind = DST_INT; src2_kind = DST_INT; end
            OPC_OP_IMM, OPC_LOAD, OPC_JALR, OPC_LOAD_FP: src1_kind = DST_INT;
            OPC_STORE, OPC_BRANCH: begin src1_kind = DST_INT; src2_kind = DST_INT; end
            OPC_STORE_FP: begin src1_kind = DST_INT; src2_kind = DST_FP; end
            OPC_AMO: begin
                src1_kind = DST_INT;
                src2_kind = (atomic_op == ATOMIC_LR) ? DST_NONE : DST_INT;
            end
            OPC_OP_FP: begin src1_kind = DST_FP; src2_kind = DST_FP; end
            OPC_SYSTEM: src1_kind = (csr_en && !csr_use_imm) ? DST_INT : DST_NONE;
            default: ;
        endcase
        if (exception) begin
            src1_kind = DST_NONE;
            src2_kind = DST_NONE;
        end

        mem_load = (mem_rd && !atomic_valid) || fp_load;
        mem_store = (mem_wr && !atomic_valid) || fp_store;
        mem_atomic = atomic_valid && !exception;
    end
endmodule
