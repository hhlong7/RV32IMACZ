`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer: Long Ho
// Create Date: 03/27/2026
// Module Name: StoreBuffer
// Description:
//   Multi-entry FIFO store buffer with youngest-first forwarding search.
//   Loads may forward only from a single fully-covering older store. If the
//   youngest overlapping store covers only part of the requested bytes, the
//   load must stall until the ambiguity drains away.
//////////////////////////////////////////////////////////////////////////////////
module StoreBuffer #(
    parameter int DEPTH = 4
)(
    input logic clk,
    input logic rst,

    input logic enqueue_valid,
    input logic [31:0] enqueue_addr,
    input logic [31:0] enqueue_data,
    input logic [3:0] enqueue_mask,

    input logic drain_accept,

    input logic query_valid,
    input logic [31:0] query_addr,
    input logic [3:0] query_mask,

    output logic full,
    output logic empty,
    output logic [$clog2(DEPTH + 1) - 1:0] occupancy,

    output logic drain_valid,
    output logic [31:0] drain_addr,
    output logic [31:0] drain_data,
    output logic [3:0] drain_mask,

    output logic forward_hit,
    output logic forward_conflict,
    output logic [31:0] forward_data_word
);
    localparam int PTR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1;

    logic [31:0] addr_q [0:DEPTH-1];
    logic [31:0] data_q [0:DEPTH-1];
    logic [3:0] mask_q [0:DEPTH-1];

    logic [PTR_W-1:0] head_q;
    logic [PTR_W-1:0] tail_q;
    logic [$clog2(DEPTH + 1) - 1:0] count_q;

    function automatic [31:0] align_store_word(
        input logic [31:0] raw_data,
        input logic [3:0] byte_mask
    );
        logic [31:0] aligned;
        integer lane;
        integer src_idx;
        begin
            aligned = 32'b0;
            src_idx = 0;

            for (lane = 0; lane < 4; lane = lane + 1) begin
                if (byte_mask[lane]) begin
                    aligned[(lane * 8) +: 8] = raw_data[(src_idx * 8) +: 8];
                    src_idx = src_idx + 1;
                end
            end

            align_store_word = aligned;
        end
    endfunction

    function automatic int phys_index_from_head(
        input int logical_index,
        input logic [PTR_W-1:0] head_ptr
    );
        int idx;
        begin
            idx = head_ptr + logical_index;
            if (idx >= DEPTH)
                idx = idx - DEPTH;
            phys_index_from_head = idx;
        end
    endfunction

    assign full = (count_q == DEPTH);
    assign empty = (count_q == 0);
    assign occupancy = count_q;

    assign drain_valid = ~empty;
    assign drain_addr = addr_q[head_q];
    assign drain_data = data_q[head_q];
    assign drain_mask = mask_q[head_q];

    always_ff @(posedge clk) begin
        logic do_enqueue;
        logic do_dequeue;
        logic [PTR_W-1:0] next_head;
        logic [PTR_W-1:0] next_tail;

        do_enqueue = enqueue_valid && ~full;
        do_dequeue = drain_accept && ~empty;

        next_head = head_q;
        next_tail = tail_q;

        if (rst) begin
            head_q <= '0;
            tail_q <= '0;
            count_q <= '0;
        end else begin
            if (do_enqueue) begin
                addr_q[tail_q] <= enqueue_addr;
                data_q[tail_q] <= enqueue_data;
                mask_q[tail_q] <= enqueue_mask;

                if (tail_q == DEPTH - 1)
                    next_tail = '0;
                else
                    next_tail = tail_q + PTR_W'(1);
            end

            if (do_dequeue) begin
                if (head_q == DEPTH - 1)
                    next_head = '0;
                else
                    next_head = head_q + PTR_W'(1);
            end

            head_q <= next_head;
            tail_q <= next_tail;

            unique case ({do_enqueue, do_dequeue})
                2'b10: count_q <= count_q + 1'b1;
                2'b01: count_q <= count_q - 1'b1;
                default: count_q <= count_q;
            endcase
        end
    end

    always_comb begin
        int entry_idx;
        int age;
        int scan;
        logic [31:0] aligned_entry_data;
        logic same_word;
        logic [3:0] overlap_mask;

        forward_hit = 1'b0;
        forward_conflict = 1'b0;
        forward_data_word = 32'b0;

        if (query_valid) begin
            for (scan = 0; scan < DEPTH; scan = scan + 1) begin
                if ((scan < count_q) && ~forward_hit && ~forward_conflict) begin
                    age = count_q - 1 - scan;
                    entry_idx = phys_index_from_head(age, head_q);
                    same_word = (addr_q[entry_idx][31:2] == query_addr[31:2]);
                    overlap_mask = query_mask & mask_q[entry_idx];

                    if (same_word && (overlap_mask != 4'b0000)) begin
                        if ((query_mask & ~mask_q[entry_idx]) == 4'b0000) begin
                            aligned_entry_data = align_store_word(data_q[entry_idx], mask_q[entry_idx]);
                            forward_hit = 1'b1;
                            forward_data_word = aligned_entry_data;
                        end else begin
                            forward_conflict = 1'b1;
                        end
                    end
                end
            end
        end
    end
endmodule
// i love cpe333
