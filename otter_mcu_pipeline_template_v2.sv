`timescale 1ns/1ps
/////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer: Long
//
// Create Date: 01/20/2019 10:36:50 AM
// Module Name: OTTER_MCU
// Description: Seven-stage RV32IMAC in-order core with a 2-slot front-end queue
//              and restricted dual issue. Slot 0 keeps full architectural
//              behavior (control/CSR/traps/memory), while slot 1 may issue a
//              younger simple integer instruction in parallel when pairing
//              rules and hazards say the bundle is safe.
/////////////////////////////////////////////////////////////////////////////

module OTTER_MCU(
    input logic CLK,
    input logic INTR,
    input logic RESET,
    input logic [31:0] IOBUS_IN,

    output logic IOBUS_WR,
    output logic [31:0] IOBUS_OUT,
    output logic [31:0] IOBUS_ADDR
);

    import otter_defs_pkg::*;

    typedef struct packed {
        logic valid;
        logic predicted_taken;
        logic [31:0] predicted_target;

        logic [31:0] pc;
        // Historical field name kept for compatibility with the existing
        // pipeline code. It now carries the architectural fall-through PC.
        logic [31:0] pc_4;
        logic [31:0] ir;

        logic regWrite;
        logic memRead;
        logic memWrite;
        logic [1:0] rf_wr_sel;

        logic alu_src_a;
        logic [1:0] alu_src_b;
        logic [4:0] alu_fun;

        logic csr_en;
        logic csr_use_imm;
        logic [1:0] csr_cmd;
        logic csr_write;
        logic [11:0] csr_addr;
        logic [31:0] csr_rdata;
        logic [31:0] csr_wdata;

        logic [31:0] rs1;
        logic [31:0] rs2;
        logic [31:0] alu_result;
        logic [31:0] mem_data;

        logic trap_taken;
        logic mret;
        logic fence;
        logic fence_i;
        logic atomic_valid;
        logic [3:0] atomic_op;
        logic atomic_aq;
        logic atomic_rl;
        logic [31:0] trap_cause;
        logic [31:0] trap_tval;
    } pipe_t;

    // Front-end queue: if_id is the oldest ready-to-issue slot, and if1_if2 is
    // the next sequential slot buffered behind it.
    frontend_t if_id, if1_if2;
    frontend_t fetch_slot0, fetch_slot1;
    frontend_t fetch_slot0_as_slot1;
    frontend_t if_id_after_issue, if1_if2_after_issue;
    frontend_t if_id_next, if1_if2_next;

    // Slot 0 is the full architectural lane. Slot 1 is restricted to simple
    // integer register-writing work so the core stays in order with one LSU and
    // one control/CSR path.
    pipe_t id_ex, ex1_ex2, ex_mem, mem_wb;
    pipe_t id_ex_pair, ex1_ex2_pair, ex_mem_pair, mem_wb_pair;

//////////////////////////////////////////////////////////////////
    // Front-end / predictor signals

    logic [31:0] pc_out;
    logic [31:0] pc_out_inc;
    logic [31:0] pc_next_fill;
    logic pc_write_fill;
    logic fetch_crossword_wait;

    logic dc_stall;
    logic dc_ctrl_stall;
    logic ic_stall;
    logic pc_stall_cache;
    logic RESETf;

    logic stallIF, stallID, stallIF2, stallEX1;
    logic flushIF2, flushID, flushID_pipe, flushEX;
    logic stallIF_hz, stallID_hz, flushEX_hz;
    logic loadUseStall_hz;
    logic issuePair;
    logic issue_lane0;
    logic fetch_request;

    logic redirect_valid_ex1;
    logic [31:0] redirect_target_ex1;
    logic redirect_pending_valid;
    logic [31:0] redirect_pending_target;

    localparam int BHT_ENTRIES = 16;
    localparam int BTB_ENTRIES = 8;
    localparam int RAS_DEPTH = 4;

    logic [31:0] ras_top;
    logic ras_valid;
    logic btb_hit_if0, btb_hit_if1;
    logic [31:0] btb_target_if0, btb_target_if1;
    logic bht_taken_if0, bht_taken_if1;

    logic [2:0] pc_source_id;

//////////////////////////////////////////////////////////////////
    // Instruction cache path

    logic [31:0] w0, w1, w2, w3, w4, w5, w6, w7;
    logic [31:0] pw0, pw1, pw2, pw3, pw4, pw5, pw6, pw7;
    logic [31:0] rd;
    logic [31:0] rd_next;
    logic [31:0] fetch_slot0_window;
    logic [31:0] fetch_slot1_window;
    logic [31:0] fetch_slot0_ir;
    logic [31:0] fetch_slot1_ir;
    logic fetch_slot0_is_compressed;
    logic fetch_slot1_is_compressed;
    logic fetch_slot0_requires_next_word;
    logic fetch_slot0_ready;
    logic fetch_slot1_enabled;
    logic hit, miss;
    logic hit_raw, miss_raw;
    logic next_valid_raw;
    logic cache_update;
    logic prefetch_hit_event_raw;
    logic prefetch_hit_event;
    logic prefetch_useless_event;

//////////////////////////////////////////////////////////////////
    // Data memory / cache path

    logic mem_sign;
    logic [1:0] mem_size;
    logic [3:0] mem_mask;

    logic [31:0] mem_dout2_mem;
    logic [31:0] mem_dout2;
    logic [31:0] rdata;
    logic dcache_hit, dcache_miss, dcache_cacheable;
    logic dcache_enable_write, dcache_last;
    logic [2:0] dcache_fill_select;

    logic [31:0] dcache_fill_word;
    logic l2_query_hit, l2_query_miss, l2_query_cacheable;
    logic [31:0] l2_line_word;
    logic l2_refill_from_l2;
    logic l2_fill_write, l2_fill_last;
    logic [2:0] l2_fill_select;

    logic mem_rden2_dc, mem_we2_dc;
    logic [31:0] mem_addr2_dc, mem_din2_dc;
    logic [1:0] mem_size_dc;
    logic mem_sign_dc;
    logic dcache_miss_start;
    logic dcache_busy;
    logic storebuf_full;
    logic storebuf_empty;
    logic [31:0] storebuf_drain_addr;
    logic [31:0] storebuf_drain_data;
    logic [3:0] storebuf_drain_mask;
    logic storebuf_drain_valid;
    logic storebuf_drain_accept;
    logic storebuf_forward_hit;
    logic storebuf_forward_conflict;
    logic [31:0] storebuf_forward_word;
    logic [31:0] storebuf_forward_data;
    logic [3:0] storebuf_enqueue_mask;
    logic storebuf_enqueue_event;
    logic storebuf_forward_event;
    logic storebuf_full_stall_event;
    logic storebuf_conflict_stall_event;
    logic storebuf_drain_event;
    logic fence_wait_event;
    logic [2:0] storebuf_occupancy;
    logic [31:0] atomic_mem_result;
    logic [31:0] atomic_preview_word_mem;
    logic [31:0] atomic_forward_preview_q;
    logic atomic_sc_ok;
    logic atomic_write_intent;
    logic atomic_commit_valid;
    logic atomic_commit_write;
    logic [3:0] atomic_commit_op;
    logic atomic_commit_sc_success;
    logic [31:0] atomic_commit_addr;
    logic [31:0] atomic_commit_old_word;
    logic [31:0] atomic_commit_new_word;
    logic reservation_valid_q;
    logic reservation_set_event;
    logic reservation_clear_event;
    logic timer_interrupt_pending;

//////////////////////////////////////////////////////////////////
    // Decode / CSR / trap signals

    logic [31:0] csr_rdata_id;
    logic [31:0] mtvec_csr, mepc_csr;
    logic csr_interrupt_pending;
    logic [31:0] csr_interrupt_cause;
    logic interrupt_accept_id;
    logic csr_read_if_id;
    logic csr_access_illegal_id;
    logic trap_taken_id, mret_id, illegal_instr_id, ecall_id, ebreak_id;
    logic fence_id;
    logic fence_i_id;
    logic atomic_valid_id;
    logic [3:0] atomic_op_id;
    logic atomic_aq_id;
    logic atomic_rl_id;
    logic atomic_legal_id;
    logic atomic_valid_pair_id;
    logic [3:0] atomic_op_pair_id;
    logic atomic_aq_pair_id;
    logic atomic_rl_pair_id;
    logic atomic_legal_pair_id;
    logic legal_instr_de;
    logic csr_write_attempt_id;
    logic instr_present_id;
    logic [31:0] trap_cause_id;
    logic [31:0] trap_tval_id;
    logic [11:0] csr_addr_hazard_id;
    logic csr_en_de;
    logic machine_ctrl_hazard_id;
    logic blocks_pair_id;

    logic [31:0] rs1_val, rs2_val;
    logic [31:0] rs1_pair_val, rs2_pair_val;
    logic [31:0] wd, wd_pair;
    logic [1:0] retire_count_wb;

    logic alu_src_a_base;
    logic [1:0] alu_src_b_base;
    logic [4:0] alu_fun_base;
    logic [1:0] rf_wr_sel_base;
    logic mem_we2_base;
    logic mem_rden2_base;
    logic reg_wr_base;
    logic legal_instr_base;

    logic alu_src_a_de;
    logic [1:0] alu_src_b_de;
    logic [4:0] alu_fun_de;
    logic [1:0] rf_wr_sel_de;
    logic mem_we2;
    logic mem_rden2;
    logic reg_wr_wb;
    logic csr_use_imm_de;
    logic [1:0] csr_cmd_de;

    logic alu_src_a_pair_base;
    logic [1:0] alu_src_b_pair_base;
    logic [4:0] alu_fun_pair_base;
    logic [1:0] rf_wr_sel_pair_base;
    logic mem_we2_pair_base;
    logic mem_rden2_pair_base;
    logic reg_wr_pair_base;
    logic legal_instr_pair_base;

    logic legal_instr_pair_de;
    logic csr_en_pair_de;
    logic csr_use_imm_pair_de;
    logic [1:0] csr_cmd_pair_de;
    logic alu_src_a_pair_de;
    logic [1:0] alu_src_b_pair_de;
    logic [4:0] alu_fun_pair_de;
    logic [1:0] rf_wr_sel_pair_de;
    logic mem_we2_pair;
    logic mem_rden2_pair;
    logic reg_wr_pair_de;
    logic pair_candidate_id;
    logic pair_issue_valid_id;
    logic [31:0] pair_pc_id;
    logic [31:0] pair_pc_4_id;
    logic [31:0] pair_ir_id;
    logic [31:0] pair_rs1_id;
    logic [31:0] pair_rs2_id;
    logic pair_alu_src_a_id;
    logic [1:0] pair_alu_src_b_id;
    logic [4:0] pair_alu_fun_id;
    logic [1:0] pair_rf_wr_sel_id;
    logic pair_reg_write_id;

//////////////////////////////////////////////////////////////////
    // EX1 / EX2 signals

    logic [31:0] Utype, Itype, Stype, Btype, Jtype;
    logic [31:0] Utype_pair, Itype_pair, Stype_pair, Btype_pair, Jtype_pair;
    logic [31:0] rs1f, rs2f, rs1f_pair, rs2f_pair;
    logic [31:0] aluA, aluB, aluA_pair, aluB_pair;
    logic [31:0] alu_result_ex1;
    logic [31:0] alu_result_pair_ex1;
    logic [31:0] exec_result_ex1;
    logic [31:0] ex1_ex2_fwd_data, ex1_ex2_pair_fwd_data;
    logic [31:0] ex_mem_fwd_data, ex_mem_pair_fwd_data;
    logic [31:0] csr_src_ex1, csr_wdata_ex1;
    logic csr_write_ex1;

    logic [31:0] branch_tgt_ex1, jalr_tgt_ex1, jal_tgt_ex1;
    logic [2:0] pc_source_branch_ex1;
    logic is_branch_ex1, is_jal_ex1, is_jalr_ex1;
    logic is_call_ex1, is_return_ex1;
    logic ex1_rd_is_link, ex1_rs1_is_link;
    logic branch_redirect_ex1;
    logic [31:0] branch_redirect_target_ex1;
    logic branch_mispredict_ex1;

    logic trap_commit_ex1, mret_commit_ex1;
    logic lsu_ordering_busy_ex1;
    logic fence_wait_ex1;
    logic fence_complete_ex1;
    logic fence_i_wait_ex1, fence_i_complete_ex1, fence_i_invalidate;
    logic atomic_wait_ex1;
    logic control_kill_ex1;
    logic branch_flush_event_ex1;
    logic mext_busy_event;

    localparam int STOREBUF_DEPTH = 4;
    localparam logic [31:0] MCAUSE_ILLEGAL_INSTR = 32'd2;
    localparam logic [31:0] MCAUSE_BREAKPOINT = 32'd3;
    localparam logic [31:0] MCAUSE_ECALL_MMODE = 32'd11;

    function automatic logic [3:0] byte_mask_for_req(
        input logic [1:0] size,
        input logic [1:0] byte_offset
    );
        begin
            unique case (size)
                2'd0: byte_mask_for_req = (4'b0001 << byte_offset);
                2'd1: byte_mask_for_req = (4'b0011 << byte_offset);
                2'd2: byte_mask_for_req = 4'b1111;
                default: byte_mask_for_req = 4'b0000;
            endcase
        end
    endfunction

    function automatic logic [31:0] format_load_word(
        input logic [31:0] raw_word,
        input logic [1:0] size,
        input logic unsigned_load,
        input logic [1:0] byte_offset
    );
        logic [7:0] loaded_byte;
        logic [15:0] loaded_half;
        begin
            loaded_byte = 8'b0;
            loaded_half = 16'b0;
            format_load_word = 32'b0;

            unique case (size)
                2'd0: begin
                    unique case (byte_offset)
                        2'd0: loaded_byte = raw_word[7:0];
                        2'd1: loaded_byte = raw_word[15:8];
                        2'd2: loaded_byte = raw_word[23:16];
                        2'd3: loaded_byte = raw_word[31:24];
                        default: loaded_byte = 8'b0;
                    endcase
                    format_load_word = unsigned_load ? {24'd0, loaded_byte} :
                                                       {{24{loaded_byte[7]}}, loaded_byte};
                end
                2'd1: begin
                    unique case (byte_offset)
                        2'd0: loaded_half = raw_word[15:0];
                        2'd1: loaded_half = raw_word[23:8];
                        2'd2: loaded_half = raw_word[31:16];
                        default: loaded_half = 16'b0;
                    endcase
                    format_load_word = unsigned_load ? {16'd0, loaded_half} :
                                                       {{16{loaded_half[15]}}, loaded_half};
                end
                2'd2: format_load_word = raw_word;
                default: format_load_word = 32'b0;
            endcase
        end
    endfunction

    function automatic logic is_control_ir(input logic [31:0] ir);
        begin
            is_control_ir = (ir[6:0] == 7'b1100011) || // branch
                            (ir[6:0] == 7'b1101111) || // jal
                            ((ir[6:0] == 7'b1100111) && (ir[14:12] == 3'b000)); // jalr
        end
    endfunction

    function automatic logic is_front_barrier_ir(input logic [31:0] ir);
        begin
            // Do not buffer younger instructions behind control/system traffic.
            is_front_barrier_ir = is_control_ir(ir) ||
                                  (ir[6:0] == 7'b1110011) ||
                                  (ir[6:0] == 7'b0001111);
        end
    endfunction

//////////////////////////////////////////////////////////////////
    // Front-end fetch packet construction

    assign pc_out_inc = pc_out + 32'd4;
    // When the PC points at the upper halfword of a 32-bit word, the current
    // instruction may straddle into the next aligned word. Build one local
    // 32-bit decode window so the decompressor can treat aligned and misaligned
    // fetch starts the same way.
    assign fetch_slot0_window = pc_out[1] ? {rd_next[15:0], rd[31:16]} : rd;
    assign fetch_slot1_window = rd_next;

    RVCExpander FETCH_SLOT0_EXPANDER(
        .raw_i(fetch_slot0_window),
        .expanded_ir_o(fetch_slot0_ir),
        .is_compressed_o(fetch_slot0_is_compressed)
    );

    RVCExpander FETCH_SLOT1_EXPANDER(
        .raw_i(fetch_slot1_window),
        .expanded_ir_o(fetch_slot1_ir),
        .is_compressed_o(fetch_slot1_is_compressed)
    );

    assign fetch_slot0_requires_next_word = pc_out[1] && ~fetch_slot0_is_compressed;
    assign fetch_slot0_ready = hit_raw && (~fetch_slot0_requires_next_word || next_valid_raw);
    // Keep same-cycle dual fetch conservative: allow the younger fetched slot
    // only when the older instruction starts on a 32-bit boundary and consumes
    // the whole first word. Compressed streams still execute correctly; they
    // just refill the queue over successive cycles.
    assign fetch_slot1_enabled = ~pc_out[1] && ~fetch_slot0_is_compressed;
    // Predictor storage and training are factored into their own module so the
    // dual-slot front end can stay focused on queueing and fetch policy.
    BranchPredictor #(
        .BHT_ENTRIES(BHT_ENTRIES),
        .BTB_ENTRIES(BTB_ENTRIES),
        .RAS_DEPTH(RAS_DEPTH),
        .BHT_RESET_VALUE(2'b10)
    ) OTTER_BRANCH_PREDICTOR (
        .clk(CLK),
        .rst(RESET),
        .fetch0_pc(pc_out),
        .fetch0_bht_taken(bht_taken_if0),
        .fetch0_btb_hit(btb_hit_if0),
        .fetch0_btb_target(btb_target_if0),
        .fetch1_pc(pc_out_inc),
        .fetch1_bht_taken(bht_taken_if1),
        .fetch1_btb_hit(btb_hit_if1),
        .fetch1_btb_target(btb_target_if1),
        .ras_valid(ras_valid),
        .ras_top(ras_top),
        .train_enable(~dc_stall),
        .branch_update_valid(is_branch_ex1),
        .branch_taken(branch_redirect_ex1),
        .branch_pc(id_ex.pc),
        .btb_update_valid((is_branch_ex1 && branch_redirect_ex1) || is_jal_ex1 || is_jalr_ex1),
        .btb_update_pc(id_ex.pc),
        .btb_update_target(branch_redirect_target_ex1),
        .ras_pop(is_return_ex1),
        .ras_push(is_call_ex1),
        .ras_push_addr(id_ex.pc_4)
    );

    FrontendPacketBuilder FETCH_SLOT0_BUILDER(
        .valid_i(hit),
        .pc_i(pc_out),
        .ir_i(fetch_slot0_ir),
        .instr_is_compressed_i(fetch_slot0_is_compressed),
        .ras_valid_i(ras_valid),
        .ras_top_i(ras_top),
        .btb_hit_i(btb_hit_if0),
        .btb_target_i(btb_target_if0),
        .bht_taken_i(bht_taken_if0),
        .packet_o(fetch_slot0)
    );

    FrontendPacketBuilder FETCH_SLOT1_BUILDER(
        .valid_i(hit && fetch_slot1_enabled && next_valid_raw),
        .pc_i(pc_out_inc),
        .ir_i(fetch_slot1_ir),
        .instr_is_compressed_i(fetch_slot1_is_compressed),
        .ras_valid_i(ras_valid),
        .ras_top_i(ras_top),
        .btb_hit_i(btb_hit_if1),
        .btb_target_i(btb_target_if1),
        .bht_taken_i(bht_taken_if1),
        .packet_o(fetch_slot1)
    );

    // Preserve the fetched prediction state when the instruction enters as
    // the younger slot so the front-end does not force a guaranteed cold
    // miss once it slides up to become the oldest queued instruction.
    assign fetch_slot0_as_slot1 = fetch_slot0;

//////////////////////////////////////////////////////////////////
    // Front-end queue control

    assign dc_stall = dc_ctrl_stall || storebuf_full_stall_event;
    assign stallEX1 = fence_wait_ex1 || fence_i_wait_ex1 || atomic_wait_ex1;
    assign stallIF = stallIF_hz || stallEX1;
    assign stallID = stallID_hz || stallEX1;
    assign stallIF2 = stallIF || stallID;
    assign flushIF2 = redirect_valid_ex1 || redirect_pending_valid;
    assign flushID = redirect_valid_ex1;
    assign flushID_pipe = redirect_valid_ex1 || redirect_pending_valid;
    assign flushEX = flushEX_hz || redirect_valid_ex1;
    assign issue_lane0 = if_id.valid && ~stallID && ~stallEX1;

    always_comb begin
        if_id_after_issue = if_id;
        if1_if2_after_issue = if1_if2;

        if (issue_lane0) begin
            if (issuePair) begin
                if_id_after_issue = '0;
                if1_if2_after_issue = '0;
            end else begin
                if_id_after_issue = if1_if2;
                if1_if2_after_issue = '0;
            end
        end
    end

    // Fetch only when issue will leave queue capacity. A control/system oldest
    // slot acts as a barrier and stops speculative younger buffering behind it.
    assign fetch_request = ~RESET &&
                           ~dc_stall &&
                           ~redirect_valid_ex1 &&
                           ~redirect_pending_valid &&
                           (~if_id_after_issue.valid ||
                            (~if1_if2_after_issue.valid &&
                             ~is_front_barrier_ir(if_id_after_issue.ir)));

    assign fetch_crossword_wait = fetch_request && fetch_slot0_requires_next_word && ~next_valid_raw;
    assign ic_stall = fetch_request && (pc_stall_cache || fetch_crossword_wait);
    assign hit = fetch_request && fetch_slot0_ready;
    assign miss = fetch_request && miss_raw;
    assign prefetch_hit_event = hit && prefetch_hit_event_raw;

    always_comb begin
        if_id_next = if_id_after_issue;
        if1_if2_next = if1_if2_after_issue;
        pc_next_fill = pc_out;
        pc_write_fill = 1'b0;

        if (~dc_stall && ~redirect_valid_ex1 && ~redirect_pending_valid && ~ic_stall) begin
            if (~if_id_after_issue.valid && fetch_slot0.valid) begin
                if_id_next = fetch_slot0;
                pc_write_fill = 1'b1;
                pc_next_fill = fetch_slot0.predicted_taken ? fetch_slot0.predicted_target : fetch_slot0.pc_4;

                if (~is_front_barrier_ir(fetch_slot0.ir) && ~if1_if2_after_issue.valid && fetch_slot1.valid) begin
                    if1_if2_next = fetch_slot1;
                    pc_next_fill = fetch_slot1.predicted_taken ? fetch_slot1.predicted_target
                                                               : fetch_slot1.pc_4;
                end
            end else if (if_id_after_issue.valid && ~if1_if2_after_issue.valid &&
                         ~is_front_barrier_ir(if_id_after_issue.ir) && fetch_slot0.valid) begin
                if1_if2_next = fetch_slot0_as_slot1;
                pc_write_fill = 1'b1;
                pc_next_fill = fetch_slot0_as_slot1.predicted_taken ? fetch_slot0_as_slot1.predicted_target
                                                                    : fetch_slot0_as_slot1.pc_4;
            end
        end
    end

    always_ff @(posedge CLK) begin
        if (RESET) begin
            pc_out <= 32'b0;
            redirect_pending_valid <= 1'b0;
            redirect_pending_target <= 32'b0;
        end else begin
            if (redirect_valid_ex1 && (dc_stall || pc_stall_cache)) begin
                redirect_pending_valid <= 1'b1;
                redirect_pending_target <= redirect_target_ex1;
            end else if (~dc_stall && ~pc_stall_cache && redirect_pending_valid) begin
                redirect_pending_valid <= 1'b0;
            end

            if (~dc_stall && ~pc_stall_cache) begin
                if (redirect_valid_ex1)
                    pc_out <= redirect_target_ex1;
                else if (redirect_pending_valid)
                    pc_out <= redirect_pending_target;
                else if (pc_write_fill)
                    pc_out <= pc_next_fill;
            end
        end
    end

    // Keep both queue slots frozen across memory stalls so the oldest/youngest
    // relationship stays aligned with the rest of the pipe.
    always_ff @(posedge CLK) begin
        if (RESET) begin
            if_id <= '0;
            if1_if2 <= '0;
        end else if (dc_stall) begin
            if_id <= if_id;
            if1_if2 <= if1_if2;
        end else if (flushID_pipe) begin
            if_id <= '0;
            if1_if2 <= '0;
        end else begin
            if_id <= if_id_next;
            if1_if2 <= if1_if2_next;
        end
    end

//////////////////////////////////////////////////////////////////
    // Instruction cache

    imem OTTER_IMEM(
        .CLK(CLK),
        .a(pc_out),
        .snoop_we(mem_we2_dc),
        .snoop_addr(mem_addr2_dc),
        .snoop_wdata(mem_din2_dc),
        .snoop_size(mem_size_dc),
        .atomic_valid(atomic_write_intent),
        .atomic_op(ex_mem.atomic_op),
        .atomic_sc_ok(atomic_sc_ok),
        .atomic_addr(ex_mem.alu_result),
        .atomic_wdata(ex_mem.rs2),
        .w0(w0),
        .w1(w1),
        .w2(w2),
        .w3(w3),
        .w4(w4),
        .w5(w5),
        .w6(w6),
        .w7(w7)
    );

    imem OTTER_IMEM_PREFETCH(
        .CLK(CLK),
        .a(pc_out + 32'd32),
        .snoop_we(mem_we2_dc),
        .snoop_addr(mem_addr2_dc),
        .snoop_wdata(mem_din2_dc),
        .snoop_size(mem_size_dc),
        .atomic_valid(atomic_write_intent),
        .atomic_op(ex_mem.atomic_op),
        .atomic_sc_ok(atomic_sc_ok),
        .atomic_addr(ex_mem.alu_result),
        .atomic_wdata(ex_mem.rs2),
        .w0(pw0),
        .w1(pw1),
        .w2(pw2),
        .w3(pw3),
        .w4(pw4),
        .w5(pw5),
        .w6(pw6),
        .w7(pw7)
    );

    Cache OTTER_CACHE(
        .PC(pc_out),
        .CLK(CLK),
        .RST(RESET),
        .update(cache_update),
        .invalidate(fence_i_invalidate),
        .w0(w0),
        .w1(w1),
        .w2(w2),
        .w3(w3),
        .w4(w4),
        .w5(w5),
        .w6(w6),
        .w7(w7),
        .pw0(pw0),
        .pw1(pw1),
        .pw2(pw2),
        .pw3(pw3),
        .pw4(pw4),
        .pw5(pw5),
        .pw6(pw6),
        .pw7(pw7),
        .rd(rd),
        .rd_next(rd_next),
        .hit(hit_raw),
        .miss(miss_raw),
        .next_valid(next_valid_raw),
        .prefetch_hit_event(prefetch_hit_event_raw),
        .prefetch_useless_event(prefetch_useless_event)
    );

    CacheFSM OTTER_CACHE_FSM(
        .hit(hit),
        .miss(miss),
        .CLK(CLK),
        .RST(RESET),
        .update(cache_update),
        .pc_stall(pc_stall_cache)
    );

//////////////////////////////////////////////////////////////////
    // Data cache / store buffer

    assign storebuf_enqueue_mask = byte_mask_for_req(mem_size, ex_mem.alu_result[1:0]);

    // The machine still has one ordered LSU. Slot 1 never allocates memory
    // traffic, so a single store buffer preserves in-order visibility.
    StoreBuffer #(
        .DEPTH(STOREBUF_DEPTH)
    ) OTTER_STORE_BUFFER(
        .clk(CLK),
        .rst(RESET),

        .enqueue_valid(ex_mem.valid && ex_mem.memWrite && ~dc_stall),
        .enqueue_addr(ex_mem.alu_result),
        .enqueue_data(ex_mem.rs2),
        .enqueue_mask(storebuf_enqueue_mask),

        .drain_accept(storebuf_drain_accept),

        .query_valid(ex_mem.valid && ex_mem.memRead && ~ex_mem.atomic_valid && dcache_cacheable),
        .query_addr(ex_mem.alu_result),
        .query_mask(mem_mask),

        .full(storebuf_full),
        .empty(storebuf_empty),
        .occupancy(storebuf_occupancy),

        .drain_valid(storebuf_drain_valid),
        .drain_addr(storebuf_drain_addr),
        .drain_data(storebuf_drain_data),
        .drain_mask(storebuf_drain_mask),

        .forward_hit(storebuf_forward_hit),
        .forward_conflict(storebuf_forward_conflict),
        .forward_data_word(storebuf_forward_word)
    );

    datacache OTTER_DCACHE(
        .clk(CLK),
        .rst(RESET),

        .loadAddr(ex_mem.alu_result),
        .loadRead(ex_mem.valid && ex_mem.memRead && ~ex_mem.atomic_valid),
        .loadSize(mem_size),
        .loadSign(mem_sign),

        .drainStoreValid(storebuf_drain_accept),
        .drainStoreAddr(storebuf_drain_addr),
        .drainStoreData(storebuf_drain_data),
        .drainStoreMask(storebuf_drain_mask),
        .atomicInvalidateValid(atomic_write_intent),
        .atomicInvalidateAddr(ex_mem.alu_result),

        .enable_write(dcache_enable_write),
        .select(dcache_fill_select),
        .word_data(dcache_fill_word),
        .last(dcache_last),

        .loadRData(rdata),
        .loadHit(dcache_hit),
        .loadMiss(dcache_miss),
        .loadCacheable(dcache_cacheable)
    );

    l2cache OTTER_L2CACHE(
        .clk(CLK),
        .rst(RESET),
        .queryAddr(ex_mem.alu_result),
        .queryValid(ex_mem.valid && ex_mem.memRead && ~ex_mem.atomic_valid &&
                    dcache_cacheable && dcache_miss &&
                    ~storebuf_forward_hit && ~storebuf_forward_conflict),
        .lineReadAddr(ex_mem.alu_result),
        .lineReadSelect(dcache_fill_select),
        .fillAddr(ex_mem.alu_result),
        .fillWrite(l2_fill_write),
        .fillSelect(l2_fill_select),
        .fillLast(l2_fill_last),
        .fillWordData(mem_dout2_mem),
        .drainStoreValid(storebuf_drain_accept),
        .drainStoreAddr(storebuf_drain_addr),
        .drainStoreData(storebuf_drain_data),
        .drainStoreMask(storebuf_drain_mask),
        .atomicInvalidateValid(atomic_write_intent),
        .atomicInvalidateAddr(ex_mem.alu_result),
        .queryHit(l2_query_hit),
        .queryMiss(l2_query_miss),
        .queryCacheable(l2_query_cacheable),
        .lineReadData(l2_line_word)
    );

    assign dcache_fill_word = l2_refill_from_l2 ? l2_line_word : mem_dout2_mem;

    datacachefsm OTTER_DCACHE_FSM(
        .clk(CLK),
        .rst(RESET),

        .exmemRead(ex_mem.valid && ex_mem.memRead && ~ex_mem.atomic_valid),
        .exmemWrite(ex_mem.valid && ex_mem.memWrite && ~ex_mem.atomic_valid),
        .exmemAddr(ex_mem.alu_result),
        .exmemSize(mem_size),
        .exmemSign(mem_sign),

        .cacheMemReady(dcache_cacheable),
        .hit(dcache_hit),
        .l2Hit(l2_query_hit),
        .loadForwardHit(storebuf_forward_hit),
        .loadForwardConflict(storebuf_forward_conflict),

        .storebufFull(storebuf_full),
        .storebufEmpty(storebuf_empty),
        .storebufDrainValid(storebuf_drain_valid),
        .storebufDrainAddr(storebuf_drain_addr),
        .storebufDrainData(storebuf_drain_data),
        .storebufDrainMask(storebuf_drain_mask),

        .stall(dc_ctrl_stall),

        .enable_write(dcache_enable_write),
        .select(dcache_fill_select),
        .last(dcache_last),
        .refill_from_l2(l2_refill_from_l2),
        .l2_fill_write(l2_fill_write),
        .l2_fill_select(l2_fill_select),
        .l2_fill_last(l2_fill_last),

        .mem_rden2(mem_rden2_dc),
        .mem_we2(mem_we2_dc),
        .mem_addr2(mem_addr2_dc),
        .mem_din2(mem_din2_dc),
        .mem_size(mem_size_dc),
        .mem_sign(mem_sign_dc),
        .storebufDrainAccept(storebuf_drain_accept),
        .miss_start(dcache_miss_start),
        .busy(dcache_busy),
        .drain_event(storebuf_drain_event)
    );

    assign storebuf_forward_data = format_load_word(storebuf_forward_word, mem_size, mem_sign, ex_mem.alu_result[1:0]);
    assign storebuf_enqueue_event = ex_mem.valid && ex_mem.memWrite && ~dc_stall;
    assign storebuf_forward_event = ex_mem.valid && ex_mem.memRead && ~ex_mem.atomic_valid &&
                                    storebuf_forward_hit && ~dc_stall;
    assign storebuf_full_stall_event = ex_mem.valid && ex_mem.memWrite && storebuf_full;
    assign storebuf_conflict_stall_event = ex_mem.valid && ex_mem.memRead && ~ex_mem.atomic_valid &&
                                           storebuf_forward_conflict;
    assign fence_wait_event = fence_wait_ex1 || fence_i_wait_ex1;

    assign mem_dout2 = (ex_mem.valid && ex_mem.atomic_valid) ?
                       ((ex_mem.atomic_op == ATOMIC_SC) ? atomic_mem_result :
                                                            atomic_forward_preview_q) :
                       (ex_mem.valid && ex_mem.memRead && storebuf_forward_hit) ? storebuf_forward_data :
                       (dcache_cacheable && ex_mem.valid && ex_mem.memRead && dcache_hit) ? rdata :
                       mem_dout2_mem;

    Memory OTTER_MEMORY(
        .MEM_RST(RESET),
        .MEM_CLK(CLK),
        .MEM_RDEN1(1'b0),
        .MEM_RDEN2(mem_rden2_dc),
        .MEM_WE2(mem_we2_dc),
        .MEM_ADDR1(14'd0),
        .MEM_ADDR2(mem_addr2_dc),
        .MEM_DIN2(mem_din2_dc),
        .MEM_SIZE(mem_size_dc),
        .MEM_SIGN(mem_sign_dc),
        .MEM_ATOMIC_VALID(ex_mem.valid && ex_mem.atomic_valid),
        .MEM_ATOMIC_OP(ex_mem.atomic_op),
        .MEM_ATOMIC_SC_OK(atomic_sc_ok),
        .MEM_ATOMIC_ADDR(ex_mem.alu_result),
        .MEM_ATOMIC_DIN(ex_mem.rs2),
        .MEM_ATOMIC_PREVIEW_ADDR(ex1_ex2.alu_result),
        .IO_IN(IOBUS_IN),
        .IO_WR(IOBUS_WR),
        .MEM_DOUT1(),
        .MEM_DOUT2(mem_dout2_mem),
        .MEM_ATOMIC_PREVIEW_WORD(atomic_preview_word_mem),
        .MEM_ATOMIC_RESULT(atomic_mem_result),
        .MEM_ATOMIC_COMMIT_VALID(atomic_commit_valid),
        .MEM_ATOMIC_COMMIT_WRITE(atomic_commit_write),
        .MEM_ATOMIC_COMMIT_OP(atomic_commit_op),
        .MEM_ATOMIC_COMMIT_SC_SUCCESS(atomic_commit_sc_success),
        .MEM_ATOMIC_COMMIT_ADDR(atomic_commit_addr),
        .MEM_ATOMIC_COMMIT_OLD_WORD(atomic_commit_old_word),
        .MEM_ATOMIC_COMMIT_NEW_WORD(atomic_commit_new_word),
        .MEM_TIMER_INTERRUPT(timer_interrupt_pending)
    );

    AtomicController ATOMIC_CTRL(
        .CLK(CLK),
        .RESET(RESET),
        .ordering_busy_i(lsu_ordering_busy_ex1),
        .dc_stall_i(dc_stall),
        .storebuf_enqueue_event_i(storebuf_enqueue_event),
        .id_ex_valid_i(id_ex.valid),
        .id_ex_atomic_valid_i(id_ex.atomic_valid),
        .ex1_ex2_valid_i(ex1_ex2.valid),
        .ex1_ex2_atomic_valid_i(ex1_ex2.atomic_valid),
        .atomic_preview_word_i(atomic_preview_word_mem),
        .ex_mem_valid_i(ex_mem.valid),
        .ex_mem_atomic_valid_i(ex_mem.atomic_valid),
        .ex_mem_atomic_op_i(ex_mem.atomic_op),
        .ex_mem_addr_i(ex_mem.alu_result),
        .atomic_commit_valid_i(atomic_commit_valid),
        .atomic_commit_op_i(atomic_commit_op),
        .atomic_commit_addr_i(atomic_commit_addr),
        .atomic_wait_ex1_o(atomic_wait_ex1),
        .atomic_sc_ok_o(atomic_sc_ok),
        .atomic_write_intent_o(atomic_write_intent),
        .atomic_forward_preview_o(atomic_forward_preview_q),
        .reservation_valid_o(reservation_valid_q),
        .reservation_set_event_o(reservation_set_event),
        .reservation_clear_event_o(reservation_clear_event)
    );

//////////////////////////////////////////////////////////////////
    // CSR file

    CSR_FILE OTTER_CSR_FILE(
        .CLK(CLK),
        .RST(RESET),
        .read_addr(if_id.ir[31:20]),
        .read_data(csr_rdata_id),
        .access_write_attempt(csr_write_attempt_id),
        .access_illegal(csr_access_illegal_id),
        .write_en(mem_wb.valid && mem_wb.csr_write && ~dc_stall),
        .write_addr(mem_wb.csr_addr),
        .write_data(mem_wb.csr_wdata),
        .trap_en(trap_commit_ex1),
        .trap_pc(id_ex.pc),
        .trap_cause(id_ex.trap_cause),
        .trap_tval(id_ex.trap_tval),
        .mret_en(mret_commit_ex1),
        .timer_interrupt_pending(timer_interrupt_pending),
        .external_interrupt_pending(INTR),
        .retire_count(retire_count_wb),
        .branch_flush_event(branch_flush_event_ex1),
        .load_use_stall_event(loadUseStall_hz),
        .icache_miss_event(cache_update),
        .dcache_miss_event(dcache_miss_start),
        .prefetch_hit_event(prefetch_hit_event),
        .prefetch_useless_event(prefetch_useless_event),
        .trap_event(trap_commit_ex1),
        .mext_busy_event(mext_busy_event),
        .mext_stall_event(1'b0),
        .storebuf_enqueue_event(storebuf_enqueue_event),
        .storebuf_full_stall_event(storebuf_full_stall_event),
        .store_to_load_forward_event(storebuf_forward_event),
        .store_conflict_stall_event(storebuf_conflict_stall_event),
        .dcache_store_drain_event(storebuf_drain_event),
        .fence_wait_event(fence_wait_event),
        .mtvec(mtvec_csr),
        .mepc(mepc_csr),
        .interrupt_pending(csr_interrupt_pending),
        .interrupt_cause(csr_interrupt_cause)
    );

//////////////////////////////////////////////////////////////////
    // Decode stage

    REG_FILE OTTER_REG_FILE(
        .CLK(CLK),
        .EN0(mem_wb.valid && mem_wb.regWrite && ~dc_stall),
        .EN1(mem_wb_pair.valid && mem_wb_pair.regWrite && ~dc_stall),
        .ADR1(if_id.ir[19:15]),
        .ADR2(if_id.ir[24:20]),
        .ADR3(if1_if2.ir[19:15]),
        .ADR4(if1_if2.ir[24:20]),
        .WA0(mem_wb.ir[11:7]),
        .WA1(mem_wb_pair.ir[11:7]),
        .WD0(wd),
        .WD1(wd_pair),
        .RS1(rs1_val),
        .RS2(rs2_val),
        .RS3(rs1_pair_val),
        .RS4(rs2_pair_val)
    );

    CU_DCDR OTTER_CU_DCDR(
        .clk(CLK),
        .IR_30(if_id.ir[30]),
        .IR_OPCODE(if_id.ir[6:0]),
        .IR_FUNCT(if_id.ir[14:12]),
        .IR_FUNCT7(if_id.ir[31:25]),
        .rst(RESET),
        .reset(RESETf),
        .ALU_SRCA(alu_src_a_base),
        .ALU_SRCB(alu_src_b_base),
        .ALU_FUN(alu_fun_base),
        .RF_WR_SEL(rf_wr_sel_base),
        .MEM_WR_EN2(mem_we2_base),
        .MEM_RD_EN2(mem_rden2_base),
        .REGWRITE(reg_wr_base),
        .CSR_EN(csr_en_de),
        .CSR_USE_IMM(csr_use_imm_de),
        .CSR_CMD(csr_cmd_de),
        .LEGAL_INSTR(legal_instr_base)
    );

    CU_DCDR OTTER_CU_DCDR_PAIR(
        .clk(CLK),
        .IR_30(if1_if2.ir[30]),
        .IR_OPCODE(if1_if2.ir[6:0]),
        .IR_FUNCT(if1_if2.ir[14:12]),
        .IR_FUNCT7(if1_if2.ir[31:25]),
        .rst(RESET),
        .reset(),
        .ALU_SRCA(alu_src_a_pair_base),
        .ALU_SRCB(alu_src_b_pair_base),
        .ALU_FUN(alu_fun_pair_base),
        .RF_WR_SEL(rf_wr_sel_pair_base),
        .MEM_WR_EN2(mem_we2_pair_base),
        .MEM_RD_EN2(mem_rden2_pair_base),
        .REGWRITE(reg_wr_pair_base),
        .CSR_EN(csr_en_pair_de),
        .CSR_USE_IMM(csr_use_imm_pair_de),
        .CSR_CMD(csr_cmd_pair_de),
        .LEGAL_INSTR(legal_instr_pair_base)
    );

    assign instr_present_id = if_id.valid;
    assign fence_id = instr_present_id &&
                      (if_id.ir[6:0] == 7'b0001111) &&
                      (if_id.ir[14:12] == 3'b000);
    assign ecall_id = instr_present_id &&
                      (if_id.ir[6:0] == 7'b1110011) &&
                      (if_id.ir[14:12] == 3'b000) &&
                      (if_id.ir[31:20] == 12'h000);
    assign ebreak_id = instr_present_id &&
                       (if_id.ir[6:0] == 7'b1110011) &&
                       (if_id.ir[14:12] == 3'b000) &&
                       (if_id.ir[31:20] == 12'h001);
    assign mret_id = instr_present_id &&
                     (if_id.ir[6:0] == 7'b1110011) &&
                     (if_id.ir[14:12] == 3'b000) &&
                     (if_id.ir[31:20] == 12'h302);
    assign fence_i_id = instr_present_id &&
                        (if_id.ir[6:0] == 7'b0001111) &&
                        (if_id.ir[14:12] == 3'b001);
    AtomicDecode ATOMIC_DECODE_SLOT0(
        .instr_valid_i(instr_present_id),
        .ir_i(if_id.ir),
        .atomic_valid_o(atomic_valid_id),
        .atomic_op_o(atomic_op_id),
        .atomic_aq_o(atomic_aq_id),
        .atomic_rl_o(atomic_rl_id),
        .atomic_legal_o(atomic_legal_id)
    );

    AtomicDecode ATOMIC_DECODE_SLOT1(
        .instr_valid_i(if1_if2.valid),
        .ir_i(if1_if2.ir),
        .atomic_valid_o(atomic_valid_pair_id),
        .atomic_op_o(atomic_op_pair_id),
        .atomic_aq_o(atomic_aq_pair_id),
        .atomic_rl_o(atomic_rl_pair_id),
        .atomic_legal_o(atomic_legal_pair_id)
    );

    // RV32A uses the normal register-forwarding/hazard machinery, but it
    // computes addresses with rs1 directly and returns the old word in the
    // memory-data writeback slot.
    assign alu_src_a_de = atomic_valid_id ? 1'b0 : alu_src_a_base;
    assign alu_src_b_de = atomic_valid_id ? 2'b00 : alu_src_b_base;
    assign alu_fun_de = atomic_valid_id ? 5'b01001 : alu_fun_base;
    assign rf_wr_sel_de = atomic_valid_id ? 2'b10 : rf_wr_sel_base;
    assign mem_we2 = atomic_valid_id ? 1'b0 : mem_we2_base;
    assign mem_rden2 = atomic_valid_id ? atomic_legal_id : mem_rden2_base;
    assign reg_wr_wb = atomic_valid_id ? atomic_legal_id : reg_wr_base;
    assign legal_instr_de = atomic_valid_id ? atomic_legal_id : legal_instr_base;

    assign alu_src_a_pair_de = atomic_valid_pair_id ? 1'b0 : alu_src_a_pair_base;
    assign alu_src_b_pair_de = atomic_valid_pair_id ? 2'b00 : alu_src_b_pair_base;
    assign alu_fun_pair_de = atomic_valid_pair_id ? 5'b01001 : alu_fun_pair_base;
    assign rf_wr_sel_pair_de = atomic_valid_pair_id ? 2'b10 : rf_wr_sel_pair_base;
    assign mem_we2_pair = atomic_valid_pair_id ? 1'b0 : mem_we2_pair_base;
    assign mem_rden2_pair = atomic_valid_pair_id ? atomic_legal_pair_id : mem_rden2_pair_base;
    assign reg_wr_pair_de = atomic_valid_pair_id ? atomic_legal_pair_id : reg_wr_pair_base;
    assign legal_instr_pair_de = atomic_valid_pair_id ? atomic_legal_pair_id : legal_instr_pair_base;

    assign csr_write_attempt_id = instr_present_id && csr_en_de &&
                                  ((csr_cmd_de == 2'b01) ||
                                   (if_id.ir[19:15] != 5'd0));

    assign illegal_instr_id = instr_present_id &&
                              (~legal_instr_de ||
                               (csr_en_de && csr_access_illegal_id) ||
                               ((if_id.ir[6:0] == 7'b1110011) &&
                                (if_id.ir[14:12] == 3'b000) &&
                                ~(ecall_id || ebreak_id || mret_id)));

    // Take asynchronous interrupts only at a clean instruction boundary so
    // the trap save path snapshots architected register state rather than a
    // partially retired call/return sequence.
        // In practice this means no older stage may still own state updates when
        // the interrupt is accepted in ID.
        assign interrupt_accept_id = instr_present_id &&
                                                                 csr_interrupt_pending &&
                                                                 ~((id_ex.valid &&
                                                                        (id_ex.regWrite || id_ex.memRead || id_ex.memWrite ||
                                                                         id_ex.csr_en || id_ex.atomic_valid ||
                                                                         id_ex.trap_taken || id_ex.mret)) ||
                                                                     (id_ex_pair.valid && id_ex_pair.regWrite) ||
                                                                     (ex1_ex2.valid &&
                                                                        (ex1_ex2.regWrite || ex1_ex2.memRead || ex1_ex2.memWrite ||
                                                                         ex1_ex2.csr_write || ex1_ex2.atomic_valid)) ||
                                                                     (ex1_ex2_pair.valid && ex1_ex2_pair.regWrite) ||
                                                                     (ex_mem.valid &&
                                                                        (ex_mem.regWrite || ex_mem.memRead || ex_mem.memWrite ||
                                                                         ex_mem.csr_write || ex_mem.atomic_valid)) ||
                                                                     (ex_mem_pair.valid && ex_mem_pair.regWrite) ||
                                                                     (mem_wb.valid && (mem_wb.regWrite || mem_wb.csr_write)) ||
                                                                     (mem_wb_pair.valid && mem_wb_pair.regWrite));

        // Once accepted, the interrupt uses the same trap path as synchronous
        // exceptions so the back end does not need special retirement logic.
    assign trap_taken_id = interrupt_accept_id ||
                           illegal_instr_id || ecall_id || ebreak_id;
    assign trap_cause_id = interrupt_accept_id ? csr_interrupt_cause :
                           illegal_instr_id ? MCAUSE_ILLEGAL_INSTR :
                           ebreak_id ? MCAUSE_BREAKPOINT :
                           MCAUSE_ECALL_MMODE;
    assign trap_tval_id = illegal_instr_id ? if_id.ir : 32'b0;

    assign csr_read_if_id = instr_present_id && csr_en_de;
    assign csr_addr_hazard_id = if_id.ir[31:20];
    assign machine_ctrl_hazard_id = trap_taken_id || mret_id;

    // Keep the pairing policy isolated from the main decode path so future
    // widening experiments only need to touch one module.
    DualIssueInOrder OTTER_DUAL_ISSUE(
        .slot0_valid_i(if_id.valid),
        .slot0_ir_i(if_id.ir),
        .slot0_trap_taken_i(trap_taken_id),
        .slot0_mret_i(mret_id),
        .slot0_fence_i(fence_id),
        .slot0_fence_i_i(fence_i_id),
        .slot0_atomic_valid_i(atomic_valid_id),
        .slot0_csr_en_i(csr_en_de),
        .slot0_mem_write_i(mem_we2),
        .slot0_mem_read_i(mem_rden2),
        .slot0_reg_write_i(reg_wr_wb),
        .slot0_legal_i(legal_instr_de),
        .slot1_valid_i(if1_if2.valid),
        .slot1_pc_i(if1_if2.pc),
        .slot1_pc_4_i(if1_if2.pc_4),
        .slot1_ir_i(if1_if2.ir),
        .slot1_rs1_i(rs1_pair_val),
        .slot1_rs2_i(rs2_pair_val),
        .slot1_legal_i(legal_instr_pair_de),
        .slot1_reg_write_i(reg_wr_pair_de),
        .slot1_mem_write_i(mem_we2_pair),
        .slot1_mem_read_i(mem_rden2_pair),
        .slot1_csr_en_i(csr_en_pair_de),
        .slot1_alu_src_a_i(alu_src_a_pair_de),
        .slot1_alu_src_b_i(alu_src_b_pair_de),
        .slot1_alu_fun_i(alu_fun_pair_de),
        .slot1_rf_wr_sel_i(rf_wr_sel_pair_de),
        .issue_lane0_i(issue_lane0),
        .issue_pair_i(issuePair),
        .blocks_pair_o(blocks_pair_id),
        .pair_candidate_o(pair_candidate_id),
        .pair_issue_valid_o(pair_issue_valid_id),
        .pair_pc_o(pair_pc_id),
        .pair_pc_4_o(pair_pc_4_id),
        .pair_ir_o(pair_ir_id),
        .pair_rs1_o(pair_rs1_id),
        .pair_rs2_o(pair_rs2_id),
        .pair_alu_src_a_o(pair_alu_src_a_id),
        .pair_alu_src_b_o(pair_alu_src_b_id),
        .pair_alu_fun_o(pair_alu_fun_id),
        .pair_rf_wr_sel_o(pair_rf_wr_sel_id),
        .pair_reg_write_o(pair_reg_write_id)
    );

//////////////////////////////////////////////////////////////////
    // Hazard / pairing rules

    Hazard OTTER_HAZARD(
        .valid_if_id(if_id.valid),
        .opcode_if_id(if_id.ir[6:0]),
        .funct3_if_id(if_id.ir[14:12]),
        .rs1_if_id(if_id.ir[19:15]),
        .rs2_if_id(if_id.ir[24:20]),
        .csrRead_if_id(csr_read_if_id),
        .csrAddr_if_id(csr_addr_hazard_id),
        .machineCtrl_if_id(machine_ctrl_hazard_id),
        .regWrite_if_id(reg_wr_wb),
        .rd_if_id(if_id.ir[11:7]),
        .blocksPair_if_id(blocks_pair_id),

        .valid_if_pair(if1_if2.valid),
        .opcode_if_pair(if1_if2.ir[6:0]),
        .funct3_if_pair(if1_if2.ir[14:12]),
        .rs1_if_pair(if1_if2.ir[19:15]),
        .rs2_if_pair(if1_if2.ir[24:20]),
        .regWrite_if_pair(reg_wr_pair_de),
        .rd_if_pair(if1_if2.ir[11:7]),
        .pairCandidate_if_pair(pair_candidate_id),

        .valid_id_ex(id_ex.valid),
        .rd_id_ex(id_ex.ir[11:7]),
        .memRead_id_ex(id_ex.memRead),
        .csrWrite_id_ex(id_ex.csr_en),
        .csrAddr_id_ex(id_ex.csr_addr),

        .valid_id_ex_pair(id_ex_pair.valid),
        .rd_id_ex_pair(id_ex_pair.ir[11:7]),
        .memRead_id_ex_pair(id_ex_pair.memRead),
        .csrWrite_id_ex_pair(id_ex_pair.csr_en),
        .csrAddr_id_ex_pair(id_ex_pair.csr_addr),

        .valid_ex1_ex2(ex1_ex2.valid),
        .csrWrite_ex1_ex2(ex1_ex2.csr_write),
        .csrAddr_ex1_ex2(ex1_ex2.csr_addr),
        .valid_ex1_ex2_pair(ex1_ex2_pair.valid),
        .csrWrite_ex1_ex2_pair(ex1_ex2_pair.csr_write),
        .csrAddr_ex1_ex2_pair(ex1_ex2_pair.csr_addr),

        .valid_ex_mem(ex_mem.valid),
        .csrWrite_ex_mem(ex_mem.csr_write),
        .csrAddr_ex_mem(ex_mem.csr_addr),
        .valid_ex_mem_pair(ex_mem_pair.valid),
        .csrWrite_ex_mem_pair(ex_mem_pair.csr_write),
        .csrAddr_ex_mem_pair(ex_mem_pair.csr_addr),

        .valid_mem_wb(mem_wb.valid),
        .csrWrite_mem_wb(mem_wb.csr_write),
        .csrAddr_mem_wb(mem_wb.csr_addr),
        .valid_mem_wb_pair(mem_wb_pair.valid),
        .csrWrite_mem_wb_pair(mem_wb_pair.csr_write),
        .csrAddr_mem_wb_pair(mem_wb_pair.csr_addr),

        .stallIF(stallIF_hz),
        .stallID(stallID_hz),
        .flushEX(flushEX_hz),
        .loadUseStall(loadUseStall_hz),
        .issuePair(issuePair)
    );

//////////////////////////////////////////////////////////////////
    // ID/EX register

    always_ff @(posedge CLK) begin
        if (RESET) begin
            id_ex <= '0;
            id_ex_pair <= '0;
        end else if (dc_stall) begin
            id_ex <= id_ex;
            id_ex_pair <= id_ex_pair;
        end else if (stallEX1) begin
            id_ex <= id_ex;
            id_ex_pair <= id_ex_pair;
        end else if (flushEX) begin
            id_ex <= '0;
            id_ex_pair <= '0;
        end else begin
            id_ex <= '0;
            id_ex_pair <= '0;

            if (issue_lane0) begin
                id_ex.valid <= 1'b1;
                id_ex.predicted_taken <= if_id.predicted_taken;
                id_ex.predicted_target <= if_id.predicted_target;
                id_ex.pc <= if_id.pc;
                id_ex.pc_4 <= if_id.pc_4;
                id_ex.ir <= if_id.ir;

                id_ex.rs1 <= rs1_val;
                id_ex.rs2 <= rs2_val;

                id_ex.alu_src_a <= alu_src_a_de;
                id_ex.alu_src_b <= alu_src_b_de;
                id_ex.alu_fun <= alu_fun_de;

                id_ex.rf_wr_sel <= rf_wr_sel_de;
                id_ex.memWrite <= mem_we2;
                id_ex.memRead <= mem_rden2;
                id_ex.regWrite <= reg_wr_wb;

                id_ex.csr_en <= csr_en_de;
                id_ex.csr_use_imm <= csr_use_imm_de;
                id_ex.csr_cmd <= csr_cmd_de;
                id_ex.csr_addr <= if_id.ir[31:20];
                id_ex.csr_rdata <= csr_rdata_id;
                id_ex.csr_write <= 1'b0;
                id_ex.csr_wdata <= 32'b0;

                id_ex.trap_taken <= trap_taken_id;
                id_ex.mret <= mret_id;
                id_ex.fence <= fence_id;
                id_ex.fence_i <= fence_i_id;
                id_ex.atomic_valid <= atomic_valid_id && atomic_legal_id;
                id_ex.atomic_op <= atomic_valid_id ? atomic_op_id : ATOMIC_NONE;
                id_ex.atomic_aq <= atomic_valid_id && atomic_aq_id;
                id_ex.atomic_rl <= atomic_valid_id && atomic_rl_id;
                id_ex.trap_cause <= trap_cause_id;
                id_ex.trap_tval <= trap_tval_id;
            end

            if (pair_issue_valid_id) begin
                // The younger lane is stripped down to pure integer execution:
                // no prediction, no LSU, no CSR writes, and no control side effects.
                id_ex_pair.valid <= 1'b1;
                id_ex_pair.predicted_taken <= 1'b0;
                id_ex_pair.predicted_target <= pair_pc_4_id;
                id_ex_pair.pc <= pair_pc_id;
                id_ex_pair.pc_4 <= pair_pc_4_id;
                id_ex_pair.ir <= pair_ir_id;

                id_ex_pair.rs1 <= pair_rs1_id;
                id_ex_pair.rs2 <= pair_rs2_id;

                id_ex_pair.alu_src_a <= pair_alu_src_a_id;
                id_ex_pair.alu_src_b <= pair_alu_src_b_id;
                id_ex_pair.alu_fun <= pair_alu_fun_id;

                id_ex_pair.rf_wr_sel <= pair_rf_wr_sel_id;
                id_ex_pair.memWrite <= 1'b0;
                id_ex_pair.memRead <= 1'b0;
                id_ex_pair.regWrite <= pair_reg_write_id;

                id_ex_pair.csr_en <= 1'b0;
                id_ex_pair.csr_use_imm <= 1'b0;
                id_ex_pair.csr_cmd <= 2'b00;
                id_ex_pair.csr_addr <= 12'b0;
                id_ex_pair.csr_rdata <= 32'b0;
                id_ex_pair.csr_write <= 1'b0;
                id_ex_pair.csr_wdata <= 32'b0;

                id_ex_pair.trap_taken <= 1'b0;
                id_ex_pair.mret <= 1'b0;
                id_ex_pair.fence <= 1'b0;
                id_ex_pair.fence_i <= 1'b0;
                id_ex_pair.atomic_valid <= 1'b0;
                id_ex_pair.atomic_op <= ATOMIC_NONE;
                id_ex_pair.atomic_aq <= 1'b0;
                id_ex_pair.atomic_rl <= 1'b0;
                id_ex_pair.trap_cause <= 32'b0;
                id_ex_pair.trap_tval <= 32'b0;
            end
        end
    end

//////////////////////////////////////////////////////////////////
    // EX1 stage

    ImmediateGenerator OTTER_IMGEN(
        .IR(id_ex.ir[31:7]),
        .U_TYPE(Utype),
        .I_TYPE(Itype),
        .S_TYPE(Stype),
        .B_TYPE(Btype),
        .J_TYPE(Jtype)
    );

    ImmediateGenerator OTTER_IMGEN_PAIR(
        .IR(id_ex_pair.ir[31:7]),
        .U_TYPE(Utype_pair),
        .I_TYPE(Itype_pair),
        .S_TYPE(Stype_pair),
        .B_TYPE(Btype_pair),
        .J_TYPE(Jtype_pair)
    );

    assign ex1_ex2_fwd_data = (ex1_ex2.rf_wr_sel == 2'b00) ? ex1_ex2.pc_4 : ex1_ex2.alu_result;
    assign ex1_ex2_pair_fwd_data = (ex1_ex2_pair.rf_wr_sel == 2'b00) ? ex1_ex2_pair.pc_4 : ex1_ex2_pair.alu_result;
    assign ex_mem_fwd_data = (ex_mem.rf_wr_sel == 2'b00) ? ex_mem.pc_4 :
                             (ex_mem.rf_wr_sel == 2'b10) ? mem_dout2 :
                             ex_mem.alu_result;
    assign ex_mem_pair_fwd_data = (ex_mem_pair.rf_wr_sel == 2'b00) ? ex_mem_pair.pc_4 :
                                  (ex_mem_pair.rf_wr_sel == 2'b10) ? ex_mem_pair.mem_data :
                                  ex_mem_pair.alu_result;

    // Search both lanes of older bundles for bypass data. Within a stage, the
    // pair pipe is checked first because it is younger than the matching slot-0
    // pipe and therefore carries the architecturally latest value.
    always_comb begin
        rs1f = id_ex.rs1;
        rs2f = id_ex.rs2;
        rs1f_pair = id_ex_pair.rs1;
        rs2f_pair = id_ex_pair.rs2;

        if (id_ex.valid && (id_ex.ir[19:15] != 5'd0)) begin
            if (ex1_ex2_pair.valid && ex1_ex2_pair.regWrite && ~ex1_ex2_pair.memRead &&
                (ex1_ex2_pair.ir[11:7] == id_ex.ir[19:15]))
                rs1f = ex1_ex2_pair_fwd_data;
            else if (ex1_ex2.valid && ex1_ex2.regWrite && ~ex1_ex2.memRead &&
                     (ex1_ex2.ir[11:7] == id_ex.ir[19:15]))
                rs1f = ex1_ex2_fwd_data;
            else if (ex_mem_pair.valid && ex_mem_pair.regWrite &&
                     (ex_mem_pair.ir[11:7] == id_ex.ir[19:15]))
                rs1f = ex_mem_pair_fwd_data;
            else if (ex_mem.valid && ex_mem.regWrite &&
                     (ex_mem.ir[11:7] == id_ex.ir[19:15]))
                rs1f = ex_mem_fwd_data;
            else if (mem_wb_pair.valid && mem_wb_pair.regWrite &&
                     (mem_wb_pair.ir[11:7] == id_ex.ir[19:15]))
                rs1f = wd_pair;
            else if (mem_wb.valid && mem_wb.regWrite &&
                     (mem_wb.ir[11:7] == id_ex.ir[19:15]))
                rs1f = wd;
        end

        if (id_ex.valid && (id_ex.ir[24:20] != 5'd0)) begin
            if (ex1_ex2_pair.valid && ex1_ex2_pair.regWrite && ~ex1_ex2_pair.memRead &&
                (ex1_ex2_pair.ir[11:7] == id_ex.ir[24:20]))
                rs2f = ex1_ex2_pair_fwd_data;
            else if (ex1_ex2.valid && ex1_ex2.regWrite && ~ex1_ex2.memRead &&
                     (ex1_ex2.ir[11:7] == id_ex.ir[24:20]))
                rs2f = ex1_ex2_fwd_data;
            else if (ex_mem_pair.valid && ex_mem_pair.regWrite &&
                     (ex_mem_pair.ir[11:7] == id_ex.ir[24:20]))
                rs2f = ex_mem_pair_fwd_data;
            else if (ex_mem.valid && ex_mem.regWrite &&
                     (ex_mem.ir[11:7] == id_ex.ir[24:20]))
                rs2f = ex_mem_fwd_data;
            else if (mem_wb_pair.valid && mem_wb_pair.regWrite &&
                     (mem_wb_pair.ir[11:7] == id_ex.ir[24:20]))
                rs2f = wd_pair;
            else if (mem_wb.valid && mem_wb.regWrite &&
                     (mem_wb.ir[11:7] == id_ex.ir[24:20]))
                rs2f = wd;
        end

        if (id_ex_pair.valid && (id_ex_pair.ir[19:15] != 5'd0)) begin
            if (ex1_ex2_pair.valid && ex1_ex2_pair.regWrite && ~ex1_ex2_pair.memRead &&
                (ex1_ex2_pair.ir[11:7] == id_ex_pair.ir[19:15]))
                rs1f_pair = ex1_ex2_pair_fwd_data;
            else if (ex1_ex2.valid && ex1_ex2.regWrite && ~ex1_ex2.memRead &&
                     (ex1_ex2.ir[11:7] == id_ex_pair.ir[19:15]))
                rs1f_pair = ex1_ex2_fwd_data;
            else if (ex_mem_pair.valid && ex_mem_pair.regWrite &&
                     (ex_mem_pair.ir[11:7] == id_ex_pair.ir[19:15]))
                rs1f_pair = ex_mem_pair_fwd_data;
            else if (ex_mem.valid && ex_mem.regWrite &&
                     (ex_mem.ir[11:7] == id_ex_pair.ir[19:15]))
                rs1f_pair = ex_mem_fwd_data;
            else if (mem_wb_pair.valid && mem_wb_pair.regWrite &&
                     (mem_wb_pair.ir[11:7] == id_ex_pair.ir[19:15]))
                rs1f_pair = wd_pair;
            else if (mem_wb.valid && mem_wb.regWrite &&
                     (mem_wb.ir[11:7] == id_ex_pair.ir[19:15]))
                rs1f_pair = wd;
        end

        if (id_ex_pair.valid && (id_ex_pair.ir[24:20] != 5'd0)) begin
            if (ex1_ex2_pair.valid && ex1_ex2_pair.regWrite && ~ex1_ex2_pair.memRead &&
                (ex1_ex2_pair.ir[11:7] == id_ex_pair.ir[24:20]))
                rs2f_pair = ex1_ex2_pair_fwd_data;
            else if (ex1_ex2.valid && ex1_ex2.regWrite && ~ex1_ex2.memRead &&
                     (ex1_ex2.ir[11:7] == id_ex_pair.ir[24:20]))
                rs2f_pair = ex1_ex2_fwd_data;
            else if (ex_mem_pair.valid && ex_mem_pair.regWrite &&
                     (ex_mem_pair.ir[11:7] == id_ex_pair.ir[24:20]))
                rs2f_pair = ex_mem_pair_fwd_data;
            else if (ex_mem.valid && ex_mem.regWrite &&
                     (ex_mem.ir[11:7] == id_ex_pair.ir[24:20]))
                rs2f_pair = ex_mem_fwd_data;
            else if (mem_wb_pair.valid && mem_wb_pair.regWrite &&
                     (mem_wb_pair.ir[11:7] == id_ex_pair.ir[24:20]))
                rs2f_pair = wd_pair;
            else if (mem_wb.valid && mem_wb.regWrite &&
                     (mem_wb.ir[11:7] == id_ex_pair.ir[24:20]))
                rs2f_pair = wd;
        end
    end

    assign aluA = id_ex.alu_src_a ? Utype : rs1f;
    assign aluB = (id_ex.alu_src_b == 2'b00) ? rs2f :
                  (id_ex.alu_src_b == 2'b01) ? Itype :
                  (id_ex.alu_src_b == 2'b10) ? Stype :
                  id_ex.pc;

    assign aluA_pair = id_ex_pair.alu_src_a ? Utype_pair : rs1f_pair;
    assign aluB_pair = (id_ex_pair.alu_src_b == 2'b00) ? rs2f_pair :
                       (id_ex_pair.alu_src_b == 2'b01) ? Itype_pair :
                       (id_ex_pair.alu_src_b == 2'b10) ? Stype_pair :
                       id_ex_pair.pc;

    ALU OTTER_ALU(
        .SRC_A(aluA),
        .SRC_B(aluB),
        .ALU_FUN(id_ex.alu_fun),
        .RESULT(alu_result_ex1)
    );

    ALU OTTER_ALU_PAIR(
        .SRC_A(aluA_pair),
        .SRC_B(aluB_pair),
        .ALU_FUN(id_ex_pair.alu_fun),
        .RESULT(alu_result_pair_ex1)
    );

    BranchGenerator OTTER_BRANCH_GEN_EX1(
        .J(Jtype),
        .B(Btype),
        .I(Itype),
        .PC(id_ex.pc),
        .rs1(rs1f),
        .rs2(rs2f),
        .IR_OPCODE(id_ex.ir[6:0]),
        .IR_FUNCT(id_ex.ir[14:12]),
        .branch(branch_tgt_ex1),
        .jalr(jalr_tgt_ex1),
        .jal(jal_tgt_ex1),
        .pcsource(pc_source_branch_ex1)
    );

    assign csr_src_ex1 = id_ex.csr_use_imm ? {27'd0, id_ex.ir[19:15]} : rs1f;
    assign csr_wdata_ex1 = (id_ex.csr_cmd == 2'b01) ? csr_src_ex1 :
                           (id_ex.csr_cmd == 2'b10) ? (id_ex.csr_rdata | csr_src_ex1) :
                           (id_ex.csr_cmd == 2'b11) ? (id_ex.csr_rdata & ~csr_src_ex1) :
                           id_ex.csr_rdata;
    assign csr_write_ex1 = id_ex.valid && id_ex.csr_en &&
                           ((id_ex.csr_cmd == 2'b01) || (csr_src_ex1 != 32'b0));
    assign exec_result_ex1 = id_ex.csr_en ? id_ex.csr_rdata : alu_result_ex1;

    assign is_branch_ex1 = id_ex.valid && (id_ex.ir[6:0] == 7'b1100011);
    assign is_jal_ex1 = id_ex.valid && (id_ex.ir[6:0] == 7'b1101111);
    assign is_jalr_ex1 = id_ex.valid &&
                         (id_ex.ir[6:0] == 7'b1100111) &&
                         (id_ex.ir[14:12] == 3'b000);
    assign ex1_rd_is_link = (id_ex.ir[11:7] == 5'd1) || (id_ex.ir[11:7] == 5'd5);
    assign ex1_rs1_is_link = (id_ex.ir[19:15] == 5'd1) || (id_ex.ir[19:15] == 5'd5);
    assign is_call_ex1 = id_ex.valid &&
                         ((is_jal_ex1 && ex1_rd_is_link) ||
                          (is_jalr_ex1 && ex1_rd_is_link));
    assign is_return_ex1 = id_ex.valid && is_jalr_ex1 &&
                           (id_ex.ir[11:7] == 5'd0) &&
                           ex1_rs1_is_link &&
                           (id_ex.ir[31:20] == 12'd0);

    assign branch_redirect_ex1 = (pc_source_branch_ex1 != 3'b000);
    assign branch_redirect_target_ex1 = (pc_source_branch_ex1 == 3'b001) ? jalr_tgt_ex1 :
                                        (pc_source_branch_ex1 == 3'b010) ? branch_tgt_ex1 :
                                        (pc_source_branch_ex1 == 3'b011) ? jal_tgt_ex1 :
                                        id_ex.pc_4;

    assign branch_mispredict_ex1 = id_ex.valid && ~dc_stall &&
                                   (is_branch_ex1 || is_jal_ex1 || is_jalr_ex1) &&
                                   ((id_ex.predicted_taken != branch_redirect_ex1) ||
                                    (branch_redirect_ex1 &&
                                     (id_ex.predicted_target != branch_redirect_target_ex1)));

    assign trap_commit_ex1 = id_ex.valid && id_ex.trap_taken && ~dc_stall;
    assign mret_commit_ex1 = id_ex.valid && id_ex.mret && ~dc_stall;

    // Fences and atomics all serialize the single LSU so the store buffer,
    // cache fill path, and reservation logic observe one ordered memory point.
    assign lsu_ordering_busy_ex1 = (ex1_ex2.valid &&
                                    (ex1_ex2.memRead || ex1_ex2.memWrite || ex1_ex2.atomic_valid)) ||
                                   (ex_mem.valid &&
                                    (ex_mem.memRead || ex_mem.memWrite || ex_mem.atomic_valid)) ||
                                   dcache_busy;
    assign fence_wait_ex1 = id_ex.valid && id_ex.fence && lsu_ordering_busy_ex1;
    assign fence_i_wait_ex1 = id_ex.valid && id_ex.fence_i && lsu_ordering_busy_ex1;
    assign fence_complete_ex1 = id_ex.valid && id_ex.fence &&
                                ~fence_wait_ex1 && ~dc_stall;
    assign fence_i_complete_ex1 = id_ex.valid && id_ex.fence_i &&
                                  ~fence_i_wait_ex1 && ~dc_stall;
    assign fence_i_invalidate = fence_i_complete_ex1;

    assign control_kill_ex1 = trap_commit_ex1 || mret_commit_ex1 || fence_i_complete_ex1;
    assign redirect_valid_ex1 = trap_commit_ex1 || mret_commit_ex1 ||
                                fence_i_complete_ex1 || branch_mispredict_ex1;
    assign redirect_target_ex1 = trap_commit_ex1 ? mtvec_csr :
                                 mret_commit_ex1 ? mepc_csr :
                                 fence_i_complete_ex1 ? id_ex.pc_4 :
                                 branch_redirect_ex1 ? branch_redirect_target_ex1 :
                                 id_ex.pc_4;

    assign pc_source_id = dc_stall ? 3'b000 :
                          trap_commit_ex1 ? 3'b100 :
                          mret_commit_ex1 ? 3'b101 :
                          fence_i_complete_ex1 ? 3'b110 :
                          pc_source_branch_ex1;

    assign branch_flush_event_ex1 = branch_mispredict_ex1 && ~dc_stall;

    assign mext_busy_event = ~dc_stall &&
                             (((id_ex.valid &&
                                (id_ex.ir[6:0] == 7'b0110011) &&
                                (id_ex.ir[31:25] == 7'b0000001))) ||
                              ((id_ex_pair.valid &&
                                (id_ex_pair.ir[6:0] == 7'b0110011) &&
                                (id_ex_pair.ir[31:25] == 7'b0000001))));

//////////////////////////////////////////////////////////////////
    // EX1/EX2 register

    always_ff @(posedge CLK) begin
        if (RESET) begin
            ex1_ex2 <= '0;
            ex1_ex2_pair <= '0;
        end else if (dc_stall) begin
            ex1_ex2 <= ex1_ex2;
            ex1_ex2_pair <= ex1_ex2_pair;
        end else begin
            ex1_ex2 <= '0;
            ex1_ex2_pair <= '0;

            if (id_ex.valid && ~stallEX1 && ~control_kill_ex1) begin
                ex1_ex2.valid <= 1'b1;
                ex1_ex2.pc <= id_ex.pc;
                ex1_ex2.pc_4 <= id_ex.pc_4;
                ex1_ex2.ir <= id_ex.ir;
                ex1_ex2.rs2 <= rs2f;
                ex1_ex2.alu_result <= exec_result_ex1;

                ex1_ex2.rf_wr_sel <= id_ex.rf_wr_sel;
                ex1_ex2.regWrite <= id_ex.regWrite;
                ex1_ex2.memRead <= id_ex.memRead;
                ex1_ex2.memWrite <= id_ex.memWrite;

                ex1_ex2.csr_en <= id_ex.csr_en;
                ex1_ex2.csr_use_imm <= id_ex.csr_use_imm;
                ex1_ex2.csr_cmd <= id_ex.csr_cmd;
                ex1_ex2.csr_addr <= id_ex.csr_addr;
                ex1_ex2.csr_rdata <= id_ex.csr_rdata;
                ex1_ex2.csr_write <= csr_write_ex1;
                ex1_ex2.csr_wdata <= csr_wdata_ex1;

                ex1_ex2.fence <= id_ex.fence;
                ex1_ex2.fence_i <= id_ex.fence_i;
                ex1_ex2.atomic_valid <= id_ex.atomic_valid;
                ex1_ex2.atomic_op <= id_ex.atomic_op;
                ex1_ex2.atomic_aq <= id_ex.atomic_aq;
                ex1_ex2.atomic_rl <= id_ex.atomic_rl;
            end

            if (id_ex_pair.valid && ~stallEX1) begin
                // Slot 1 continues as an ALU-only shadow pipe; slot 0 remains
                // the sole owner of memory, CSR, trap, and redirect behavior.
                ex1_ex2_pair.valid <= 1'b1;
                ex1_ex2_pair.pc <= id_ex_pair.pc;
                ex1_ex2_pair.pc_4 <= id_ex_pair.pc_4;
                ex1_ex2_pair.ir <= id_ex_pair.ir;
                ex1_ex2_pair.rs2 <= rs2f_pair;
                ex1_ex2_pair.alu_result <= alu_result_pair_ex1;

                ex1_ex2_pair.rf_wr_sel <= id_ex_pair.rf_wr_sel;
                ex1_ex2_pair.regWrite <= id_ex_pair.regWrite;
                ex1_ex2_pair.memRead <= 1'b0;
                ex1_ex2_pair.memWrite <= 1'b0;

                ex1_ex2_pair.csr_en <= 1'b0;
                ex1_ex2_pair.csr_use_imm <= 1'b0;
                ex1_ex2_pair.csr_cmd <= 2'b00;
                ex1_ex2_pair.csr_addr <= 12'b0;
                ex1_ex2_pair.csr_rdata <= 32'b0;
                ex1_ex2_pair.csr_write <= 1'b0;
                ex1_ex2_pair.csr_wdata <= 32'b0;

                ex1_ex2_pair.fence <= 1'b0;
                ex1_ex2_pair.fence_i <= 1'b0;
                ex1_ex2_pair.atomic_valid <= 1'b0;
                ex1_ex2_pair.atomic_op <= ATOMIC_NONE;
                ex1_ex2_pair.atomic_aq <= 1'b0;
                ex1_ex2_pair.atomic_rl <= 1'b0;
            end
        end
    end

//////////////////////////////////////////////////////////////////
    // EX2/MEM register

    always_ff @(posedge CLK) begin
        if (RESET) begin
            ex_mem <= '0;
            ex_mem_pair <= '0;
        end else if (dc_stall) begin
            ex_mem <= ex_mem;
            ex_mem_pair <= ex_mem_pair;
        end else begin
            ex_mem <= '0;
            ex_mem_pair <= '0;

            if (ex1_ex2.valid) begin
                ex_mem.valid <= 1'b1;
                ex_mem.pc <= ex1_ex2.pc;
                ex_mem.pc_4 <= ex1_ex2.pc_4;
                ex_mem.ir <= ex1_ex2.ir;
                ex_mem.rs2 <= ex1_ex2.rs2;
                ex_mem.alu_result <= ex1_ex2.alu_result;

                ex_mem.rf_wr_sel <= ex1_ex2.rf_wr_sel;
                ex_mem.regWrite <= ex1_ex2.regWrite;
                ex_mem.memRead <= ex1_ex2.memRead;
                ex_mem.memWrite <= ex1_ex2.memWrite;

                ex_mem.csr_en <= ex1_ex2.csr_en;
                ex_mem.csr_use_imm <= ex1_ex2.csr_use_imm;
                ex_mem.csr_cmd <= ex1_ex2.csr_cmd;
                ex_mem.csr_addr <= ex1_ex2.csr_addr;
                ex_mem.csr_rdata <= ex1_ex2.csr_rdata;
                ex_mem.csr_write <= ex1_ex2.csr_write;
                ex_mem.csr_wdata <= ex1_ex2.csr_wdata;

                ex_mem.fence <= ex1_ex2.fence;
                ex_mem.fence_i <= ex1_ex2.fence_i;
                ex_mem.atomic_valid <= ex1_ex2.atomic_valid;
                ex_mem.atomic_op <= ex1_ex2.atomic_op;
                ex_mem.atomic_aq <= ex1_ex2.atomic_aq;
                ex_mem.atomic_rl <= ex1_ex2.atomic_rl;
            end

            if (ex1_ex2_pair.valid) begin
                ex_mem_pair.valid <= 1'b1;
                ex_mem_pair.pc <= ex1_ex2_pair.pc;
                ex_mem_pair.pc_4 <= ex1_ex2_pair.pc_4;
                ex_mem_pair.ir <= ex1_ex2_pair.ir;
                ex_mem_pair.rs2 <= ex1_ex2_pair.rs2;
                ex_mem_pair.alu_result <= ex1_ex2_pair.alu_result;

                ex_mem_pair.rf_wr_sel <= ex1_ex2_pair.rf_wr_sel;
                ex_mem_pair.regWrite <= ex1_ex2_pair.regWrite;
                ex_mem_pair.memRead <= 1'b0;
                ex_mem_pair.memWrite <= 1'b0;

                ex_mem_pair.csr_en <= 1'b0;
                ex_mem_pair.csr_use_imm <= 1'b0;
                ex_mem_pair.csr_cmd <= 2'b00;
                ex_mem_pair.csr_addr <= 12'b0;
                ex_mem_pair.csr_rdata <= 32'b0;
                ex_mem_pair.csr_write <= 1'b0;
                ex_mem_pair.csr_wdata <= 32'b0;

                ex_mem_pair.fence <= 1'b0;
                ex_mem_pair.fence_i <= 1'b0;
                ex_mem_pair.atomic_valid <= 1'b0;
                ex_mem_pair.atomic_op <= ATOMIC_NONE;
                ex_mem_pair.atomic_aq <= 1'b0;
                ex_mem_pair.atomic_rl <= 1'b0;
            end
        end
    end

//////////////////////////////////////////////////////////////////
    // MEM stage

    assign mem_sign = ex_mem.ir[14];
    assign mem_size = ex_mem.ir[13:12];
    assign mem_mask = byte_mask_for_req(mem_size, ex_mem.alu_result[1:0]);

    assign IOBUS_OUT = mem_din2_dc;
    assign IOBUS_ADDR = mem_addr2_dc;

//////////////////////////////////////////////////////////////////
    // MEM/WB register

    always_ff @(posedge CLK) begin
        if (RESET) begin
            mem_wb <= '0;
            mem_wb_pair <= '0;
        end else if (dc_stall) begin
            mem_wb <= mem_wb;
            mem_wb_pair <= mem_wb_pair;
        end else begin
            mem_wb <= '0;
            mem_wb_pair <= '0;

            if (ex_mem.valid) begin
                mem_wb.valid <= 1'b1;
                mem_wb.pc <= ex_mem.pc;
                mem_wb.pc_4 <= ex_mem.pc_4;
                mem_wb.ir <= ex_mem.ir;
                mem_wb.alu_result <= ex_mem.alu_result;
                mem_wb.mem_data <= mem_dout2;

                mem_wb.rf_wr_sel <= ex_mem.rf_wr_sel;
                mem_wb.regWrite <= ex_mem.regWrite;

                mem_wb.csr_en <= ex_mem.csr_en;
                mem_wb.csr_use_imm <= ex_mem.csr_use_imm;
                mem_wb.csr_cmd <= ex_mem.csr_cmd;
                mem_wb.csr_addr <= ex_mem.csr_addr;
                mem_wb.csr_rdata <= ex_mem.csr_rdata;
                mem_wb.csr_write <= ex_mem.csr_write;
                mem_wb.csr_wdata <= ex_mem.csr_wdata;

                mem_wb.fence <= ex_mem.fence;
                mem_wb.fence_i <= ex_mem.fence_i;
                mem_wb.atomic_valid <= ex_mem.atomic_valid;
                mem_wb.atomic_op <= ex_mem.atomic_op;
                mem_wb.atomic_aq <= ex_mem.atomic_aq;
                mem_wb.atomic_rl <= ex_mem.atomic_rl;
            end

            if (ex_mem_pair.valid) begin
                // The younger lane bypasses MEM side effects and simply waits
                // for ordered WB/retirement beside the older lane.
                mem_wb_pair.valid <= 1'b1;
                mem_wb_pair.pc <= ex_mem_pair.pc;
                mem_wb_pair.pc_4 <= ex_mem_pair.pc_4;
                mem_wb_pair.ir <= ex_mem_pair.ir;
                mem_wb_pair.alu_result <= ex_mem_pair.alu_result;
                mem_wb_pair.mem_data <= ex_mem_pair.mem_data;

                mem_wb_pair.rf_wr_sel <= ex_mem_pair.rf_wr_sel;
                mem_wb_pair.regWrite <= ex_mem_pair.regWrite;

                mem_wb_pair.csr_en <= 1'b0;
                mem_wb_pair.csr_use_imm <= 1'b0;
                mem_wb_pair.csr_cmd <= 2'b00;
                mem_wb_pair.csr_addr <= 12'b0;
                mem_wb_pair.csr_rdata <= 32'b0;
                mem_wb_pair.csr_write <= 1'b0;
                mem_wb_pair.csr_wdata <= 32'b0;

                mem_wb_pair.fence <= 1'b0;
                mem_wb_pair.fence_i <= 1'b0;
                mem_wb_pair.atomic_valid <= 1'b0;
                mem_wb_pair.atomic_op <= ATOMIC_NONE;
                mem_wb_pair.atomic_aq <= 1'b0;
                mem_wb_pair.atomic_rl <= 1'b0;
            end
        end
    end

//////////////////////////////////////////////////////////////////
    // WB stage / ordered dual commit

    assign wd = (mem_wb.rf_wr_sel == 2'b00) ? mem_wb.pc_4 :
                (mem_wb.rf_wr_sel == 2'b10) ? mem_wb.mem_data :
                mem_wb.alu_result;

    assign wd_pair = (mem_wb_pair.rf_wr_sel == 2'b00) ? mem_wb_pair.pc_4 :
                     (mem_wb_pair.rf_wr_sel == 2'b10) ? mem_wb_pair.mem_data :
                     mem_wb_pair.alu_result;

    // Count the two WB slots exactly as they retire so CSR minstret can advance
    // by 0, 1, or 2 instructions per cycle.
    assign retire_count_wb = {1'b0, (~RESET && ~dc_stall && mem_wb.valid)} +
                             {1'b0, (~RESET && ~dc_stall && mem_wb_pair.valid)};

endmodule
// i love cpe333
