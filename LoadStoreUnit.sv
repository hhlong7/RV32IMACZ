`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: LoadStoreUnit
// Description:
//   Memory side of the out-of-order core.
//
//   Memory queue   in-order reservation station for loads, stores, and
//                  atomics (program order among memory operations).
//   Store queue    stores whose address and data are known, waiting for
//                  commit; commit moves the oldest into the store buffer,
//                  which drains to the D-cache/L2/memory as before.
//   Forwarding     a load at the queue head checks the store queue: the
//                  youngest overlapping older store forwards its data if it
//                  covers the whole load (the load completes at once); a
//                  partial overlap, or any older store before an MMIO load,
//                  makes the load wait for those stores to commit.
//   Load stage     one load at a time drives the D-cache, L2, store-buffer
//                  forwarding (committed stores), and refill FSM.
//   Atomics        run only at the ROB head with all stores drained:
//                  read the old word, then commit the read-modify-write.
//   Output buffer  one completion for the common data bus.
//
//   A squash (mispredicted branch) drops everything younger than the branch:
//   memory-queue entries, the store-queue tail, the output buffer, and the
//   load in flight. On a flush everything waiting is dropped. A load already inside a cache
//   refill finishes (the refill cannot be abandoned) and is then discarded.
//////////////////////////////////////////////////////////////////////////////////
module LoadStoreUnit
    import otter_defs_pkg::*;
    import ooo_pkg::*;
#(
    parameter int QUEUE_ENTRIES = 8,
    parameter int SQ_ENTRIES = 4,
    parameter int STOREBUF_DEPTH = 4
) (
    input  logic clk,
    input  logic rst,
    input  logic flush,
    input  logic squash,
    input  tag_t squash_tag,

    // Dispatch into the memory queue.
    input  logic      ins0_en,
    input  rs_entry_t ins0,
    input  logic      ins1_en,
    input  rs_entry_t ins1,
    output logic [3:0] free_count,

    input  cdb_t cdb0,
    input  cdb_t cdb1,
    input  cdb_t cdb2,
    input  tag_t rob_head,

    // Completion.
    output cdb_t cdb_req,
    input  logic cdb_grant,

    // Commit: move the oldest store queue entry into the store buffer.
    input  logic commit_store,
    output logic store_buffer_full,
    output logic drained,                 // store buffer empty and D-side idle
    output logic busy,                    // a load or atomic is in progress

    // Data memory port (also snooped by the instruction memories).
    output logic        mem_rden2,
    output logic        mem_we2,
    output logic [31:0] mem_addr2,
    output logic [31:0] mem_din2,
    output logic [1:0]  mem_size,
    output logic        mem_sign,
    input  logic [31:0] mem_dout2,

    // Atomic port of the data memory.
    output logic        atomic_valid,
    output logic [3:0]  atomic_op,
    output logic        atomic_sc_ok,
    output logic [31:0] atomic_addr,
    output logic [31:0] atomic_wdata,
    output logic        atomic_write_intent,
    input  logic [31:0] atomic_preview_word,
    input  logic [31:0] atomic_sc_result,
    input  logic        atomic_commit_valid,
    input  logic [3:0]  atomic_commit_op,
    input  logic [31:0] atomic_commit_addr,

    // Events for the performance counters and testbench.
    output logic storebuf_enqueue_event,
    output logic storebuf_forward_event,
    output logic storebuf_conflict_event,
    output logic storebuf_drain_event,
    output logic dcache_miss_start,
    output logic dcache_hit_event,
    output logic l2_hit_event,
    output logic load_complete_event,
    output logic reservation_valid,
    output logic reservation_set_event,
    output logic reservation_clear_event
);
    localparam int SQ_BITS = $clog2(SQ_ENTRIES);

    // ---- helpers -----------------------------------------------------------
    function automatic logic [3:0] byte_mask(input logic [1:0] size, input logic [1:0] offset);
        unique case (size)
            2'd0: byte_mask = 4'b0001 << offset;
            2'd1: byte_mask = 4'b0011 << offset;
            default: byte_mask = 4'b1111;
        endcase
    endfunction

    function automatic logic [31:0] format_load(input logic [31:0] word, input logic [1:0] size,
                                                input logic is_unsigned, input logic [1:0] offset);
        logic [7:0] b;
        logic [15:0] h;
        b = word[offset * 8 +: 8];
        h = offset[1] ? word[31:16] : word[15:0];
        unique case (size)
            2'd0: format_load = is_unsigned ? {24'd0, b} : {{24{b[7]}}, b};
            2'd1: format_load = is_unsigned ? {16'd0, h} : {{16{h[15]}}, h};
            default: format_load = word;
        endcase
    endfunction

    function automatic logic misaligned(input logic [31:0] addr, input logic [1:0] size);
        misaligned = ((size == 2'd1) && addr[0]) || ((size == 2'd2) && (addr[1:0] != 2'b00));
    endfunction

    // ---- memory queue ------------------------------------------------------
    logic      head_valid;
    rs_entry_t head;
    logic      head_take;

    ReservationStation #(.ENTRIES(QUEUE_ENTRIES), .IN_ORDER(1'b1)) MEMQ (
        .clk, .rst, .flush, .squash, .squash_tag,
        .ins0_en, .ins0, .ins1_en, .ins1, .free_count,
        .cdb0, .cdb1, .cdb2, .rob_head,
        .issue_valid(head_valid), .issue_entry(head), .issue_take(head_take),
        .issue1_valid(), .issue1_entry(), .issue1_take(1'b0)
    );

    logic [31:0] head_imm, head_addr;
    logic [1:0] head_size;
    logic head_misaligned;

    assign head_imm = head.mem_store ? {{20{head.ir[31]}}, head.ir[31:25], head.ir[11:7]} :
                      head.mem_load  ? {{20{head.ir[31]}}, head.ir[31:20]} : 32'b0;
    assign head_addr = head.src1 + head_imm;
    assign head_size = head.ir[13:12];
    assign head_misaligned = misaligned(head_addr, head_size);

    // ---- output buffer -----------------------------------------------------
    cdb_t out_q;
    logic out_free;          // a new completion can be written at this edge
    logic load_claims_out;   // the finishing load takes the output buffer
    logic head_out_free;     // ...otherwise the memory queue head may use it

    assign cdb_req = out_q;
    assign out_free = !out_q.valid || cdb_grant;


    function automatic cdb_t completion(input tag_t tag, input logic [31:0] value);
        completion = '0;
        completion.valid = 1'b1;
        completion.tag = tag;
        completion.value = value;
    endfunction

    function automatic cdb_t misaligned_fault(input tag_t tag, input logic is_load, input logic [31:0] addr);
        misaligned_fault = completion(tag, 32'b0);
        misaligned_fault.exception = 1'b1;
        misaligned_fault.cause = is_load ? 32'd4 : 32'd6;   // load / store-AMO address misaligned
        misaligned_fault.tval = addr;
    endfunction

    // ---- store queue -------------------------------------------------------
    typedef struct packed {
        tag_t tag;
        logic [31:0] addr;
        logic [31:0] data;
        logic [1:0] size;
    } sq_entry_t;

    sq_entry_t [SQ_ENTRIES-1:0] sq;
    logic [SQ_BITS-1:0] sq_head, sq_tail;
    logic [SQ_BITS:0] sq_count;
    sq_entry_t sq_oldest;

    assign sq_oldest = sq[sq_head];

    // ---- load stage and atomics -------------------------------------------
    typedef struct packed {
        logic valid;
        logic squashed;          // flushed while in flight: finish quietly
        tag_t tag;
        logic [31:0] addr;
        logic [1:0] size;
        logic is_unsigned;
    } load_t;

    load_t ld;

    typedef enum logic [1:0] { AT_IDLE, AT_READ, AT_WRITE } atomic_state_t;
    atomic_state_t at_state;
    tag_t at_tag;
    logic [31:0] at_addr, at_wdata, at_old;
    logic [3:0] at_op;

    // ---- D-side datapath ---------------------------------------------------
    logic dc_hit, dc_miss, dc_cacheable, dc_enable_write, dc_last;
    logic [2:0] dc_fill_select;
    logic [31:0] dc_rdata, dc_fill_word;
    logic l2_hit, l2_miss, l2_cacheable, l2_refill, l2_fill_write, l2_fill_last;
    logic [2:0] l2_fill_select;
    logic [31:0] l2_line_word;
    logic fsm_stall, fsm_busy;
    logic sb_full, sb_empty, sb_drain_valid, sb_drain_accept;
    logic [31:0] sb_drain_addr, sb_drain_data, sb_fwd_word;
    logic [3:0] sb_drain_mask;
    logic sb_fwd_hit, sb_fwd_conflict;
    logic [$clog2(STOREBUF_DEPTH + 1) - 1:0] sb_occupancy;
    logic [3:0] ld_mask;
    logic [31:0] load_result;
    logic load_done;
    logic reservation_q;
    logic [29:0] reservation_addr_q;

    assign ld_mask = byte_mask(ld.size, ld.addr[1:0]);

    StoreBuffer #(.DEPTH(STOREBUF_DEPTH)) STORE_BUFFER (
        .clk, .rst,
        .enqueue_valid(commit_store),
        .enqueue_addr(sq_oldest.addr),
        .enqueue_data(sq_oldest.data),
        .enqueue_mask(byte_mask(sq_oldest.size, sq_oldest.addr[1:0])),
        .drain_accept(sb_drain_accept),
        .query_valid(ld.valid && dc_cacheable),
        .query_addr(ld.addr),
        .query_mask(ld_mask),
        .full(sb_full),
        .empty(sb_empty),
        .occupancy(sb_occupancy),
        .drain_valid(sb_drain_valid),
        .drain_addr(sb_drain_addr),
        .drain_data(sb_drain_data),
        .drain_mask(sb_drain_mask),
        .forward_hit(sb_fwd_hit),
        .forward_conflict(sb_fwd_conflict),
        .forward_data_word(sb_fwd_word)
    );

    datacache DCACHE (
        .clk, .rst,
        .loadAddr(ld.addr),
        .loadRead(ld.valid),
        .loadSize(ld.size),
        .loadSign(ld.is_unsigned),
        .drainStoreValid(sb_drain_accept),
        .drainStoreAddr(sb_drain_addr),
        .drainStoreData(sb_drain_data),
        .drainStoreMask(sb_drain_mask),
        .atomicInvalidateValid(atomic_write_intent),
        .atomicInvalidateAddr(at_addr),
        .enable_write(dc_enable_write),
        .select(dc_fill_select),
        .word_data(dc_fill_word),
        .last(dc_last),
        .loadRData(dc_rdata),
        .loadHit(dc_hit),
        .loadMiss(dc_miss),
        .loadCacheable(dc_cacheable)
    );

    l2cache L2CACHE (
        .clk, .rst,
        .queryAddr(ld.addr),
        .queryValid(ld.valid && dc_cacheable && dc_miss && !sb_fwd_hit && !sb_fwd_conflict),
        .lineReadAddr(ld.addr),
        .lineReadSelect(dc_fill_select),
        .fillAddr(ld.addr),
        .fillWrite(l2_fill_write),
        .fillSelect(l2_fill_select),
        .fillLast(l2_fill_last),
        .fillWordData(mem_dout2),
        .drainStoreValid(sb_drain_accept),
        .drainStoreAddr(sb_drain_addr),
        .drainStoreData(sb_drain_data),
        .drainStoreMask(sb_drain_mask),
        .atomicInvalidateValid(atomic_write_intent),
        .atomicInvalidateAddr(at_addr),
        .queryHit(l2_hit),
        .queryMiss(l2_miss),
        .queryCacheable(l2_cacheable),
        .lineReadData(l2_line_word)
    );

    assign dc_fill_word = l2_refill ? l2_line_word : mem_dout2;

    datacachefsm DCACHE_FSM (
        .clk, .rst,
        .exmemRead(ld.valid),
        .exmemWrite(commit_store),
        .exmemAddr(ld.addr),
        .exmemSize(ld.size),
        .exmemSign(ld.is_unsigned),
        .cacheMemReady(dc_cacheable),
        .hit(dc_hit),
        .l2Hit(l2_hit),
        .loadForwardHit(sb_fwd_hit),
        .loadForwardConflict(sb_fwd_conflict),
        .storebufFull(sb_full),
        .storebufEmpty(sb_empty),
        .storebufDrainValid(sb_drain_valid),
        .storebufDrainAddr(sb_drain_addr),
        .storebufDrainData(sb_drain_data),
        .storebufDrainMask(sb_drain_mask),
        .stall(fsm_stall),
        .enable_write(dc_enable_write),
        .select(dc_fill_select),
        .last(dc_last),
        .refill_from_l2(l2_refill),
        .l2_fill_write(l2_fill_write),
        .l2_fill_select(l2_fill_select),
        .l2_fill_last(l2_fill_last),
        .mem_rden2(mem_rden2),
        .mem_we2(mem_we2),
        .mem_addr2(mem_addr2),
        .mem_din2(mem_din2),
        .mem_size(mem_size),
        .mem_sign(mem_sign),
        .storebufDrainAccept(sb_drain_accept),
        .miss_start(dcache_miss_start),
        .busy(fsm_busy),
        .drain_event(storebuf_drain_event)
    );

    // Load data: store-buffer forward, D-cache hit, or the memory/MMIO port.
    assign load_result = sb_fwd_hit ? format_load(sb_fwd_word, ld.size, ld.is_unsigned, ld.addr[1:0]) :
                         (dc_cacheable && dc_hit) ? dc_rdata :
                         mem_dout2;
    // The FSM releases the load once its data is valid.
    assign load_done = ld.valid && !fsm_stall;
    // The load in flight is older than the queue head, so it goes first.
    assign load_claims_out = load_done && !ld.squashed && out_free;
    assign head_out_free = out_free && !load_claims_out;

    // ---- atomics -----------------------------------------------------------
    assign atomic_valid = (at_state == AT_WRITE);
    assign atomic_op = at_op;
    assign atomic_addr = at_addr;
    assign atomic_wdata = at_wdata;
    assign atomic_sc_ok = reservation_q && (at_op == ATOMIC_SC) &&
                          (reservation_addr_q == at_addr[31:2]);
    assign atomic_write_intent = atomic_valid &&
                                 ((at_op == ATOMIC_SC) ? atomic_sc_ok : (at_op != ATOMIC_LR));

    // A committed LR sets the reservation; any other atomic commit, or a
    // store to the reserved word entering the store buffer, clears it.
    assign reservation_set_event = atomic_commit_valid && (atomic_commit_op == ATOMIC_LR);
    assign reservation_clear_event = (atomic_commit_valid && (atomic_commit_op != ATOMIC_LR)) ||
                                     (commit_store && reservation_q &&
                                      (reservation_addr_q == sq_oldest.addr[31:2]));
    assign reservation_valid = reservation_q;

    // Store-queue entries older than a squashing branch.
    logic [SQ_BITS:0] sq_keep;
    always_comb begin
        sq_keep = '0;
        for (int i = 0; i < SQ_ENTRIES; i++) begin
            sq_entry_t e;
            e = sq[SQ_BITS'(sq_head + SQ_BITS'(i))];
            if ((SQ_BITS+1)'(i) < sq_count && !tag_younger(e.tag, squash_tag, rob_head))
                sq_keep = (SQ_BITS+1)'(i + 1);
        end
    end

    // ---- store-queue forwarding ----------------------------------------------
    // The memory queue is in order, so when a load reaches its head every
    // older store is already in the store queue with its address and data.
    // The youngest store that overlaps the load decides: if it covers every
    // byte the load reads, its data is forwarded and the load finishes at
    // once; a partial overlap makes the load wait for those stores to commit.
    // MMIO loads always wait for older stores, keeping device accesses in
    // program order.
    logic head_mmio;
    logic sq_fwd_hit, sq_fwd_block;
    logic [31:0] sq_fwd_value;
    logic sq_forward_take;                    // a load completes by forwarding

    assign head_mmio = (head_addr >= 32'h0001_0000);

    // always @* (not always_comb): Icarus 12 hangs on always_comb blocks that
    // share called functions; this block only calls byte_mask (no locals).
    always @* begin
        logic [3:0] lmask, smask;
        logic [31:0] word, shifted;
        logic [7:0] b;
        logic [15:0] h;
        sq_fwd_hit = 1'b0;
        sq_fwd_block = 1'b0;
        word = 32'b0;
        lmask = byte_mask(head_size, head_addr[1:0]);
        for (int i = 0; i < SQ_ENTRIES; i++) begin
            sq_entry_t e;
            e = sq[SQ_BITS'(sq_head + SQ_BITS'(i))];
            smask = byte_mask(e.size, e.addr[1:0]);
            // Oldest to youngest: a younger overlapping store overrides.
            if ((SQ_BITS+1)'(i) < sq_count && e.addr[31:2] == head_addr[31:2] && (lmask & smask) != 4'b0) begin
                if ((lmask & ~smask) == 4'b0) begin
                    sq_fwd_hit = 1'b1;
                    sq_fwd_block = 1'b0;
                    word = e.data << {e.addr[1:0], 3'b000};
                end else begin
                    sq_fwd_hit = 1'b0;
                    sq_fwd_block = 1'b1;
                end
            end
        end
        shifted = word >> {head_addr[1:0], 3'b000};
        b = shifted[7:0];
        h = shifted[15:0];
        unique case (head_size)
            2'd0: sq_fwd_value = head.ir[14] ? {24'd0, b} : {{24{b[7]}}, b};
            2'd1: sq_fwd_value = head.ir[14] ? {16'd0, h} : {{16{h[15]}}, h};
            default: sq_fwd_value = word;
        endcase
    end

    // ---- memory queue head -------------------------------------------------
    always_comb begin
        head_take = 1'b0;
        if (head_valid && at_state == AT_IDLE && !squash) begin
            if (head.mem_store) begin
                head_take = head_out_free && (head_misaligned || sq_count < SQ_ENTRIES);
            end else if (head.mem_load) begin
                if (head_misaligned)
                    head_take = head_out_free;
                else if (head_mmio)
                    head_take = sq_count == 0 && !ld.valid;
                else if (sq_fwd_hit)
                    head_take = head_out_free;           // forwarded: no cache access
                else
                    head_take = !sq_fwd_block && !ld.valid;
            end else if (head.mem_atomic) begin
                head_take = head_misaligned ? head_out_free :
                            (rob_head == head.tag && sq_count == 0 && sb_empty && !fsm_busy && !ld.valid);
            end
        end
    end

    assign sq_forward_take = head_take && head.mem_load && !head_misaligned && !head_mmio && sq_fwd_hit;

    assign store_buffer_full = sb_full;
    assign drained = sb_empty && !fsm_busy && !ld.valid;
    assign busy = ld.valid || (at_state != AT_IDLE);

    assign storebuf_enqueue_event = commit_store;
    // Forwards from the store buffer (committed stores) or the store queue.
    assign storebuf_forward_event = (load_done && sb_fwd_hit) || sq_forward_take;
    // Store-ordering stalls: a ready load held behind older uncommitted stores,
    // or one waiting on a partially overlapping store in the store buffer.
    assign storebuf_conflict_event = (ld.valid && sb_fwd_conflict) ||
                                     (head_valid && at_state == AT_IDLE && head.mem_load &&
                                      !head_misaligned && !head_take &&
                                      (head_mmio ? (sq_count != 0) : sq_fwd_block));
    assign dcache_hit_event = load_done && dc_cacheable && dc_hit && !sb_fwd_hit;
    assign l2_hit_event = dcache_miss_start && l2_hit;
    assign load_complete_event = load_claims_out;

    always_ff @(posedge clk) begin
        if (rst) begin
            out_q <= '0;
            ld <= '0;
            at_state <= AT_IDLE;
            sq_head <= '0;
            sq_tail <= '0;
            sq_count <= '0;
            reservation_q <= 1'b0;
            reservation_addr_q <= '0;
        end else begin
            // Reservation (architectural: survives flushes).
            if (reservation_set_event) begin
                reservation_q <= 1'b1;
                reservation_addr_q <= atomic_commit_addr[31:2];
            end else if (reservation_clear_event) begin
                reservation_q <= 1'b0;
            end

            if (flush) begin
                out_q <= '0;
                sq_head <= '0;
                sq_tail <= '0;
                sq_count <= '0;
                at_state <= AT_IDLE;
                // A load inside the D-side machinery runs to completion.
                ld.squashed <= ld.valid;
                if (load_done) ld <= '0;
            end else begin
                if (cdb_grant) out_q <= '0;

                // Load completes into the output buffer.
                if (load_done) begin
                    if (ld.squashed) begin
                        ld <= '0;
                    end else if (out_free) begin
                        out_q <= completion(ld.tag, load_result);
                        ld <= '0;
                    end
                end

                // Store queue: commit pops the oldest.
                if (commit_store) begin
                    sq_head <= sq_head + 1'b1;
                end

                // Atomic sequence: read the old word, then write.
                unique case (at_state)
                    AT_READ: begin
                        at_old <= atomic_preview_word;
                        if (!out_q.valid) at_state <= AT_WRITE;
                    end
                    AT_WRITE: begin
                        out_q <= completion(at_tag, (at_op == ATOMIC_SC) ? atomic_sc_result : at_old);
                        at_state <= AT_IDLE;
                    end
                    default: ;
                endcase

                // Memory queue head.
                if (head_take) begin
                    if (head_misaligned) begin
                        // LR reports a load fault; stores, SC, and AMOs a store fault.
                        out_q <= misaligned_fault(head.tag,
                                                  head.mem_load || (head.mem_atomic && head.atomic_op == ATOMIC_LR),
                                                  head_addr);
                    end else if (head.mem_store) begin
                        sq[sq_tail] <= {head.tag, head_addr, head.src2, head_size};   // {tag, addr, data, size}
                        sq_tail <= sq_tail + 1'b1;
                        out_q <= completion(head.tag, 32'b0);
                    end else if (sq_forward_take) begin
                        out_q <= completion(head.tag, sq_fwd_value);
                    end else if (head.mem_load) begin
                        // {valid, squashed, tag, addr, size, is_unsigned}
                        ld <= {1'b1, 1'b0, head.tag, head_addr, head_size, head.ir[14]};
                    end else begin
                        at_tag <= head.tag;
                        at_addr <= head.src1;
                        at_wdata <= head.src2;
                        at_op <= head.atomic_op;
                        at_state <= AT_READ;
                    end
                end

                sq_count <= sq_count + (head_take && head.mem_store && !head_misaligned) - commit_store;

                // Squash (no memory-queue head is taken this cycle). Stores sit
                // in the store queue in program order, so the younger ones are
                // a suffix: keep the older prefix.
                if (squash) begin
                    // A younger result still waiting for a CDB is dropped. One
                    // leaving this cycle has already freed the buffer, which an
                    // older load may have just claimed: leave that alone.
                    if (out_q.valid && !cdb_grant && tag_younger(out_q.tag, squash_tag, rob_head))
                        out_q <= '0;
                    if (load_done && !ld.squashed && out_free && tag_younger(ld.tag, squash_tag, rob_head))
                        out_q <= '0;
                    if (ld.valid && tag_younger(ld.tag, squash_tag, rob_head)) begin
                        if (load_done) ld <= '0;
                        else ld.squashed <= 1'b1;
                    end
                    sq_tail <= sq_head + SQ_BITS'(sq_keep);
                    sq_count <= sq_keep - (SQ_BITS+1)'(commit_store);
                end
            end
        end
    end
endmodule
