`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: ReorderBuffer
// Description:
//   Circular reorder buffer. Dispatch allocates up to two entries per cycle at
//   the tail (the entry index is the instruction's rename tag), the two
//   common data buses mark entries done, and commit retires up to two per
//   cycle from the head in program order. A flush empties it; a squash (a
//   mispredicted branch resolving) drops every entry younger than the branch.
//
//   Storage is split by who writes it:
//     entries      valid, done, and the completion fields the CDBs write
//                  (flip-flops: three CDB write ports plus allocation)
//     bank_even/   everything else (PC, instruction, destination, flags,
//     bank_odd     CSR operand, history), written only at allocation
//   Allocation writes tail and tail+1, which always have opposite parity, so
//   each bank needs one write port, and commit reads head and head+1, one
//   from each bank. The banks map onto LUT RAM instead of about 180
//   flip-flops per entry with their write multiplexers and read trees.
//
//   The completion fields are also narrowed, because every bit has a
//   six-way write multiplexer: cause keeps 4 bits (synchronous exception
//   codes are below 16; interrupts never pass through the ROB), and tval and
//   next_pc share one field, since only exceptions use tval and only the
//   branch unit, which never raises one, sets next_pc.
//////////////////////////////////////////////////////////////////////////////////
module ReorderBuffer
    import ooo_pkg::*;
(
    input  logic clk,
    input  logic rst,
    input  logic flush,
    input  logic squash,                  // drop entries younger than squash_tag
    input  tag_t squash_tag,

    // Dispatch (never in a squash cycle): entry 1 is only allocated together with entry 0.
    input  logic       alloc0_en,
    input  rob_entry_t alloc0,
    input  logic       alloc1_en,
    input  rob_entry_t alloc1,
    output tag_t       alloc0_tag,
    output tag_t       alloc1_tag,
    output logic [4:0] free_count,
    output logic [4:0] count,

    // Completion.
    input  cdb_t cdb0,
    input  cdb_t cdb1,
    input  cdb_t cdb2,

    // Operand lookup for dispatch.
    output logic [ROB_SIZE-1:0] done_vec,
    output logic [ROB_SIZE-1:0][31:0] value_vec,

    // Commit.
    output tag_t       head_tag,
    output rob_entry_t head0,
    output rob_entry_t head1,
    input  logic [1:0] commit_count
);
    localparam int HALF = ROB_SIZE / 2;
    localparam int HALF_BITS = $clog2(HALF);

    // Fields the CDBs (or allocation) write.
    typedef struct packed {
        logic valid;
        logic done;
        logic [31:0] value;
        logic exception;
        logic [3:0] cause;
        logic [31:0] aux;               // tval if exception, else next_pc
        logic mispredict;
        logic taken;
        logic [4:0] fp_flags;
    } rob_dyn_t;

    // Fields written only at allocation.
    typedef struct packed {
        logic [31:0] pc;
        logic [31:0] pc_next;
        logic [31:0] ir;
        logic [31:0] raw_ir;
        logic wr_int;
        logic wr_fp;
        logic [4:0] rd;
        logic fp_arith;
        logic is_store;
        logic is_control;
        logic serial;
        logic sys_csr;
        logic sys_mret;
        logic sys_fence;
        logic sys_fence_i;
        logic [31:0] csr_src;
        logic [otter_defs_pkg::GHR_BITS-1:0] ghr;
    } rob_static_t;

    function automatic rob_dyn_t dyn_of(input rob_entry_t e);
        dyn_of.valid = e.valid;
        dyn_of.done = e.done;
        dyn_of.value = e.value;
        dyn_of.exception = e.exception;
        dyn_of.cause = e.cause[3:0];
        dyn_of.aux = e.exception ? e.tval : e.next_pc;
        dyn_of.mispredict = e.mispredict;
        dyn_of.taken = e.taken;
        dyn_of.fp_flags = e.fp_flags;
    endfunction

    function automatic rob_static_t static_of(input rob_entry_t e);
        static_of.pc = e.pc;
        static_of.pc_next = e.pc_next;
        static_of.ir = e.ir;
        static_of.raw_ir = e.raw_ir;
        static_of.wr_int = e.wr_int;
        static_of.wr_fp = e.wr_fp;
        static_of.rd = e.rd;
        static_of.fp_arith = e.fp_arith;
        static_of.is_store = e.is_store;
        static_of.is_control = e.is_control;
        static_of.serial = e.serial;
        static_of.sys_csr = e.sys_csr;
        static_of.sys_mret = e.sys_mret;
        static_of.sys_fence = e.sys_fence;
        static_of.sys_fence_i = e.sys_fence_i;
        static_of.csr_src = e.csr_src;
        static_of.ghr = e.ghr;
    endfunction

    function automatic rob_entry_t join_entry(input rob_dyn_t d, input rob_static_t s);
        join_entry = '0;
        join_entry.valid = d.valid;
        join_entry.done = d.done;
        join_entry.value = d.value;
        join_entry.exception = d.exception;
        join_entry.cause = 32'(d.cause);
        join_entry.tval = d.aux;
        join_entry.mispredict = d.mispredict;
        join_entry.taken = d.taken;
        join_entry.next_pc = d.aux;
        join_entry.fp_flags = d.fp_flags;
        join_entry.pc = s.pc;
        join_entry.pc_next = s.pc_next;
        join_entry.ir = s.ir;
        join_entry.raw_ir = s.raw_ir;
        join_entry.wr_int = s.wr_int;
        join_entry.wr_fp = s.wr_fp;
        join_entry.rd = s.rd;
        join_entry.fp_arith = s.fp_arith;
        join_entry.is_store = s.is_store;
        join_entry.is_control = s.is_control;
        join_entry.serial = s.serial;
        join_entry.sys_csr = s.sys_csr;
        join_entry.sys_mret = s.sys_mret;
        join_entry.sys_fence = s.sys_fence;
        join_entry.sys_fence_i = s.sys_fence_i;
        join_entry.csr_src = s.csr_src;
        join_entry.ghr = s.ghr;
    endfunction

    // Packed array: Icarus 13 cannot select fields from unpacked arrays of structs.
    rob_dyn_t [ROB_SIZE-1:0] entries;
    logic [$bits(rob_static_t)-1:0] bank_even [HALF];
    logic [$bits(rob_static_t)-1:0] bank_odd [HALF];
    tag_t head, tail;
    logic [4:0] used;

    // The banks hold no state that matters until allocated (valid lives in
    // entries); zero them so simulation never reads X from an unused slot.
    initial begin
        for (int i = 0; i < HALF; i++) begin
            bank_even[i] = '0;
            bank_odd[i] = '0;
        end
    end

    tag_t tail1, head1_tag;
    assign tail1 = tag_t'(tail + 1'b1);
    assign head1_tag = tag_t'(head + 1'b1);

    assign alloc0_tag = tail;
    assign alloc1_tag = tail1;
    assign count = used;
    assign free_count = 5'(ROB_SIZE) - used;
    assign head_tag = head;

    // ---- allocation-only fields ---------------------------------------------
    // Entry t lives in bank t[0] at row t >> 1.
    logic we_even, we_odd;
    logic [HALF_BITS-1:0] wa_even, wa_odd;
    logic [$bits(rob_static_t)-1:0] wd_even, wd_odd;

    always @* begin
        if (!tail[0]) begin                  // alloc0 -> even, alloc1 -> odd
            we_even = alloc0_en;
            wa_even = HALF_BITS'(tail >> 1);
            wd_even = static_of(alloc0);
            we_odd = alloc1_en;
            wa_odd = HALF_BITS'(tail1 >> 1);
            wd_odd = static_of(alloc1);
        end else begin                       // alloc0 -> odd, alloc1 -> even
            we_odd = alloc0_en;
            wa_odd = HALF_BITS'(tail >> 1);
            wd_odd = static_of(alloc0);
            we_even = alloc1_en;
            wa_even = HALF_BITS'(tail1 >> 1);
            wd_even = static_of(alloc1);
        end
    end

    always_ff @(posedge clk) begin
        if (we_even) bank_even[wa_even] <= wd_even;
        if (we_odd) bank_odd[wa_odd] <= wd_odd;
    end

    logic [$bits(rob_static_t)-1:0] s_head0, s_head1;
    assign s_head0 = head[0] ? bank_odd[HALF_BITS'(head >> 1)] : bank_even[HALF_BITS'(head >> 1)];
    assign s_head1 = head1_tag[0] ? bank_odd[HALF_BITS'(head1_tag >> 1)] : bank_even[HALF_BITS'(head1_tag >> 1)];

    always @* head0 = join_entry(entries[head], s_head0);
    always @* head1 = join_entry(entries[head1_tag], s_head1);

    // Simulation and testbench view of one whole entry.
    function automatic rob_entry_t entry(input tag_t t);
        entry = join_entry(entries[t], t[0] ? bank_odd[HALF_BITS'(t >> 1)] : bank_even[HALF_BITS'(t >> 1)]);
    endfunction

    always_comb begin
        for (int i = 0; i < ROB_SIZE; i++) begin
            done_vec[i] = entries[i].valid && entries[i].done;
            value_vec[i] = entries[i].value;
        end
    end

    // The narrowed fields rely on these; any new exception source must keep them.
    // synthesis translate_off
    always @(posedge clk) begin
        if (!rst) begin
            if ((cdb0.valid && cdb0.exception && cdb0.cause >= 32'd16) ||
                (cdb1.valid && cdb1.exception && cdb1.cause >= 32'd16) ||
                (cdb2.valid && cdb2.exception && cdb2.cause >= 32'd16) ||
                (alloc0_en && alloc0.exception && alloc0.cause >= 32'd16) ||
                (alloc1_en && alloc1.exception && alloc1.cause >= 32'd16))
                $fatal(1, "ROB: exception cause does not fit in 4 bits");
            if ((cdb0.valid && cdb0.exception && cdb0.next_pc != 32'b0) ||
                (cdb1.valid && cdb1.exception && cdb1.next_pc != 32'b0) ||
                (cdb2.valid && cdb2.exception && cdb2.next_pc != 32'b0))
                $fatal(1, "ROB: a completion carries both an exception and a next PC");
        end
    end
    // synthesis translate_on

    // ---- completion state ---------------------------------------------------
    // Apply one completion to an entry (whole-element update keeps Icarus
    // away from partial writes into an array of structs).
    function automatic rob_dyn_t complete(input rob_dyn_t e, input cdb_t c);
        complete = e;
        complete.done = 1'b1;
        complete.value = c.value;
        complete.exception = c.exception;
        complete.cause = c.cause[3:0];
        complete.aux = c.exception ? c.tval : c.next_pc;
        complete.mispredict = c.mispredict;
        complete.taken = c.taken;
        complete.fp_flags = c.fp_flags;
    endfunction

    rob_dyn_t new0, new1;
    always @* new0 = dyn_of(alloc0);
    always @* new1 = dyn_of(alloc1);

    always_ff @(posedge clk) begin
        if (rst || flush) begin
            head <= '0;
            tail <= '0;
            used <= '0;
            for (int i = 0; i < ROB_SIZE; i++)
                entries[i] <= '0;
        end else begin
            for (int i = 0; i < ROB_SIZE; i++) begin
                rob_dyn_t e;
                e = entries[i];
                if (cdb0.valid && cdb0.tag == tag_t'(i) && e.valid)
                    e = complete(e, cdb0);
                if (cdb1.valid && cdb1.tag == tag_t'(i) && e.valid)
                    e = complete(e, cdb1);
                if (cdb2.valid && cdb2.tag == tag_t'(i) && e.valid)
                    e = complete(e, cdb2);
                // Retire.
                if ((commit_count >= 2'd1 && tag_t'(i) == head) ||
                    (commit_count == 2'd2 && tag_t'(i) == head1_tag))
                    e.valid = 1'b0;
                // Allocate.
                if (alloc0_en && tag_t'(i) == tail) begin
                    e = new0;
                    e.valid = 1'b1;
                end
                if (alloc1_en && tag_t'(i) == tail1) begin
                    e = new1;
                    e.valid = 1'b1;
                end
                if (squash && tag_younger(tag_t'(i), squash_tag, head))
                    e.valid = 1'b0;
                entries[i] <= e;
            end

            head <= head + tag_t'(commit_count);
            if (squash) begin
                tail <= squash_tag + 1'b1;
                used <= 5'(tag_age(squash_tag, head)) + 5'd1 - 5'(commit_count);
            end else begin
                tail <= tail + tag_t'(alloc0_en) + tag_t'(alloc1_en);
                used <= used + 5'(alloc0_en) + 5'(alloc1_en) - 5'(commit_count);
            end
        end
    end
endmodule
