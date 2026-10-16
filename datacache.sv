`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: datacache (L1 data cache)
// Description:
//   Fully associative D-cache (LINES x 32-byte lines). Tags and replacement
//   live in cache_tags. Loads hit combinationally; misses are refilled one
//   word per beat by datacachefsm (from L2 or memory) into the victim line,
//   whose tag is published on the last beat so a partial line never hits.
//   Drained stores update a resident line (no write-allocate); atomics
//   invalidate a resident line because they write memory directly.
//////////////////////////////////////////////////////////////////////////////////
module datacache #(
    parameter int LINES = 16
) (
    input logic clk,
    input logic rst,
    input logic [31:0] loadAddr,
    input logic loadRead,
    input logic [1:0] loadSize,
    input logic loadSign, // 1 = zero-extend, 0 = sign-extend

    input logic drainStoreValid,
    input logic [31:0] drainStoreAddr,
    input logic [31:0] drainStoreData,
    input logic [3:0] drainStoreMask,
    input logic atomicInvalidateValid,
    input logic [31:0] atomicInvalidateAddr,

    input logic enable_write, // asserted once per fill beat
    input logic [2:0] select, // which word inside the line this beat writes
    input logic last,         // final fill beat: publish the tag
    input logic [31:0] word_data,

    output logic loadHit,
    output logic loadMiss,
    output logic loadCacheable,
    output logic [31:0] loadRData
);
    import otter_defs_pkg::*;

    localparam int BLOCK_SIZE = 8;
    localparam int LINE_BITS = $clog2(LINES);
    localparam int PORT_LOAD = 0, PORT_DRAIN = 1, PORT_ATOMIC = 2;

    logic [31:0] data [LINES][BLOCK_SIZE];

    logic [2:0] tag_hit;
    logic [2:0][LINE_BITS-1:0] tag_line;
    logic [LINE_BITS-1:0] victim_line;

    logic drain_store_cacheable, atomic_invalidate_cacheable;
    logic atomic_slot, drain_slot, load_slot;
    logic [31:0] load_word;

    // Drained stores arrive packed (low bytes first); spread them back into
    // the byte lanes selected by the mask.
    function automatic logic [31:0] align_store_word(
        input logic [31:0] raw_data,
        input logic [3:0] byte_mask
    );
        int src;
        align_store_word = 32'b0;
        src = 0;
        for (int lane = 0; lane < 4; lane++) begin
            if (byte_mask[lane]) begin
                align_store_word[lane * 8 +: 8] = raw_data[src * 8 +: 8];
                src++;
            end
        end
    endfunction

    function automatic logic [31:0] merge_store(
        input logic [31:0] old_word,
        input logic [31:0] raw_data,
        input logic [3:0] byte_mask
    );
        logic [31:0] aligned;
        aligned = align_store_word(raw_data, byte_mask);
        merge_store = old_word;
        for (int lane = 0; lane < 4; lane++)
            if (byte_mask[lane])
                merge_store[lane * 8 +: 8] = aligned[lane * 8 +: 8];
    endfunction

    // Internal BRAM-backed data memory is cacheable; MMIO stays uncached.
    assign loadCacheable = (loadAddr < 32'h0001_0000);
    assign drain_store_cacheable = (drainStoreAddr < 32'h0001_0000);
    assign atomic_invalidate_cacheable = (atomicInvalidateAddr < 32'h0001_0000);

    // One update per cycle, in this priority: refill beat, atomic
    // invalidate, drained-store merge, load-hit recency update.
    assign atomic_slot = ~enable_write && atomicInvalidateValid && atomic_invalidate_cacheable;
    assign drain_slot = ~enable_write && ~atomic_slot && drainStoreValid && drain_store_cacheable &&
                        tag_hit[PORT_DRAIN];
    assign load_slot = ~enable_write && ~atomic_slot && ~drain_slot && loadHit;

    cache_tags #(
        .LINES(LINES),
        .TAG_BITS(CACHE_TAG_BITS),
        .LOOKUPS(3),
        .TRUE_LRU(CACHE_TRUE_LRU)
    ) TAGS (
        .clk(clk),
        .rst(rst),
        .lookup_tag({atomicInvalidateAddr[31:5], drainStoreAddr[31:5], loadAddr[31:5]}),
        .lookup_hit(tag_hit),
        .lookup_line(tag_line),
        .victim_line(victim_line),
        .flush(1'b0),
        .fill_en(enable_write && last),
        .fill_tag(loadAddr[31:5]),
        .inval_en(atomic_slot && tag_hit[PORT_ATOMIC]),
        .inval_line(tag_line[PORT_ATOMIC]),
        .touch_en(drain_slot || load_slot),
        .touch_line(drain_slot ? tag_line[PORT_DRAIN] : tag_line[PORT_LOAD])
    );

    assign loadHit = loadRead & loadCacheable & tag_hit[PORT_LOAD];
    assign loadMiss = loadRead & loadCacheable & ~tag_hit[PORT_LOAD];

    assign load_word = data[tag_line[PORT_LOAD]][loadAddr[4:2]];

    always_comb begin
        logic [7:0] loaded_byte;
        logic [15:0] loaded_half;

        loaded_byte = load_word[loadAddr[1:0] * 8 +: 8];
        loaded_half = loadAddr[1] ? load_word[31:16] : load_word[15:0];
        loadRData = 32'b0;

        if (loadHit) begin
            unique case (loadSize)
                2'd0: loadRData = loadSign ? {24'd0, loaded_byte} : {{24{loaded_byte[7]}}, loaded_byte};
                2'd1: loadRData = loadSign ? {16'd0, loaded_half} : {{16{loaded_half[15]}}, loaded_half};
                2'd2: loadRData = load_word;
                default: loadRData = 32'b0;
            endcase
        end
    end

    // The pipeline is stalled during a refill, so loadAddr (and therefore the
    // victim) stays put for every beat.
    always_ff @(negedge clk) begin
        if (enable_write)
            data[victim_line][select] <= word_data;
        else if (drain_slot)
            data[tag_line[PORT_DRAIN]][drainStoreAddr[4:2]] <=
                merge_store(data[tag_line[PORT_DRAIN]][drainStoreAddr[4:2]], drainStoreData, drainStoreMask);
    end
endmodule
