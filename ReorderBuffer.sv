`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: ReorderBuffer
// Description:
//   Circular reorder buffer. Dispatch allocates up to two entries per cycle at
//   the tail (the entry index is the instruction's rename tag), the two
//   common data buses mark entries done, and commit retires up to two per
//   cycle from the head in program order. A flush empties it; a squash (a
//   mispredicted branch resolving) drops every entry younger than the branch.
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
    // Packed array: Icarus 13 cannot select fields from unpacked arrays of structs.
    rob_entry_t [ROB_SIZE-1:0] entries;
    tag_t head, tail;
    logic [4:0] used;

    assign alloc0_tag = tail;
    assign alloc1_tag = tail + 1'b1;
    assign count = used;
    assign free_count = 5'(ROB_SIZE) - used;
    assign head_tag = head;
    assign head0 = entries[head];
    assign head1 = entries[tag_t'(head + 1'b1)];

    always_comb begin
        for (int i = 0; i < ROB_SIZE; i++) begin
            done_vec[i] = entries[i].valid && entries[i].done;
            value_vec[i] = entries[i].value;
        end
    end

    // Apply one completion to an entry (whole-element update keeps Icarus
    // away from partial writes into an array of structs).
    function automatic rob_entry_t complete(input rob_entry_t e, input cdb_t c);
        complete = e;
        complete.done = 1'b1;
        complete.value = c.value;
        complete.exception = c.exception;
        complete.cause = c.cause;
        complete.tval = c.tval;
        complete.mispredict = c.mispredict;
        complete.taken = c.taken;
        complete.next_pc = c.next_pc;
        complete.fp_flags = c.fp_flags;
    endfunction

    always_ff @(posedge clk) begin
        if (rst || flush) begin
            head <= '0;
            tail <= '0;
            used <= '0;
            for (int i = 0; i < ROB_SIZE; i++)
                entries[i] <= '0;
        end else begin
            for (int i = 0; i < ROB_SIZE; i++) begin
                rob_entry_t e;
                e = entries[i];
                if (cdb0.valid && cdb0.tag == tag_t'(i) && e.valid)
                    e = complete(e, cdb0);
                if (cdb1.valid && cdb1.tag == tag_t'(i) && e.valid)
                    e = complete(e, cdb1);
                if (cdb2.valid && cdb2.tag == tag_t'(i) && e.valid)
                    e = complete(e, cdb2);
                // Retire.
                if ((commit_count >= 2'd1 && tag_t'(i) == head) ||
                    (commit_count == 2'd2 && tag_t'(i) == tag_t'(head + 1'b1)))
                    e.valid = 1'b0;
                // Allocate.
                if (alloc0_en && tag_t'(i) == tail) begin
                    e = alloc0;
                    e.valid = 1'b1;
                end
                if (alloc1_en && tag_t'(i) == tag_t'(tail + 1'b1)) begin
                    e = alloc1;
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
