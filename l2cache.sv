`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: l2cache
// Description:
//   Fully associative L2 (LINES x 32-byte lines) behind the L1 D-cache.
//   Tags and replacement live in cache_tags. It serves whole-line refills to
//   L1 one word per beat, captures lines refilled from memory, keeps resident
//   lines current with drained stores, and drops lines an atomic overwrites.
//////////////////////////////////////////////////////////////////////////////////
module l2cache #(
    parameter int LINES = 32
) (
    input logic clk,
    input logic rst,

    input logic [31:0] queryAddr,
    input logic queryValid,

    input logic [31:0] lineReadAddr,
    input logic [2:0] lineReadSelect,

    input logic [31:0] fillAddr,
    input logic fillWrite,
    input logic [2:0] fillSelect,
    input logic fillLast,
    input logic [31:0] fillWordData,

    input logic drainStoreValid,
    input logic [31:0] drainStoreAddr,
    input logic [31:0] drainStoreData,
    input logic [3:0] drainStoreMask,
    input logic atomicInvalidateValid,
    input logic [31:0] atomicInvalidateAddr,

    output logic queryHit,
    output logic queryMiss,
    output logic queryCacheable,
    output logic [31:0] lineReadData
);
    import otter_defs_pkg::*;

    localparam int BLOCK_SIZE = 8;
    localparam int LINE_BITS = $clog2(LINES);
    localparam int PORT_QUERY = 0, PORT_LINE_READ = 1, PORT_DRAIN = 2, PORT_ATOMIC = 3;

    logic [31:0] data [LINES][BLOCK_SIZE];

    logic [3:0] tag_hit;
    logic [3:0][LINE_BITS-1:0] tag_line;
    logic [LINE_BITS-1:0] victim_line;

    logic drain_store_cacheable, atomic_invalidate_cacheable;
    logic atomic_slot, drain_slot, query_slot;

    function automatic logic [31:0] merge_store(
        input logic [31:0] old_word,
        input logic [31:0] raw_data,
        input logic [3:0] byte_mask
    );
        int src;
        merge_store = old_word;
        src = 0;
        // Drained stores arrive packed (low bytes first).
        for (int lane = 0; lane < 4; lane++) begin
            if (byte_mask[lane]) begin
                merge_store[lane * 8 +: 8] = raw_data[src * 8 +: 8];
                src++;
            end
        end
    endfunction

    assign queryCacheable = (queryAddr < 32'h0001_0000);
    assign drain_store_cacheable = (drainStoreAddr < 32'h0001_0000);
    assign atomic_invalidate_cacheable = (atomicInvalidateAddr < 32'h0001_0000);

    assign queryHit = queryValid && queryCacheable && tag_hit[PORT_QUERY];
    assign queryMiss = queryValid && queryCacheable && ~tag_hit[PORT_QUERY];

    // One update per cycle, in this priority: fill beat, atomic invalidate,
    // drained-store merge, query-hit recency update.
    assign atomic_slot = ~fillWrite && atomicInvalidateValid && atomic_invalidate_cacheable;
    assign drain_slot = ~fillWrite && ~atomic_slot && drainStoreValid && drain_store_cacheable &&
                        tag_hit[PORT_DRAIN];
    assign query_slot = ~fillWrite && ~atomic_slot && ~drain_slot && queryHit;

    cache_tags #(
        .LINES(LINES),
        .TAG_BITS(CACHE_TAG_BITS),
        .LOOKUPS(4),
        .TRUE_LRU(CACHE_TRUE_LRU)
    ) TAGS (
        .clk(clk),
        .rst(rst),
        .lookup_tag({atomicInvalidateAddr[31:5], drainStoreAddr[31:5], lineReadAddr[31:5], queryAddr[31:5]}),
        .lookup_hit(tag_hit),
        .lookup_line(tag_line),
        .victim_line(victim_line),
        .flush(1'b0),
        .fill_en(fillWrite && fillLast),
        .fill_tag(fillAddr[31:5]),
        .inval_en(atomic_slot && tag_hit[PORT_ATOMIC]),
        .inval_line(tag_line[PORT_ATOMIC]),
        .touch_en(drain_slot || query_slot),
        .touch_line(drain_slot ? tag_line[PORT_DRAIN] : tag_line[PORT_QUERY])
    );

    // Refills from L2 stream the hit line out one word per beat.
    assign lineReadData = tag_hit[PORT_LINE_READ] ? data[tag_line[PORT_LINE_READ]][lineReadSelect] : 32'b0;

    // The refill address is stable for all beats, so the victim is too.
    always_ff @(posedge clk) begin
        if (fillWrite)
            data[victim_line][fillSelect] <= fillWordData;
        else if (drain_slot)
            data[tag_line[PORT_DRAIN]][drainStoreAddr[4:2]] <=
                merge_store(data[tag_line[PORT_DRAIN]][drainStoreAddr[4:2]], drainStoreData, drainStoreMask);
    end
endmodule
