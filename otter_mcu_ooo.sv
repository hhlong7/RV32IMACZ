`timescale 1ns/1ps
/////////////////////////////////////////////////////////////////////////////
// Engineer: Long
// Module Name: OTTER_MCU
// Description: Out-of-order RV32IMAC (+ single-precision FP subset) core.
//
//   Front end   IF1 -> IF2: two-wide fetch with BHT/BTB/RAS prediction into
//               a two-entry queue (if_id = oldest, if1_if2 = next).
//   Dispatch    decode, rename through the register alias table, and
//               allocate up to two instructions per cycle into the reorder
//               buffer (ROB) and the reservation station of their unit.
//   Execute     Tomasulo-style: each unit issues its oldest ready entry.
//                 2 integer ALUs               1 cycle, sharing one station
//                 integer multiplier           3-stage pipeline
//                 integer divider              iterative, about 35 cycles
//                 branch unit                  1 cycle
//                 load/store unit              in-order memory queue
//                 FP adder / multiplier        3-stage pipelines
//                 FP divider                   iterative
//               Results return on three common data buses (CDBs); the
//               three oldest requesting units win each cycle.
//   Recovery    a branch or jump that resolves as mispredicted redirects
//               fetch at once: the rename table returns to the checkpoint
//               the branch saved at dispatch, and everything younger is
//               squashed (ROB tail, reservation stations, memory and store
//               queues, in-flight FP and load results).
//   Commit      up to two instructions per cycle from the ROB head, in
//               program order. Exceptions, interrupts, MRET and FENCE.I are
//               handled here: commit flushes everything and redirects fetch.
//
//   CSR accesses, atomics, fences, MRET and WFI serialize: they dispatch
//   only into an empty ROB, alone, and execute as they commit. FP CSR
//   accesses that cannot change frm (fflags, and frm/fcsr reads) skip that:
//   they dispatch normally, read the CSR at the ROB head, and broadcast it.
/////////////////////////////////////////////////////////////////////////////

module OTTER_MCU
    import otter_defs_pkg::*;
    import ooo_pkg::*;
(
    input logic CLK,
    input logic INTR,
    input logic RESET,
    input logic [31:0] IOBUS_IN,

    output logic IOBUS_WR,
    output logic [31:0] IOBUS_OUT,
    output logic [31:0] IOBUS_ADDR
);

    localparam int BHT_ENTRIES = 512;
    localparam int BTB_ENTRIES = 16;
    localparam int RAS_DEPTH = 4;

    // Requesters on the common data buses.
    // Units that share the free common data buses (ALU 0, ALU 1, and the
    // branch unit own CDB 0, 1, and 2 whenever they execute).
    localparam int REQ_LSU = 0, REQ_FADD = 1, REQ_FMUL = 2, REQ_FDIV = 3;
    localparam int REQ_IMUL = 4, REQ_IDIV = 5, REQ_CSR = 6;
    localparam int REQUESTERS = 7;

//////////////////////////////////////////////////////////////////
    // Signals

    // Front end
    frontend_t if_id, if1_if2;
    frontend_t fetch_slot0, fetch_slot1;
    frontend_t if_id_after_dispatch, if1_if2_after_dispatch;
    frontend_t if_id_next, if1_if2_next;
    logic [31:0] pc_out, fetch_slot1_pc, pc_next_fill;
    logic pc_write_fill, fetch_request, fetch_crossword_wait;
    logic ic_stall, pc_stall_cache;
    logic redirect_valid;
    logic [31:0] redirect_target;
    logic redirect_pending_valid;
    logic [31:0] redirect_pending_target;
    logic [31:0] ras_top;
    logic ras_valid;
    logic btb_hit_if0, btb_hit_if1, bht_taken_if0, bht_taken_if1, bht_weak_if0, bht_weak_if1;
    logic [31:0] btb_target_if0, btb_target_if1;

    // Instruction cache
    logic [31:0] w0, w1, w2, w3, w4, w5, w6, w7;
    logic [31:0] pw0, pw1, pw2, pw3, pw4, pw5, pw6, pw7;
    logic [31:0] rd, rd_next;
    logic [31:0] fetch_slot0_window, fetch_slot1_window, fetch_slot0_ir, fetch_slot1_ir;
    logic fetch_slot0_is_compressed, fetch_slot1_is_compressed;
    logic fetch_slot0_requires_next_word, fetch_slot0_ready, fetch_slot1_bytes_ready;
    logic hit, miss, hit_raw, miss_raw, next_valid_raw, cache_update;
    logic prefetch_hit_event_raw, prefetch_useless_event_raw;
    logic prefetch_hit_event, prefetch_useless_event;
    logic icache_invalidate;

    // Decode / dispatch (index 0 = if_id, 1 = if1_if2)
    logic [1:0][3:0] cls;
    logic [1:0][2:0] sys, dec_fp_rm;
    logic [1:0] exc, dec_alu_src_a, dec_mem_load, dec_mem_store, dec_mem_atomic;
    logic [1:0] dec_fp_sub, dec_fp_arith, dec_is_control, dec_csr_write_attempt, dec_csr_nonserial;
    // Slot 0 is an FP CSR access that dispatches without serializing (its
    // operand is already known); it reads its CSR at the ROB head.
    logic csr_fast0;
    logic h0_csr;                         // a CSR access is at the ROB head
    logic [1:0][31:0] exc_cause, exc_tval;
    logic [1:0][1:0] dst, src1_kind, src2_kind, dec_alu_src_b;
    logic [1:0][4:0] dec_rd, dec_alu_fun;
    logic [1:0][3:0] dec_atomic_op;
    logic dispatch0, dispatch1;
    // Reservation-station insert enables, [slot] per class.
    logic [1:0] ins_alu, ins_br, ins_mem, ins_fadd, ins_fmul, ins_fdiv, ins_imul, ins_idiv;
    logic dispatch_stall;
    logic serial_in_flight;
    logic fence_dispatch_wait;
    logic slot0_writes, slot0_wr_fp;

    // Branch recovery and rename checkpoints
    logic branch_recover;                 // mispredicted branch resolves this cycle
    tag_t recover_tag;
    logic [31:0] recover_target;
    logic [CKPTS-1:0] ckpt_used;
    tag_t [CKPTS-1:0] ckpt_owner;
    logic ckpt_avail;
    ckpt_t ckpt_free_id;
    logic ckpt_save;
    rob_entry_t rob_alloc0, rob_alloc1;
    rs_entry_t rs_new0, rs_new1;
    tag_t tag0, tag1;
    logic [3:0][31:0] int_read, fp_read;
    logic [3:0][5:0] rat_idx;
    logic [3:0] rat_busy;
    tag_t [3:0] rat_tag;
    logic [3:0] src_ready;
    tag_t [3:0] src_tag;
    logic [3:0][31:0] src_value;

    // ROB
    logic [4:0] rob_free, rob_count;
    logic [ROB_SIZE-1:0] rob_done;
    logic [ROB_SIZE-1:0][31:0] rob_value;
    tag_t rob_head;
    rob_entry_t h0, h1;
    logic [1:0] commit_count;

    // Reservation stations and units
    logic [3:0] free_alu, free_br, free_mem, free_fadd, free_fmul, free_fdiv, free_imul, free_idiv;
    logic alu_issue, alu1_issue, br_issue, fadd_issue, fmul_issue, fdiv_issue, imul_issue, idiv_issue;
    rs_entry_t alu_e, alu1_e, br_e, fadd_e, fmul_e, fdiv_e, imul_e, idiv_e;
    // Issue/execute split: the stations select (alu_sel, alu1_sel, br_sel);
    // the selected entries execute from registers (alu_e, alu1_e, br_e) in
    // the next cycle.
    rs_entry_t alu_sel, alu1_sel, br_sel;
    logic [1:0] wk_valid;                 // tag-only wake-ups from ALU selects
    tag_t [1:0] wk_tag;
    logic [2:0] bus_free;                 // CDB j not driven by its owner unit
    cdb_t arb_bus0, arb_bus1, arb_bus2;
    cdb_t cdb_alu, cdb_alu1, cdb_br, cdb_lsu, cdb_fadd, cdb_fmul, cdb_fdiv, cdb_csr, cdb_imul, cdb_idiv;
    // RV32M units: pipelined multiplier and iterative divider.
    logic imul_advance, imul_valid, idiv_busy, idiv_valid, idiv_kill, idiv_start;
    logic [31:0] imul_result, idiv_result;
    tag_t imul_tag1, imul_tag2, imul_tag3, idiv_tag;
    logic imul_live1, imul_live2, imul_live3;
    cdb_t [REQUESTERS-1:0] cdb_req;
    logic [REQUESTERS-1:0] cdb_grant;
    cdb_t cdb0, cdb1, cdb2;
    logic fadd_advance, fmul_advance;
    logic fadd_valid, fmul_valid, fdiv_busy, fdiv_valid;
    logic [31:0] fadd_result, fmul_result, fdiv_result;
    logic [4:0] fadd_flags, fmul_flags, fdiv_flags;
    tag_t fadd_tag1, fadd_tag2, fmul_tag1, fmul_tag2, fdiv_tag;
    // Live bits beside the tag shadows: cleared when a recovery squashes the
    // operation, which then drains out of the pipeline without a CDB request.
    logic fadd_live1, fadd_live2, fmul_live1, fmul_live2;
    logic fdiv_kill, fdiv_start;

    // Commit / system
    logic commit0, commit1, trap_take, interrupt_take, mret_commit, flush;
    logic fence_i_commit, fence_wait;
    logic h0_ready_store_blocked;
    logic [31:0] csr_rdata, csr_wdata;
    logic [11:0] csr_addr;
    logic csr_illegal, csr_write_attempt, csr_write_en;
    logic [31:0] mtvec_csr, mepc_csr, csr_interrupt_cause;
    logic csr_interrupt_pending;
    logic [2:0] frm_csr;
    logic [1:0] fs_csr;
    logic [31:0] commit0_value;
    logic timer_interrupt_pending;

    // Memory
    logic mem_rden2_dc, mem_we2_dc, mem_sign_dc;
    logic [31:0] mem_addr2_dc, mem_din2_dc, mem_dout2_mem;
    logic [1:0] mem_size_dc;
    logic lsu_commit_store, lsu_sb_full, lsu_drained, lsu_busy;
    logic atomic_valid, atomic_sc_ok, atomic_write_intent;
    logic [3:0] atomic_op;
    logic [31:0] atomic_addr, atomic_wdata, atomic_preview_word, atomic_sc_result;
    logic atomic_commit_valid, atomic_commit_write, atomic_commit_sc_success;
    logic [3:0] atomic_commit_op;
    logic [31:0] atomic_commit_addr, atomic_commit_old_word, atomic_commit_new_word;
    logic storebuf_enqueue_event, storebuf_forward_event, storebuf_conflict_event, storebuf_drain_event;
    logic dcache_miss_start, dcache_hit_event, l2_hit_event, load_complete_event;
    logic reservation_valid, reservation_set_event, reservation_clear_event;

//////////////////////////////////////////////////////////////////
    // Front end: fetch packets

    // A PC on the upper halfword may start a 32-bit instruction that
    // straddles into the next word: build one 32-bit decode window.
    assign fetch_slot0_window = pc_out[1] ? {rd_next[15:0], rd[31:16]} : rd;

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

    // The younger slot starts right after slot 0 (2 or 4 bytes on) and is
    // cut from the same two fetched words; it is valid when all of its bytes
    // are inside them.
    //   slot 0 at   slot 0 is   slot 1 window                 slot 1 needs
    //   word        32-bit      next word                     next word
    //   word        16-bit      {next[15:0], this[31:16]}     next word unless 16-bit
    //   halfword    16-bit      next word                     next word
    //   halfword    32-bit      next[31:16]                   next word, and 16-bit
    assign fetch_slot1_pc = pc_out + (fetch_slot0_is_compressed ? 32'd2 : 32'd4);
    always_comb begin
        unique case ({pc_out[1], fetch_slot0_is_compressed})
            2'b00: fetch_slot1_window = rd_next;
            2'b01: fetch_slot1_window = {rd_next[15:0], rd[31:16]};
            2'b11: fetch_slot1_window = rd_next;
            default: fetch_slot1_window = {16'b0, rd_next[31:16]};
        endcase
        unique case ({pc_out[1], fetch_slot0_is_compressed})
            2'b01: fetch_slot1_bytes_ready = fetch_slot1_is_compressed || next_valid_raw;
            2'b10: fetch_slot1_bytes_ready = next_valid_raw && fetch_slot1_is_compressed;
            default: fetch_slot1_bytes_ready = next_valid_raw;
        endcase
    end

    // Speculative return-address stack: calls push and returns pop as they
    // dispatch (at most one control instruction per dispatch bundle).
    logic ras_push, ras_pop;
    logic [31:0] ras_push_addr;
    always_comb begin
        frontend_t c;
        c = dispatch0 ? if_id : '0;
        if (dispatch1 && (if1_if2.is_jal || if1_if2.is_jalr))
            c = if1_if2;
        ras_push = (c.is_jal || c.is_jalr) && c.rd_is_link;
        ras_pop = c.is_return;
        ras_push_addr = c.pc_next;
    end

    // Branch history and target buffers train at commit, in program order.
    logic train_branch, train_btb;
    logic [GHR_BITS-1:0] bp_ghr, ghr_recover_value;
    logic ghr_shift, ghr_shift_taken;

    // A mispredicted conditional branch restarts the history from the copy it
    // carried plus its real outcome; a mispredicted jump never shifted it.
    assign ghr_recover_value = (br_e.ir[6:0] == OPC_BRANCH) ? {br_e.ghr[GHR_BITS-2:0], cdb_br.taken} : br_e.ghr;
    assign train_branch = commit0 && h0.is_control && (h0.ir[6:0] == OPC_BRANCH);
    // Only indirect jumps need the BTB: branch and jal targets are computed
    // from the instruction at fetch.
    assign train_btb = commit0 && h0.is_control && h0.taken && (h0.ir[6:0] == OPC_JALR);

    BranchPredictor #(
        .BHT_ENTRIES(BHT_ENTRIES),
        .BTB_ENTRIES(BTB_ENTRIES),
        .RAS_DEPTH(RAS_DEPTH),
        .GHR_BITS(GHR_BITS),
        .BHT_RESET_VALUE(2'b01)
    ) OTTER_BRANCH_PREDICTOR (
        .clk(CLK),
        .rst(RESET),
        .fetch0_pc(pc_out),
        .fetch0_bht_taken(bht_taken_if0),
        .fetch0_bht_weak(bht_weak_if0),
        .fetch0_btb_hit(btb_hit_if0),
        .fetch0_btb_target(btb_target_if0),
        .fetch1_pc(fetch_slot1_pc),
        .fetch1_bht_taken(bht_taken_if1),
        .fetch1_bht_weak(bht_weak_if1),
        .fetch1_btb_hit(btb_hit_if1),
        .fetch1_btb_target(btb_target_if1),
        .ras_valid(ras_valid),
        .ras_top(ras_top),
        .ghr(bp_ghr),
        .ghr_shift(ghr_shift),
        .ghr_shift_taken(ghr_shift_taken),
        .ghr_recover(branch_recover),
        .ghr_recover_value(ghr_recover_value),
        .ghr_restore_retired(flush),
        .train_enable(1'b1),
        .branch_update_valid(train_branch),
        .branch_taken(h0.taken),
        .branch_pc(h0.pc),
        .branch_ghr(h0.ghr),
        .btb_update_valid(train_btb),
        .btb_update_pc(h0.pc),
        .btb_update_target(h0.next_pc),
        .ras_pop(ras_pop),
        .ras_push(ras_push),
        .ras_push_addr(ras_push_addr)
    );

    FrontendPacketBuilder FETCH_SLOT0_BUILDER(
        .valid_i(hit),
        .pc_i(pc_out),
        .ir_i(fetch_slot0_ir),
        .instr_is_compressed_i(fetch_slot0_is_compressed),
        .raw_i(fetch_slot0_window),
        .ras_valid_i(ras_valid),
        .ras_top_i(ras_top),
        .btb_hit_i(btb_hit_if0),
        .btb_target_i(btb_target_if0),
        .bht_taken_i(bht_taken_if0),
        .bht_weak_i(bht_weak_if0),
        .ghr_i(bp_ghr),
        .packet_o(fetch_slot0)
    );

    FrontendPacketBuilder FETCH_SLOT1_BUILDER(
        .valid_i(hit && fetch_slot1_bytes_ready),
        .pc_i(fetch_slot1_pc),
        .ir_i(fetch_slot1_ir),
        .instr_is_compressed_i(fetch_slot1_is_compressed),
        .raw_i(fetch_slot1_window),
        .ras_valid_i(ras_valid),
        .ras_top_i(ras_top),
        .btb_hit_i(btb_hit_if1),
        .btb_target_i(btb_target_if1),
        .bht_taken_i(bht_taken_if1),
        .bht_weak_i(bht_weak_if1),
        .ghr_i(bp_ghr),
        .packet_o(fetch_slot1)
    );

//////////////////////////////////////////////////////////////////
    // Front end: fetch queue

    always_comb begin
        if_id_after_dispatch = if_id;
        if1_if2_after_dispatch = if1_if2;
        if (dispatch0) begin
            if_id_after_dispatch = dispatch1 ? '0 : if1_if2;
            if1_if2_after_dispatch = '0;
        end
    end

    // Bundle rule: a control or system instruction ends the bundle, except a
    // conditional branch predicted not-taken, which may be followed by one
    // instruction that is not itself control/system. So each bundle still
    // holds at most one branch (one rename checkpoint, one history shift).
    // Separate blocks: queued_lets_follow gates the fetch request, and the
    // others read the fetched packets, which depend on that request. always @*
    // (not always_comb): Icarus 12 makes always_comb blocks that share a
    // function (is_front_barrier_ir) re-trigger each other forever.
    logic queued_lets_follow, slot0_takes_slot1, queued_takes_slot0, queued_nt_branch;
    always @* begin
        queued_nt_branch = if_id_after_dispatch.is_branch && !if_id_after_dispatch.predicted_taken;
        queued_lets_follow = !is_front_barrier_ir(if_id_after_dispatch.ir) || queued_nt_branch;
    end
    always @* begin
        queued_takes_slot0 = !is_front_barrier_ir(if_id_after_dispatch.ir) ||
                             (queued_nt_branch && !is_front_barrier_ir(fetch_slot0.ir));
        slot0_takes_slot1 = !is_front_barrier_ir(fetch_slot0.ir) ||
                            (fetch_slot0.is_branch && !fetch_slot0.predicted_taken &&
                             !is_front_barrier_ir(fetch_slot1.ir));
    end

    // Fetch only into free queue space.
    assign fetch_request = ~RESET && ~redirect_valid && ~redirect_pending_valid &&
                           (~if_id_after_dispatch.valid ||
                            (~if1_if2_after_dispatch.valid && queued_lets_follow));

    assign fetch_crossword_wait = fetch_request && fetch_slot0_requires_next_word && ~next_valid_raw;
    assign ic_stall = fetch_request && (pc_stall_cache || fetch_crossword_wait);
    assign hit = fetch_request && fetch_slot0_ready;
    assign miss = fetch_request && miss_raw;

    // The I-cache updates at the clock edge, so its prefetch events are
    // stable for the whole cycle and feed the HPM counters directly.
    assign prefetch_hit_event = hit && prefetch_hit_event_raw;
    assign prefetch_useless_event = prefetch_useless_event_raw;

    always_comb begin
        if_id_next = if_id_after_dispatch;
        if1_if2_next = if1_if2_after_dispatch;
        pc_next_fill = pc_out;
        pc_write_fill = 1'b0;
        ghr_shift = 1'b0;
        ghr_shift_taken = 1'b0;

        if (~redirect_valid && ~redirect_pending_valid && ~ic_stall) begin
            if (~if_id_after_dispatch.valid && fetch_slot0.valid) begin
                if_id_next = fetch_slot0;
                pc_write_fill = 1'b1;
                pc_next_fill = fetch_slot0.predicted_taken ? fetch_slot0.predicted_target : fetch_slot0.pc_next;
                ghr_shift = fetch_slot0.is_branch;
                ghr_shift_taken = fetch_slot0.predicted_taken;
                if (slot0_takes_slot1 && fetch_slot1.valid) begin
                    if1_if2_next = fetch_slot1;
                    pc_next_fill = fetch_slot1.predicted_taken ? fetch_slot1.predicted_target : fetch_slot1.pc_next;
                    // At most one of the two is a branch.
                    if (fetch_slot1.is_branch) begin
                        ghr_shift = 1'b1;
                        ghr_shift_taken = fetch_slot1.predicted_taken;
                    end
                end
            end else if (if_id_after_dispatch.valid && ~if1_if2_after_dispatch.valid &&
                         queued_takes_slot0 && fetch_slot0.valid) begin
                if1_if2_next = fetch_slot0;
                pc_write_fill = 1'b1;
                pc_next_fill = fetch_slot0.predicted_taken ? fetch_slot0.predicted_target : fetch_slot0.pc_next;
                ghr_shift = fetch_slot0.is_branch;
                ghr_shift_taken = fetch_slot0.predicted_taken;
            end
        end
    end

    always_ff @(posedge CLK) begin
        if (RESET) begin
            pc_out <= 32'b0;
            redirect_pending_valid <= 1'b0;
            redirect_pending_target <= 32'b0;
        end else begin
            // A redirect during an I-cache fill waits for the fill to finish.
            if (redirect_valid && pc_stall_cache) begin
                redirect_pending_valid <= 1'b1;
                redirect_pending_target <= redirect_target;
            end else if (~pc_stall_cache && redirect_pending_valid) begin
                redirect_pending_valid <= 1'b0;
            end

            if (~pc_stall_cache) begin
                if (redirect_valid)
                    pc_out <= redirect_target;
                else if (redirect_pending_valid)
                    pc_out <= redirect_pending_target;
                else if (pc_write_fill)
                    pc_out <= pc_next_fill;
            end
        end
    end

    always_ff @(posedge CLK) begin
        if (RESET || redirect_valid || redirect_pending_valid) begin
            if_id <= '0;
            if1_if2 <= '0;
        end else begin
            if_id <= if_id_next;
            if1_if2 <= if1_if2_next;
        end
    end

//////////////////////////////////////////////////////////////////
    // Instruction memory and cache

    imem OTTER_IMEM(
        .CLK(CLK),
        .a(pc_out),
        .snoop_we(mem_we2_dc),
        .snoop_addr(mem_addr2_dc),
        .snoop_wdata(mem_din2_dc),
        .snoop_size(mem_size_dc),
        .atomic_valid(atomic_write_intent),
        .atomic_op(atomic_op),
        .atomic_sc_ok(atomic_sc_ok),
        .atomic_addr(atomic_addr),
        .atomic_wdata(atomic_wdata),
        .w0(w0), .w1(w1), .w2(w2), .w3(w3), .w4(w4), .w5(w5), .w6(w6), .w7(w7)
    );

    imem OTTER_IMEM_PREFETCH(
        .CLK(CLK),
        .a(pc_out + 32'd32),
        .snoop_we(mem_we2_dc),
        .snoop_addr(mem_addr2_dc),
        .snoop_wdata(mem_din2_dc),
        .snoop_size(mem_size_dc),
        .atomic_valid(atomic_write_intent),
        .atomic_op(atomic_op),
        .atomic_sc_ok(atomic_sc_ok),
        .atomic_addr(atomic_addr),
        .atomic_wdata(atomic_wdata),
        .w0(pw0), .w1(pw1), .w2(pw2), .w3(pw3), .w4(pw4), .w5(pw5), .w6(pw6), .w7(pw7)
    );

    Cache OTTER_CACHE(
        .PC(pc_out),
        .CLK(CLK),
        .RST(RESET),
        .update(cache_update),
        .invalidate(icache_invalidate),
        .w0(w0), .w1(w1), .w2(w2), .w3(w3), .w4(w4), .w5(w5), .w6(w6), .w7(w7),
        .pw0(pw0), .pw1(pw1), .pw2(pw2), .pw3(pw3), .pw4(pw4), .pw5(pw5), .pw6(pw6), .pw7(pw7),
        .rd(rd),
        .rd_next(rd_next),
        .hit(hit_raw),
        .miss(miss_raw),
        .next_valid(next_valid_raw),
        .prefetch_hit_event(prefetch_hit_event_raw),
        .prefetch_useless_event(prefetch_useless_event_raw)
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
    // Decode

    // Only slot 0 can dispatch a CSR access (they serialize), so slot 1
    // reports any CSR as illegal and simply waits to become slot 0.
    DispatchDecode DECODE0 (
        .ir(if_id.ir),
        .raw_ir(if_id.raw_ir),
        .pc(if_id.pc),
        .frm(frm_csr),
        .fs(fs_csr),
        // Only slot 0 can dispatch a CSR access (they serialize).
        .csr_illegal(csr_illegal),
        .cls(cls[0]),
        .sys(sys[0]),
        .exception(exc[0]),
        .cause(exc_cause[0]),
        .tval(exc_tval[0]),
        .dst(dst[0]),
        .rd(dec_rd[0]),
        .src1_kind(src1_kind[0]),
        .src2_kind(src2_kind[0]),
        .alu_src_a(dec_alu_src_a[0]),
        .alu_src_b(dec_alu_src_b[0]),
        .alu_fun(dec_alu_fun[0]),
        .mem_load(dec_mem_load[0]),
        .mem_store(dec_mem_store[0]),
        .mem_atomic(dec_mem_atomic[0]),
        .atomic_op(dec_atomic_op[0]),
        .fp_sub(dec_fp_sub[0]),
        .fp_arith(dec_fp_arith[0]),
        .fp_rm(dec_fp_rm[0]),
        .is_control(dec_is_control[0]),
        .csr_write_attempt(dec_csr_write_attempt[0]),
        .csr_nonserial(dec_csr_nonserial[0])
    );

    DispatchDecode DECODE1 (
        .ir(if1_if2.ir),
        .raw_ir(if1_if2.raw_ir),
        .pc(if1_if2.pc),
        .frm(frm_csr),
        .fs(fs_csr),
        // Only slot 0 can dispatch a CSR access (they serialize).
        .csr_illegal(1'b1),
        .cls(cls[1]),
        .sys(sys[1]),
        .exception(exc[1]),
        .cause(exc_cause[1]),
        .tval(exc_tval[1]),
        .dst(dst[1]),
        .rd(dec_rd[1]),
        .src1_kind(src1_kind[1]),
        .src2_kind(src2_kind[1]),
        .alu_src_a(dec_alu_src_a[1]),
        .alu_src_b(dec_alu_src_b[1]),
        .alu_fun(dec_alu_fun[1]),
        .mem_load(dec_mem_load[1]),
        .mem_store(dec_mem_store[1]),
        .mem_atomic(dec_mem_atomic[1]),
        .atomic_op(dec_atomic_op[1]),
        .fp_sub(dec_fp_sub[1]),
        .fp_arith(dec_fp_arith[1]),
        .fp_rm(dec_fp_rm[1]),
        .is_control(dec_is_control[1]),
        .csr_write_attempt(dec_csr_write_attempt[1]),
        .csr_nonserial(dec_csr_nonserial[1])
    );

//////////////////////////////////////////////////////////////////
    // Rename: operand lookup

    REG_FILE OTTER_REG_FILE(
        .CLK(CLK),
        .EN0(commit0 && h0.wr_int),
        .EN1(commit1 && h1.wr_int),
        .ADR1(if_id.ir[19:15]),
        .ADR2(if_id.ir[24:20]),
        .ADR3(if1_if2.ir[19:15]),
        .ADR4(if1_if2.ir[24:20]),
        .WA0(h0.rd),
        .WA1(h1.rd),
        .WD0(commit0_value),
        .WD1(h1.value),
        .RS1(int_read[0]),
        .RS2(int_read[1]),
        .RS3(int_read[2]),
        .RS4(int_read[3])
    );

    FP_REG_FILE OTTER_FP_REG_FILE(
        .CLK(CLK),
        .WE0(commit0 && h0.wr_fp),
        .WA0(h0.rd),
        .WD0(h0.value),
        .WE1(commit1 && h1.wr_fp),
        .WA1(h1.rd),
        .WD1(h1.value),
        .RA({if1_if2.ir[24:20], if1_if2.ir[19:15], if_id.ir[24:20], if_id.ir[19:15]}),
        .RD(fp_read)
    );

    // Source p: 0 = slot0 rs1, 1 = slot0 rs2, 2 = slot1 rs1, 3 = slot1 rs2.
    always_comb begin
        rat_idx[0] = {src1_kind[0] == DST_FP, if_id.ir[19:15]};
        rat_idx[1] = {src2_kind[0] == DST_FP, if_id.ir[24:20]};
        rat_idx[2] = {src1_kind[1] == DST_FP, if1_if2.ir[19:15]};
        rat_idx[3] = {src2_kind[1] == DST_FP, if1_if2.ir[24:20]};
    end

    RenameTable OTTER_RAT(
        .clk(CLK),
        .rst(RESET),
        .flush(flush),
        .lookup_idx(rat_idx),
        .lookup_busy(rat_busy),
        .lookup_tag(rat_tag),
        .set0_en(dispatch0 && (rob_alloc0.wr_int || rob_alloc0.wr_fp)),
        .set0_idx({rob_alloc0.wr_fp, rob_alloc0.rd}),
        .set0_tag(tag0),
        .set1_en(dispatch1 && (rob_alloc1.wr_int || rob_alloc1.wr_fp)),
        .set1_idx({rob_alloc1.wr_fp, rob_alloc1.rd}),
        .set1_tag(tag1),
        .clear0_en(commit0 && (h0.wr_int || h0.wr_fp)),
        .clear0_idx({h0.wr_fp, h0.rd}),
        .clear0_tag(rob_head),
        .clear1_en(commit1 && (h1.wr_int || h1.wr_fp)),
        .clear1_idx({h1.wr_fp, h1.rd}),
        .clear1_tag(tag_t'(rob_head + 1'b1)),
        .save_en(ckpt_save),
        .save_id(ckpt_free_id),
        .save_after_slot0(ins_br[0]),
        .restore_en(branch_recover),
        .restore_id(br_e.ckpt)
    );

    // Slot 0's destination, decoded separately from rob_alloc0 (which depends
    // on src_value through csr_src) so slot 1's operand check is loop-free.
    always_comb begin
        slot0_wr_fp = (dst[0] == DST_FP);
        slot0_writes = (dst[0] == DST_INT) || slot0_wr_fp;
    end

    // Resolve each source: no source, x0, the slot-0 result (for slot 1),
    // a finished ROB value, a pending tag, or the committed register value.
    always_comb begin
        for (int p = 0; p < 4; p++) begin
            logic [1:0] kind;
            logic [5:0] idx;
            tag_t t;
            kind = (p == 0) ? src1_kind[0] : (p == 1) ? src2_kind[0] :
                   (p == 2) ? src1_kind[1] : src2_kind[1];
            t = rat_tag[p];
            idx = rat_idx[p];
            src_ready[p] = 1'b1;
            src_tag[p] = '0;
            src_value[p] = (kind == DST_FP) ? fp_read[p] : int_read[p];

            if (kind == DST_NONE || (kind == DST_INT && idx[4:0] == 5'd0)) begin
                src_value[p] = 32'b0;
            end else if (p >= 2 && slot0_writes && idx == {slot0_wr_fp, dec_rd[0]}) begin
                src_ready[p] = 1'b0;            // produced by the older slot
                src_tag[p] = tag0;
            end else if (rat_busy[p]) begin
                src_tag[p] = t;
                // A value broadcast this very cycle is not forwarded here (a
                // long path); the reservation station captures it on insertion.
                if (rob_done[t]) begin
                    src_value[p] = rob_value[t];
                end else begin
                    src_ready[p] = 1'b0;
                end
            end
        end
    end

//////////////////////////////////////////////////////////////////
    // Dispatch

    function automatic rob_entry_t make_rob_entry(input frontend_t f, input int s,
                                                  input logic [3:0] c, input logic [2:0] sy,
                                                  input logic e, input logic [31:0] ca, input logic [31:0] tv,
                                                  input logic [1:0] d, input logic [4:0] r,
                                                  input logic is_store, input logic is_ctl, input logic fpa,
                                                  input logic [31:0] csr_src, input logic fast_csr);
        make_rob_entry = '0;
        make_rob_entry.valid = 1'b1;
        // Serializing instructions other than atomics, and exceptions, are
        // finished as soon as they dispatch: they act at commit. A fast CSR
        // access finishes when it reads its CSR at the ROB head (on a CDB).
        make_rob_entry.done = (c == CLS_NONE) && !fast_csr;
        make_rob_entry.pc = f.pc;
        make_rob_entry.pc_next = f.pc_next;
        make_rob_entry.ir = f.ir;
        make_rob_entry.raw_ir = f.raw_ir;
        make_rob_entry.wr_int = (d == DST_INT);
        make_rob_entry.wr_fp = (d == DST_FP);
        make_rob_entry.rd = r;
        make_rob_entry.exception = e;
        make_rob_entry.cause = ca;
        make_rob_entry.tval = tv;
        make_rob_entry.is_store = is_store;
        make_rob_entry.is_control = is_ctl;
        make_rob_entry.fp_arith = fpa;
        make_rob_entry.serial = (sy != SYS_NONE);
        make_rob_entry.sys_csr = (sy == SYS_CSR);
        make_rob_entry.sys_mret = (sy == SYS_MRET);
        make_rob_entry.sys_fence = (sy == SYS_FENCE);
        make_rob_entry.sys_fence_i = (sy == SYS_FENCE_I);
        make_rob_entry.csr_src = csr_src;
        make_rob_entry.ghr = f.ghr;
    endfunction

    always_comb begin
        rob_alloc0 = make_rob_entry(if_id, 0, cls[0], sys[0], exc[0], exc_cause[0], exc_tval[0],
                                    dst[0], dec_rd[0], dec_mem_store[0], dec_is_control[0], dec_fp_arith[0],
                                    if_id.ir[14] ? {27'b0, if_id.ir[19:15]} : src_value[0], csr_fast0);
        rob_alloc1 = make_rob_entry(if1_if2, 1, cls[1], sys[1], exc[1], exc_cause[1], exc_tval[1],
                                    dst[1], dec_rd[1], dec_mem_store[1], dec_is_control[1], dec_fp_arith[1],
                                    32'b0, 1'b0);
    end

    // A faulting access (e.g. FP CSR with FS off) traps at commit as usual.
    assign csr_fast0 = dec_csr_nonserial[0] && !exc[0] && (if_id.ir[14] || src_ready[0]);

    function automatic rs_entry_t make_rs_entry(input frontend_t f, input tag_t t, input int s,
                                                input logic sa, input logic [1:0] sb, input logic [4:0] fun,
                                                input logic ld, input logic st, input logic amo,
                                                input logic [3:0] aop, input logic fsub, input logic [2:0] rm,
                                                input logic [1:0] d,
                                                input logic r1, input tag_t t1, input logic [31:0] v1,
                                                input logic r2, input tag_t t2, input logic [31:0] v2);
        make_rs_entry = '0;
        make_rs_entry.valid = 1'b1;
        make_rs_entry.tag = t;
        make_rs_entry.pc = f.pc;
        make_rs_entry.pc_next = f.pc_next;
        make_rs_entry.ghr = f.ghr;
        make_rs_entry.ir = f.ir;
        make_rs_entry.predicted_taken = f.predicted_taken;
        make_rs_entry.predicted_target = f.predicted_target;
        make_rs_entry.alu_src_a = sa;
        make_rs_entry.alu_src_b = sb;
        make_rs_entry.alu_fun = fun;
        make_rs_entry.writes_rd = (d != DST_NONE);
        make_rs_entry.mem_load = ld;
        make_rs_entry.mem_store = st;
        make_rs_entry.mem_atomic = amo;
        make_rs_entry.atomic_op = aop;
        make_rs_entry.fp_sub = fsub;
        make_rs_entry.fp_rm = rm;
        make_rs_entry.src1_ready = r1;
        make_rs_entry.src1_tag = t1;
        make_rs_entry.src1 = v1;
        make_rs_entry.src2_ready = r2;
        make_rs_entry.src2_tag = t2;
        make_rs_entry.src2 = v2;
    endfunction

    always_comb begin
        rs_new0 = make_rs_entry(if_id, tag0, 0, dec_alu_src_a[0], dec_alu_src_b[0], dec_alu_fun[0],
                                dec_mem_load[0], dec_mem_store[0], dec_mem_atomic[0], dec_atomic_op[0],
                                dec_fp_sub[0], dec_fp_rm[0], dst[0],
                                src_ready[0], src_tag[0], src_value[0], src_ready[1], src_tag[1], src_value[1]);
        rs_new1 = make_rs_entry(if1_if2, tag1, 1, dec_alu_src_a[1], dec_alu_src_b[1], dec_alu_fun[1],
                                dec_mem_load[1], dec_mem_store[1], dec_mem_atomic[1], dec_atomic_op[1],
                                dec_fp_sub[1], dec_fp_rm[1], dst[1],
                                src_ready[2], src_tag[2], src_value[2], src_ready[3], src_tag[3], src_value[3]);
        rs_new0.ckpt = ckpt_free_id;
        rs_new1.ckpt = ckpt_free_id;
    end

    // Rename checkpoints: a dispatching branch takes a free one (at most one
    // control instruction dispatches per cycle: they are fetch barriers). It
    // is released when the branch resolves; a recovery also releases those
    // of the younger branches it squashes.
    always_comb begin
        ckpt_avail = 1'b0;
        ckpt_free_id = '0;
        for (int k = CKPTS - 1; k >= 0; k--) begin
            if (!ckpt_used[k]) begin
                ckpt_avail = 1'b1;
                ckpt_free_id = ckpt_t'(k);
            end
        end
        ckpt_save = ins_br[0] || ins_br[1];
    end

    always_ff @(posedge CLK) begin
        if (RESET || flush) begin
            ckpt_used <= '0;
        end else begin
            for (int k = 0; k < CKPTS; k++) begin
                if (br_e.valid && br_e.ckpt == ckpt_t'(k))
                    ckpt_used[k] <= 1'b0;
                else if (branch_recover && ckpt_used[k] && tag_younger(ckpt_owner[k], recover_tag, rob_head))
                    ckpt_used[k] <= 1'b0;
            end
            if (ckpt_save) begin
                ckpt_used[ckpt_free_id] <= 1'b1;
                ckpt_owner[ckpt_free_id] <= ins_br[1] ? tag1 : tag0;
            end
        end
    end

    function automatic logic [3:0] class_free(input logic [3:0] c,
                                              input logic [3:0] fa, input logic [3:0] fb, input logic [3:0] fm,
                                              input logic [3:0] fx, input logic [3:0] fy, input logic [3:0] fz,
                                              input logic [3:0] fi, input logic [3:0] fd);
        unique case (c)
            CLS_ALU:    class_free = fa;
            CLS_BRANCH: class_free = fb;
            CLS_MEM:    class_free = fm;
            CLS_FPADD:  class_free = fx;
            CLS_FPMUL:  class_free = fy;
            CLS_FPDIV:  class_free = fz;
            CLS_IMUL:   class_free = fi;
            CLS_IDIV:   class_free = fd;
            default:    class_free = 4'd15;
        endcase
    endfunction

    // A serializing instruction in the ROB blocks all younger dispatch until
    // it commits; an interrupt waits for the ROB to drain.
    always_ff @(posedge CLK) begin
        if (RESET || flush)
            serial_in_flight <= 1'b0;
        else if (dispatch0 && sys[0] != SYS_NONE && !csr_fast0)
            serial_in_flight <= 1'b1;
        else if (commit0 && h0.serial)
            serial_in_flight <= 1'b0;
    end

    always_comb begin
        logic [3:0] need0_free, need1_free;
        logic same_class;

        need0_free = class_free(cls[0], free_alu, free_br, free_mem, free_fadd, free_fmul, free_fdiv, free_imul, free_idiv);
        need1_free = class_free(cls[1], free_alu, free_br, free_mem, free_fadd, free_fmul, free_fdiv, free_imul, free_idiv);
        same_class = (cls[0] == cls[1]) && (cls[0] != CLS_NONE);

        dispatch0 = if_id.valid && !flush && !branch_recover && !serial_in_flight && !csr_interrupt_pending &&
                    (rob_free >= 5'd1) && (need0_free >= 4'd1) &&
                    ((cls[0] != CLS_BRANCH) || ckpt_avail) &&
                    ((sys[0] == SYS_NONE) || (rob_count == 5'd0) ||
                     (csr_fast0 && !h0_csr));      // one CSR on the read port at a time

        dispatch1 = dispatch0 && if1_if2.valid &&
                    ((cls[1] != CLS_BRANCH) || ckpt_avail) &&
                    (sys[0] == SYS_NONE) && !exc[0] &&
                    (sys[1] == SYS_NONE) && !exc[1] &&
                    (rob_free >= 5'd2) &&
                    (need1_free >= (same_class ? 4'd2 : 4'd1));

        dispatch_stall = if_id.valid && !dispatch0;
        // A fence waits twice: here for older instructions to retire, then at
        // commit for the store buffer to drain. Both count as fence wait.
        fence_dispatch_wait = dispatch_stall && !flush &&
                              ((sys[0] == SYS_FENCE) || (sys[0] == SYS_FENCE_I));
    end

    // Which reservation station each dispatching slot enters. Decoded in an
    // always_comb block: Icarus 13 can mis-evaluate compares against package
    // constants inside port expressions.
    always_comb begin
        logic [1:0] go;
        go = {dispatch1, dispatch0};
        for (int k = 0; k < 2; k++) begin
            ins_alu[k] = 1'b0;
            ins_br[k] = 1'b0;
            ins_mem[k] = 1'b0;
            ins_fadd[k] = 1'b0;
            ins_fmul[k] = 1'b0;
            ins_fdiv[k] = 1'b0;
            ins_imul[k] = 1'b0;
            ins_idiv[k] = 1'b0;
            if (go[k]) begin
                unique case (cls[k])
                    CLS_ALU:    ins_alu[k] = 1'b1;
                    CLS_BRANCH: ins_br[k] = 1'b1;
                    CLS_MEM:    ins_mem[k] = 1'b1;
                    CLS_FPADD:  ins_fadd[k] = 1'b1;
                    CLS_FPMUL:  ins_fmul[k] = 1'b1;
                    CLS_FPDIV:  ins_fdiv[k] = 1'b1;
                    CLS_IMUL:   ins_imul[k] = 1'b1;
                    CLS_IDIV:   ins_idiv[k] = 1'b1;
                    default: ;
                endcase
            end
        end
    end

//////////////////////////////////////////////////////////////////
    // Reorder buffer

    ReorderBuffer OTTER_ROB(
        .clk(CLK),
        .rst(RESET),
        .flush(flush),
        .squash(branch_recover),
        .squash_tag(recover_tag),
        .alloc0_en(dispatch0),
        .alloc0(rob_alloc0),
        .alloc1_en(dispatch1),
        .alloc1(rob_alloc1),
        .alloc0_tag(tag0),
        .alloc1_tag(tag1),
        .free_count(rob_free),
        .count(rob_count),
        .cdb0(cdb0),
        .cdb1(cdb1),
        .cdb2(cdb2),
        .done_vec(rob_done),
        .value_vec(rob_value),
        .head_tag(rob_head),
        .head0(h0),
        .head1(h1),
        .commit_count(commit_count)
    );

//////////////////////////////////////////////////////////////////
    // Reservation stations and execution units

    ReservationStation #(.ENTRIES(8), .SPEC_WAKE(1'b1)) RS_ALU (
        .clk(CLK), .rst(RESET), .flush(flush), .squash(branch_recover), .squash_tag(recover_tag),
        .ins0_en(ins_alu[0]), .ins0(rs_new0),
        .ins1_en(ins_alu[1]), .ins1(rs_new1),
        .free_count(free_alu), .cdb0(cdb0), .cdb1(cdb1), .cdb2(cdb2), .wk_valid(wk_valid), .wk_tag(wk_tag), .rob_head(rob_head),
        .issue_valid(alu_issue), .issue_entry(alu_sel), .issue_take(alu_issue),
        .issue1_valid(alu1_issue), .issue1_entry(alu1_sel), .issue1_take(alu1_issue)
    );

    ReservationStation #(.ENTRIES(BR_RS_ENTRIES), .SPEC_WAKE(1'b1)) RS_BR (
        .clk(CLK), .rst(RESET), .flush(flush), .squash(branch_recover), .squash_tag(recover_tag),
        .ins0_en(ins_br[0]), .ins0(rs_new0),
        .ins1_en(ins_br[1]), .ins1(rs_new1),
        .free_count(free_br), .cdb0(cdb0), .cdb1(cdb1), .cdb2(cdb2), .wk_valid(wk_valid), .wk_tag(wk_tag), .rob_head(rob_head),
        .issue_valid(br_issue), .issue_entry(br_sel), .issue_take(br_issue),
        .issue1_valid(), .issue1_entry(), .issue1_take(1'b0)
    );

    // ---- Issue -> execute registers ----------------------------------------
    // The ALUs and the branch unit never stall: whatever the stations select
    // executes next cycle on the unit's own CDB. A selected instruction that
    // a recovery squashes this cycle never enters execution.
    always_ff @(posedge CLK) begin
        if (RESET || flush) begin
            alu_e <= '0;
            alu1_e <= '0;
            br_e <= '0;
        end else begin
            alu_e <= alu_sel;
            alu_e.valid <= alu_issue && !(branch_recover && tag_younger(alu_sel.tag, recover_tag, rob_head));
            alu1_e <= alu1_sel;
            alu1_e.valid <= alu1_issue && !(branch_recover && tag_younger(alu1_sel.tag, recover_tag, rob_head));
            br_e <= br_sel;
            br_e.valid <= br_issue && !(branch_recover && tag_younger(br_sel.tag, recover_tag, rob_head));
        end
    end

    // Speculative wake-up: a selected ALU instruction's tag, broadcast now;
    // its value follows on the ALU's own CDB next cycle.
    always_comb begin
        wk_valid = {alu1_issue, alu_issue};
        wk_tag = {alu1_sel.tag, alu_sel.tag};
    end

    // ---- Integer ALU: one cycle, result straight onto a CDB ---------------
    logic [31:0] alu_u, alu_i, alu_s, alu_b_imm, alu_j, alu_a, alu_b, alu_result;

    ImmediateGenerator ALU_IMM (
        .IR(alu_e.ir[31:7]), .U_TYPE(alu_u), .I_TYPE(alu_i), .S_TYPE(alu_s),
        .B_TYPE(alu_b_imm), .J_TYPE(alu_j)
    );

    assign alu_a = alu_e.alu_src_a ? alu_u : alu_e.src1;
    assign alu_b = (alu_e.alu_src_b == 2'b00) ? alu_e.src2 :
                   (alu_e.alu_src_b == 2'b01) ? alu_i :
                   (alu_e.alu_src_b == 2'b10) ? alu_s : alu_e.pc;

    ALU OTTER_ALU (
        .SRC_A(alu_a),
        .SRC_B(alu_b),
        .ALU_FUN(alu_e.alu_fun),
        .RESULT(alu_result)
    );

    always_comb begin
        cdb_alu = '0;
        cdb_alu.valid = alu_e.valid;
        cdb_alu.tag = alu_e.tag;
        cdb_alu.value = alu_result;
    end

    // ---- Second integer ALU: the ALU station's second-oldest ready entry ---
    logic [31:0] alu1_u, alu1_i, alu1_s, alu1_b_imm, alu1_j, alu1_a, alu1_b, alu1_result;

    ImmediateGenerator ALU1_IMM (
        .IR(alu1_e.ir[31:7]), .U_TYPE(alu1_u), .I_TYPE(alu1_i), .S_TYPE(alu1_s),
        .B_TYPE(alu1_b_imm), .J_TYPE(alu1_j)
    );

    assign alu1_a = alu1_e.alu_src_a ? alu1_u : alu1_e.src1;
    assign alu1_b = (alu1_e.alu_src_b == 2'b00) ? alu1_e.src2 :
                    (alu1_e.alu_src_b == 2'b01) ? alu1_i :
                    (alu1_e.alu_src_b == 2'b10) ? alu1_s : alu1_e.pc;

    ALU OTTER_ALU1 (
        .SRC_A(alu1_a),
        .SRC_B(alu1_b),
        .ALU_FUN(alu1_e.alu_fun),
        .RESULT(alu1_result)
    );

    always_comb begin
        cdb_alu1 = '0;
        cdb_alu1.valid = alu1_e.valid;
        cdb_alu1.tag = alu1_e.tag;
        cdb_alu1.value = alu1_result;
    end

    // ---- Branch unit: one cycle ------------------------------------------
    logic [31:0] br_u, br_i, br_s, br_b, br_j, br_branch_tgt, br_jalr_tgt, br_jal_tgt;
    logic [2:0] br_pcsource;

    ImmediateGenerator BR_IMM (
        .IR(br_e.ir[31:7]), .U_TYPE(br_u), .I_TYPE(br_i), .S_TYPE(br_s),
        .B_TYPE(br_b), .J_TYPE(br_j)
    );

    BranchGenerator OTTER_BRANCH_GEN (
        .J(br_j), .B(br_b), .I(br_i), .PC(br_e.pc),
        .rs1(br_e.src1), .rs2(br_e.src2),
        .IR_OPCODE(br_e.ir[6:0]), .IR_FUNCT(br_e.ir[14:12]),
        .branch(br_branch_tgt), .jalr(br_jalr_tgt), .jal(br_jal_tgt),
        .pcsource(br_pcsource)
    );

    always_comb begin
        logic taken;
        logic [31:0] target;
        taken = (br_pcsource != 3'b000);
        target = (br_pcsource == 3'b001) ? br_jalr_tgt :
                 (br_pcsource == 3'b010) ? br_branch_tgt :
                 (br_pcsource == 3'b011) ? br_jal_tgt : br_e.pc_next;

        cdb_br = '0;
        cdb_br.valid = br_e.valid;
        cdb_br.tag = br_e.tag;
        cdb_br.value = br_e.pc_next;      // jal/jalr link value
        cdb_br.taken = taken;
        cdb_br.next_pc = target;
        cdb_br.mispredict = (br_e.predicted_taken != taken) ||
                                     (taken && br_e.predicted_target != target);
    end

    // A mispredicted branch recovers as it executes (it owns CDB 2 that
    // cycle, so its result and the squash land together). A commit-time
    // flush takes priority.
    assign branch_recover = br_e.valid && cdb_br.mispredict && !flush;
    assign recover_tag = br_e.tag;
    assign recover_target = cdb_br.next_pc;

    // ---- Load/store unit ---------------------------------------------------
    LoadStoreUnit OTTER_LSU (
        .clk(CLK), .rst(RESET), .flush(flush), .squash(branch_recover), .squash_tag(recover_tag),
        .ins0_en(ins_mem[0]), .ins0(rs_new0),
        .ins1_en(ins_mem[1]), .ins1(rs_new1),
        .free_count(free_mem),
        .cdb0(cdb0), .cdb1(cdb1), .cdb2(cdb2), .rob_head(rob_head),
        .cdb_req(cdb_lsu),
        .cdb_grant(cdb_grant[REQ_LSU]),
        .commit_store(lsu_commit_store),
        .store_buffer_full(lsu_sb_full),
        .drained(lsu_drained),
        .busy(lsu_busy),
        .mem_rden2(mem_rden2_dc),
        .mem_we2(mem_we2_dc),
        .mem_addr2(mem_addr2_dc),
        .mem_din2(mem_din2_dc),
        .mem_size(mem_size_dc),
        .mem_sign(mem_sign_dc),
        .mem_dout2(mem_dout2_mem),
        .atomic_valid(atomic_valid),
        .atomic_op(atomic_op),
        .atomic_sc_ok(atomic_sc_ok),
        .atomic_addr(atomic_addr),
        .atomic_wdata(atomic_wdata),
        .atomic_write_intent(atomic_write_intent),
        .atomic_preview_word(atomic_preview_word),
        .atomic_sc_result(atomic_sc_result),
        .atomic_commit_valid(atomic_commit_valid),
        .atomic_commit_op(atomic_commit_op),
        .atomic_commit_addr(atomic_commit_addr),
        .storebuf_enqueue_event(storebuf_enqueue_event),
        .storebuf_forward_event(storebuf_forward_event),
        .storebuf_conflict_event(storebuf_conflict_event),
        .storebuf_drain_event(storebuf_drain_event),
        .dcache_miss_start(dcache_miss_start),
        .dcache_hit_event(dcache_hit_event),
        .l2_hit_event(l2_hit_event),
        .load_complete_event(load_complete_event),
        .reservation_valid(reservation_valid),
        .reservation_set_event(reservation_set_event),
        .reservation_clear_event(reservation_clear_event)
    );

    // ---- FP units ----------------------------------------------------------
    // The pipelined units advance unless a finished result is still waiting
    // for a CDB; a tag shadow pipeline follows each operation.
    ReservationStation #(.ENTRIES(2)) RS_FADD (
        .clk(CLK), .rst(RESET), .flush(flush), .squash(branch_recover), .squash_tag(recover_tag),
        .ins0_en(ins_fadd[0]), .ins0(rs_new0),
        .ins1_en(ins_fadd[1]), .ins1(rs_new1),
        .free_count(free_fadd), .cdb0(cdb0), .cdb1(cdb1), .cdb2(cdb2), .wk_valid(wk_valid), .wk_tag(wk_tag), .rob_head(rob_head),
        .issue_valid(fadd_issue), .issue_entry(fadd_e), .issue_take(fadd_issue && fadd_advance),
        .issue1_valid(), .issue1_entry(), .issue1_take(1'b0)
    );

    ReservationStation #(.ENTRIES(2)) RS_FMUL (
        .clk(CLK), .rst(RESET), .flush(flush), .squash(branch_recover), .squash_tag(recover_tag),
        .ins0_en(ins_fmul[0]), .ins0(rs_new0),
        .ins1_en(ins_fmul[1]), .ins1(rs_new1),
        .free_count(free_fmul), .cdb0(cdb0), .cdb1(cdb1), .cdb2(cdb2), .wk_valid(wk_valid), .wk_tag(wk_tag), .rob_head(rob_head),
        .issue_valid(fmul_issue), .issue_entry(fmul_e), .issue_take(fmul_issue && fmul_advance),
        .issue1_valid(), .issue1_entry(), .issue1_take(1'b0)
    );

    ReservationStation #(.ENTRIES(2)) RS_FDIV (
        .clk(CLK), .rst(RESET), .flush(flush), .squash(branch_recover), .squash_tag(recover_tag),
        .ins0_en(ins_fdiv[0]), .ins0(rs_new0),
        .ins1_en(ins_fdiv[1]), .ins1(rs_new1),
        .free_count(free_fdiv), .cdb0(cdb0), .cdb1(cdb1), .cdb2(cdb2), .wk_valid(wk_valid), .wk_tag(wk_tag), .rob_head(rob_head),
        .issue_valid(fdiv_issue), .issue_entry(fdiv_e), .issue_take(fdiv_start),
        .issue1_valid(), .issue1_entry(), .issue1_take(1'b0)
    );


    assign fadd_advance = !(cdb_fadd.valid && !cdb_grant[REQ_FADD]);
    assign fmul_advance = !(cdb_fmul.valid && !cdb_grant[REQ_FMUL]);
    // A squashed division is abandoned; a squashed one is never started.
    assign fdiv_kill = branch_recover && fdiv_busy && tag_younger(fdiv_tag, recover_tag, rob_head);
    assign fdiv_start = fdiv_issue && !fdiv_busy &&
                        !(branch_recover && tag_younger(fdiv_e.tag, recover_tag, rob_head));

    fp_adder OTTER_FP_ADDER(
        .clk(CLK),
        .rst(RESET || flush),
        .advance(fadd_advance),
        .in_valid(fadd_issue),
        .in_sub(fadd_e.fp_sub),
        .in_a(fadd_e.src1),
        .in_b(fadd_e.src2),
        .in_rm(fadd_e.fp_rm),
        .out_valid(fadd_valid),
        .out_result(fadd_result),
        .out_flags(fadd_flags)
    );

    fp_multiplier OTTER_FP_MULTIPLIER(
        .clk(CLK),
        .rst(RESET || flush),
        .advance(fmul_advance),
        .in_valid(fmul_issue),
        .in_a(fmul_e.src1),
        .in_b(fmul_e.src2),
        .in_rm(fmul_e.fp_rm),
        .out_valid(fmul_valid),
        .out_result(fmul_result),
        .out_flags(fmul_flags)
    );

    fp_divider OTTER_FP_DIVIDER(
        .clk(CLK),
        .rst(RESET || flush || fdiv_kill),
        .in_valid(fdiv_start),
        .in_a(fdiv_e.src1),
        .in_b(fdiv_e.src2),
        .in_rm(fdiv_e.fp_rm),
        .busy(fdiv_busy),
        .out_valid(fdiv_valid),
        .out_result(fdiv_result),
        .out_flags(fdiv_flags),
        .ack(cdb_grant[REQ_FDIV])
    );

    // ---- RV32M units --------------------------------------------------------
    // Multiplies: a 3-stage pipeline, one per cycle, squashed with live bits
    // like the FP pipelines. Divides: iterative (about 35 cycles), one at a
    // time, killed by a squash like the FP divider.
    ReservationStation #(.ENTRIES(2), .SPEC_WAKE(1'b1)) RS_IMUL (
        .clk(CLK), .rst(RESET), .flush(flush), .squash(branch_recover), .squash_tag(recover_tag),
        .ins0_en(ins_imul[0]), .ins0(rs_new0),
        .ins1_en(ins_imul[1]), .ins1(rs_new1),
        .free_count(free_imul), .cdb0(cdb0), .cdb1(cdb1), .cdb2(cdb2), .wk_valid(wk_valid), .wk_tag(wk_tag), .rob_head(rob_head),
        .issue_valid(imul_issue), .issue_entry(imul_e), .issue_take(imul_issue && imul_advance),
        .issue1_valid(), .issue1_entry(), .issue1_take(1'b0)
    );

    ReservationStation #(.ENTRIES(2)) RS_IDIV (
        .clk(CLK), .rst(RESET), .flush(flush), .squash(branch_recover), .squash_tag(recover_tag),
        .ins0_en(ins_idiv[0]), .ins0(rs_new0),
        .ins1_en(ins_idiv[1]), .ins1(rs_new1),
        .free_count(free_idiv), .cdb0(cdb0), .cdb1(cdb1), .cdb2(cdb2), .wk_valid(wk_valid), .wk_tag(wk_tag), .rob_head(rob_head),
        .issue_valid(idiv_issue), .issue_entry(idiv_e), .issue_take(idiv_start),
        .issue1_valid(), .issue1_entry(), .issue1_take(1'b0)
    );

    assign imul_advance = !(cdb_imul.valid && !cdb_grant[REQ_IMUL]);
    assign idiv_kill = branch_recover && idiv_busy && tag_younger(idiv_tag, recover_tag, rob_head);
    assign idiv_start = idiv_issue && !idiv_busy &&
                        !(branch_recover && tag_younger(idiv_e.tag, recover_tag, rob_head));

    IntMultiplier OTTER_INT_MULTIPLIER (
        .clk(CLK),
        .rst(RESET || flush),
        .advance(imul_advance),
        .in_valid(imul_issue),
        .in_op(imul_e.alu_fun[1:0]),
        .in_a(imul_e.src1),
        .in_b(imul_e.src2),
        .out_valid(imul_valid),
        .out_result(imul_result)
    );

    IntDivider OTTER_INT_DIVIDER (
        .clk(CLK),
        .rst(RESET || flush || idiv_kill),
        .in_valid(idiv_start),
        .in_op(idiv_e.alu_fun[1:0]),
        .in_a(idiv_e.src1),
        .in_b(idiv_e.src2),
        .busy(idiv_busy),
        .out_valid(idiv_valid),
        .out_result(idiv_result),
        .ack(cdb_grant[REQ_IDIV])
    );

    always_ff @(posedge CLK) begin
        logic sq;
        sq = branch_recover;
        if (imul_advance) begin
            imul_tag1 <= imul_e.tag;
            imul_tag2 <= imul_tag1;
            imul_tag3 <= imul_tag2;
            imul_live1 <= imul_issue && !(sq && tag_younger(imul_e.tag, recover_tag, rob_head));
            imul_live2 <= imul_live1 && !(sq && tag_younger(imul_tag1, recover_tag, rob_head));
            imul_live3 <= imul_live2 && !(sq && tag_younger(imul_tag2, recover_tag, rob_head));
        end else if (sq) begin
            imul_live1 <= imul_live1 && !tag_younger(imul_tag1, recover_tag, rob_head);
            imul_live2 <= imul_live2 && !tag_younger(imul_tag2, recover_tag, rob_head);
            imul_live3 <= imul_live3 && !tag_younger(imul_tag3, recover_tag, rob_head);
        end
        if (idiv_start)
            idiv_tag <= idiv_e.tag;
    end

    always_comb begin
        cdb_imul = '0;
        cdb_imul.valid = imul_valid && imul_live3;
        cdb_imul.tag = imul_tag3;
        cdb_imul.value = imul_result;

        cdb_idiv = '0;
        cdb_idiv.valid = idiv_valid;
        cdb_idiv.tag = idiv_tag;
        cdb_idiv.value = idiv_result;
    end

    always_ff @(posedge CLK) begin
        logic sq;
        sq = branch_recover;
        if (fadd_advance) begin
            fadd_tag1 <= fadd_e.tag;
            fadd_tag2 <= fadd_tag1;
            fadd_live1 <= fadd_issue && !(sq && tag_younger(fadd_e.tag, recover_tag, rob_head));
            fadd_live2 <= fadd_live1 && !(sq && tag_younger(fadd_tag1, recover_tag, rob_head));
        end else if (sq) begin
            fadd_live1 <= fadd_live1 && !tag_younger(fadd_tag1, recover_tag, rob_head);
            fadd_live2 <= fadd_live2 && !tag_younger(fadd_tag2, recover_tag, rob_head);
        end
        if (fmul_advance) begin
            fmul_tag1 <= fmul_e.tag;
            fmul_tag2 <= fmul_tag1;
            fmul_live1 <= fmul_issue && !(sq && tag_younger(fmul_e.tag, recover_tag, rob_head));
            fmul_live2 <= fmul_live1 && !(sq && tag_younger(fmul_tag1, recover_tag, rob_head));
        end else if (sq) begin
            fmul_live1 <= fmul_live1 && !tag_younger(fmul_tag1, recover_tag, rob_head);
            fmul_live2 <= fmul_live2 && !tag_younger(fmul_tag2, recover_tag, rob_head);
        end
        if (fdiv_start)
            fdiv_tag <= fdiv_e.tag;
    end

    always_comb begin
        cdb_fadd = '0;
        cdb_fadd.valid = fadd_valid && fadd_live2;
        cdb_fadd.tag = fadd_tag2;
        cdb_fadd.value = fadd_result;
        cdb_fadd.fp_flags = fadd_flags;

        cdb_fmul = '0;
        cdb_fmul.valid = fmul_valid && fmul_live2;
        cdb_fmul.tag = fmul_tag2;
        cdb_fmul.value = fmul_result;
        cdb_fmul.fp_flags = fmul_flags;

        cdb_fdiv = '0;
        cdb_fdiv.valid = fdiv_valid;
        cdb_fdiv.tag = fdiv_tag;
        cdb_fdiv.value = fdiv_result;
        cdb_fdiv.fp_flags = fdiv_flags;
    end

    // Index order matches REQ_*.
    // A fast CSR access at the ROB head broadcasts the CSR value it read, so
    // younger dependents wake up. It is the oldest request, so it always wins.
    always_comb begin
        cdb_csr = '0;
        cdb_csr.valid = h0_csr && !h0.done;
        cdb_csr.tag = rob_head;
        cdb_csr.value = csr_rdata;
    end

    // Requests by index (REQ_*).
    always_comb begin
        cdb_req[REQ_LSU]  = cdb_lsu;
        cdb_req[REQ_FADD] = cdb_fadd;
        cdb_req[REQ_FMUL] = cdb_fmul;
        cdb_req[REQ_FDIV] = cdb_fdiv;
        cdb_req[REQ_CSR]  = cdb_csr;
        cdb_req[REQ_IMUL] = cdb_imul;
        cdb_req[REQ_IDIV] = cdb_idiv;
    end
    logic [REQUESTERS-1:0] cdb_req_valid;      // for the testbench report
    always_comb begin
        for (int i = 0; i < REQUESTERS; i++)
            cdb_req_valid[i] = cdb_req[i].valid;
    end

    assign bus_free = {!br_e.valid, !alu1_e.valid, !alu_e.valid};

    CdbArbiter #(.REQUESTERS(REQUESTERS)) OTTER_CDB_ARBITER (
        .req(cdb_req),
        .rob_head(rob_head),
        .bus_free(bus_free),
        .grant(cdb_grant),
        .bus0(arb_bus0),
        .bus1(arb_bus1),
        .bus2(arb_bus2)
    );

    // Each bus: its owner unit's result when it executes, else a granted request.
    assign cdb0 = alu_e.valid ? cdb_alu : arb_bus0;
    assign cdb1 = alu1_e.valid ? cdb_alu1 : arb_bus1;
    assign cdb2 = br_e.valid ? cdb_br : arb_bus2;

//////////////////////////////////////////////////////////////////
    // Commit

    // CSR instructions read and write their CSR as they commit. The CSR read
    // port otherwise checks the slot-0 CSR address for legality at dispatch.
    assign h0_csr = h0.valid && h0.sys_csr;
    assign csr_addr = h0_csr ? h0.ir[31:20] : if_id.ir[31:20];
    assign csr_write_attempt = h0_csr ? (h0.ir[13:12] == 2'b01 || h0.ir[19:15] != 5'd0)
                                      : dec_csr_write_attempt[0];
    assign csr_wdata = (h0.ir[13:12] == 2'b01) ? h0.csr_src :
                       (h0.ir[13:12] == 2'b10) ? (csr_rdata | h0.csr_src) :
                                                  (csr_rdata & ~h0.csr_src);

    always_comb begin
        logic h0_ready, h1_ready;

        trap_take = 1'b0;
        interrupt_take = 1'b0;
        mret_commit = 1'b0;
        fence_i_commit = 1'b0;
        fence_wait = 1'b0;
        commit0 = 1'b0;
        commit1 = 1'b0;
        lsu_commit_store = 1'b0;
        csr_write_en = 1'b0;
        commit0_value = h0.value;

        h0_ready = h0.valid && h0.done;

        if (h0_ready && h0.exception) begin
            trap_take = 1'b1;
        end else if (h0_ready) begin
            commit0 = 1'b1;
            if (h0.is_store) begin
                commit0 = !lsu_sb_full;
                lsu_commit_store = commit0;
            end
            if (h0.sys_csr) begin
                commit0_value = csr_rdata;
                csr_write_en = csr_write_attempt;
            end
            if (h0.sys_mret)
                mret_commit = 1'b1;
            if (h0.sys_fence || h0.sys_fence_i) begin
                fence_wait = !lsu_drained;
                commit0 = lsu_drained;
                fence_i_commit = h0.sys_fence_i && lsu_drained;
            end
        end else if (rob_count == 5'd0 && csr_interrupt_pending && if_id.valid) begin
            interrupt_take = 1'b1;
        end

        // A second, simple instruction may retire alongside the first.
        h1_ready = h1.valid && h1.done && !h1.exception && !h1.serial && !h1.is_control;
        commit1 = commit0 && !h0.serial && h1_ready &&
                  !(h1.is_store && (h0.is_store || lsu_sb_full));
        if (commit1 && h1.is_store)
            lsu_commit_store = 1'b1;

        commit_count = {1'b0, commit0} + {1'b0, commit1};
        flush = trap_take || interrupt_take || mret_commit || fence_i_commit;
        icache_invalidate = fence_i_commit;
    end

    // Fetch redirect: a commit-time flush, or a branch recovering at execute.
    always_comb begin
        redirect_valid = flush || branch_recover;
        redirect_target = (trap_take || interrupt_take) ? mtvec_csr :
                          mret_commit ? mepc_csr :
                          fence_i_commit ? h0.pc_next :
                          recover_target;
    end

    CSR_FILE OTTER_CSR_FILE(
        .CLK(CLK),
        .RST(RESET),
        .read_addr(csr_addr),
        .read_data(csr_rdata),
        .access_write_attempt(csr_write_attempt),
        .access_illegal(csr_illegal),
        .write_en(csr_write_en),
        .write_addr(h0.ir[31:20]),
        .write_data(csr_wdata),
        .trap_en(trap_take || interrupt_take),
        .trap_pc(interrupt_take ? if_id.pc : h0.pc),
        .trap_cause(interrupt_take ? csr_interrupt_cause : h0.cause),
        .trap_tval(interrupt_take ? 32'b0 : h0.tval),
        .mret_en(mret_commit),
        .timer_interrupt_pending(timer_interrupt_pending),
        .external_interrupt_pending(INTR),
        .retire_count(commit_count),
        .branch_flush_event(branch_recover),
        .load_use_stall_event(dispatch_stall),
        .icache_miss_event(cache_update),
        .dcache_miss_event(dcache_miss_start),
        .prefetch_hit_event(prefetch_hit_event),
        .prefetch_useless_event(prefetch_useless_event),
        .trap_event(trap_take || interrupt_take),
        .mext_busy_event(idiv_busy || imul_valid),
        .mext_stall_event(1'b0),
        .storebuf_enqueue_event(storebuf_enqueue_event),
        .storebuf_full_stall_event(h0_ready_store_blocked),
        .store_to_load_forward_event(storebuf_forward_event),
        .store_conflict_stall_event(storebuf_conflict_event),
        .dcache_store_drain_event(storebuf_drain_event),
        .fence_wait_event(fence_wait || fence_dispatch_wait),
        .fp_dirty((commit0 && h0.wr_fp) || (commit1 && h1.wr_fp)),
        .fflags_accrue((commit0 && h0.fp_arith) || (commit1 && h1.fp_arith)),
        .fflags_new(((commit0 && h0.fp_arith) ? h0.fp_flags : 5'b0) |
                    ((commit1 && h1.fp_arith) ? h1.fp_flags : 5'b0)),
        .frm(frm_csr),
        .fs(fs_csr),
        .mtvec(mtvec_csr),
        .mepc(mepc_csr),
        .interrupt_pending(csr_interrupt_pending),
        .interrupt_cause(csr_interrupt_cause)
    );

    assign h0_ready_store_blocked = h0.valid && h0.done && h0.is_store && lsu_sb_full;

//////////////////////////////////////////////////////////////////
    // Data memory and MMIO

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
        .MEM_ATOMIC_VALID(atomic_valid),
        .MEM_ATOMIC_OP(atomic_op),
        .MEM_ATOMIC_SC_OK(atomic_sc_ok),
        .MEM_ATOMIC_ADDR(atomic_addr),
        .MEM_ATOMIC_DIN(atomic_wdata),
        .MEM_ATOMIC_PREVIEW_ADDR(atomic_addr),
        .IO_IN(IOBUS_IN),
        .IO_WR(IOBUS_WR),
        .MEM_DOUT1(),
        .MEM_DOUT2(mem_dout2_mem),
        .MEM_ATOMIC_PREVIEW_WORD(atomic_preview_word),
        .MEM_ATOMIC_RESULT(atomic_sc_result),
        .MEM_ATOMIC_COMMIT_VALID(atomic_commit_valid),
        .MEM_ATOMIC_COMMIT_WRITE(atomic_commit_write),
        .MEM_ATOMIC_COMMIT_OP(atomic_commit_op),
        .MEM_ATOMIC_COMMIT_SC_SUCCESS(atomic_commit_sc_success),
        .MEM_ATOMIC_COMMIT_ADDR(atomic_commit_addr),
        .MEM_ATOMIC_COMMIT_OLD_WORD(atomic_commit_old_word),
        .MEM_ATOMIC_COMMIT_NEW_WORD(atomic_commit_new_word),
        .MEM_TIMER_INTERRUPT(timer_interrupt_pending)
    );

    assign IOBUS_OUT = mem_din2_dc;
    assign IOBUS_ADDR = mem_addr2_dc;

endmodule
