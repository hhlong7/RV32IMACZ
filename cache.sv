`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: California Polytechnic University, San Luis Obispo
// Engineer: Long Ho
// Module Name: Cache (L1 instruction cache)
// Description:
//   Fully associative I-cache (LINES x 32-byte lines) with a one-line
//   next-line prefetch buffer. Tags and replacement live in cache_tags.
//
//   Each cycle it looks up PC and PC+4 (for the two fetch slots). A miss
//   fills a whole line at once from imem (`update`). A hit in the prefetch
//   buffer that misses the cache promotes the buffered line into the cache.
//   Every real access refreshes the prefetch buffer from the prefetch
//   memory, which reads the line after the PC one cycle earlier (it is a
//   synchronous block RAM), so the buffer takes its tag from pw_line, the
//   line actually read, rather than from the current PC.
//////////////////////////////////////////////////////////////////////////////////
module Cache #(
    parameter int LINES = 16
) (
    input logic [31:0] PC,
    input logic CLK,
    input logic RST,
    input logic update,
    input logic invalidate, // fence.i: drop every line and the prefetch buffer
    input logic [31:0] w0,
    input logic [31:0] w1,
    input logic [31:0] w2,
    input logic [31:0] w3,
    input logic [31:0] w4,
    input logic [31:0] w5,
    input logic [31:0] w6,
    input logic [31:0] w7,
    input logic [31:0] pw0,
    input logic [31:0] pw1,
    input logic [31:0] pw2,
    input logic [31:0] pw3,
    input logic [31:0] pw4,
    input logic [31:0] pw5,
    input logic [31:0] pw6,
    input logic [31:0] pw7,
    input logic [otter_defs_pkg::CACHE_TAG_BITS-1:0] pw_line,  // line address of pw0..pw7
    output logic [31:0] rd,
    output logic [31:0] rd_next,
    output logic hit,
    output logic miss,
    output logic next_valid,
    output logic prefetch_hit_event,
    output logic prefetch_useless_event
);
    import otter_defs_pkg::*;

    localparam int BLOCK_SIZE = 8;
    localparam int LINE_BITS = $clog2(LINES);
    localparam logic [31:0] NOP = 32'h0000_0013;

    logic [31:0] data [LINES][BLOCK_SIZE];

    // Next-line prefetch buffer.
    logic prefetch_valid;
    logic [CACHE_TAG_BITS-1:0] prefetch_tag;
    logic [31:0] prefetch_data [BLOCK_SIZE];
    // Whether the buffered line supplied an instruction before being replaced.
    logic prefetch_used;

    logic [31:0] next_pc;
    logic [CACHE_TAG_BITS-1:0] pc_tag, next_fetch_tag;
    logic [2:0] pc_offset, next_fetch_offset;

    logic [1:0] tag_hit;
    logic [1:0][LINE_BITS-1:0] tag_line;
    logic [LINE_BITS-1:0] victim_line;

    logic cache_hit, next_cache_hit;
    logic prefetch_hit, next_prefetch_hit, prefetch_only_hit;
    logic prefetch_refresh;
    logic fill;

    assign next_pc = PC + 32'd4;
    assign pc_tag = PC[31:5];
    assign pc_offset = PC[4:2];
    assign next_fetch_tag = next_pc[31:5];
    assign next_fetch_offset = next_pc[4:2];

    // Port 0 looks up PC; port 1 looks up PC+4 for the younger fetch slot.
    cache_tags #(
        .LINES(LINES),
        .TAG_BITS(CACHE_TAG_BITS),
        .LOOKUPS(2),
        .TRUE_LRU(CACHE_TRUE_LRU)
    ) TAGS (
        .clk(CLK),
        .rst(RST),
        .lookup_tag({next_fetch_tag, pc_tag}),
        .lookup_hit(tag_hit),
        .lookup_line(tag_line),
        .victim_line(victim_line),
        .flush(invalidate),
        .fill_en(fill),
        .fill_tag(pc_tag),
        .inval_en(1'b0),
        .inval_line('0),
        .touch_en(cache_hit),
        .touch_line(tag_line[0])
    );

    assign cache_hit = tag_hit[0];
    assign next_cache_hit = tag_hit[1];
    assign prefetch_hit = prefetch_valid && (prefetch_tag == pc_tag);
    assign next_prefetch_hit = prefetch_valid && (prefetch_tag == next_fetch_tag);
    // The prefetch buffer supplied an instruction the cache did not have.
    assign prefetch_only_hit = prefetch_hit && ~cache_hit;
    // A miss refill or a prefetch promotion installs a line.
    assign fill = update || prefetch_only_hit;
    // Any real instruction touch refreshes the next-line prefetch buffer.
    assign prefetch_refresh = cache_hit || update || prefetch_only_hit;

    assign hit = cache_hit || prefetch_hit;
    assign miss = ~hit;
    assign next_valid = next_cache_hit || next_prefetch_hit;
    assign prefetch_hit_event = prefetch_only_hit;
    // A prefetched line replaced without ever supplying an instruction.
    assign prefetch_useless_event = prefetch_refresh && prefetch_valid && ~prefetch_used && ~prefetch_hit;

    // rd/rd_next are only meaningful when hit/next_valid are high.
    always_comb begin
        rd = NOP;
        rd_next = NOP;
        if (cache_hit)
            rd = data[tag_line[0]][pc_offset];
        else if (prefetch_hit)
            rd = prefetch_data[pc_offset];

        if (next_cache_hit)
            rd_next = data[tag_line[1]][next_fetch_offset];
        else if (next_prefetch_hit)
            rd_next = prefetch_data[next_fetch_offset];
    end

    always_ff @(posedge CLK) begin
        if (RST || invalidate) begin
            prefetch_valid <= 1'b0;
            prefetch_tag <= '0;
            prefetch_used <= 1'b0;
        end else begin
            if (update) begin
                data[victim_line][0] <= w0;
                data[victim_line][1] <= w1;
                data[victim_line][2] <= w2;
                data[victim_line][3] <= w3;
                data[victim_line][4] <= w4;
                data[victim_line][5] <= w5;
                data[victim_line][6] <= w6;
                data[victim_line][7] <= w7;
            end else if (prefetch_only_hit) begin
                for (int w = 0; w < BLOCK_SIZE; w++)
                    data[victim_line][w] <= prefetch_data[w];
            end

            if (prefetch_refresh) begin
                prefetch_valid <= 1'b1;
                prefetch_tag <= pw_line;
                prefetch_used <= 1'b0;
                prefetch_data[0] <= pw0;
                prefetch_data[1] <= pw1;
                prefetch_data[2] <= pw2;
                prefetch_data[3] <= pw3;
                prefetch_data[4] <= pw4;
                prefetch_data[5] <= pw5;
                prefetch_data[6] <= pw6;
                prefetch_data[7] <= pw7;
            end else if (prefetch_only_hit) begin
                prefetch_used <= 1'b1;
            end
        end
    end
endmodule
