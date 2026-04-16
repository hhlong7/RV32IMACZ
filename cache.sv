`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: California Polytechnic University, San Luis Obispo
// Engineer: Long Ho
// Create Date: 02/23/2023 09:39:49 AM
// Module Name: cache
//////////////////////////////////////////////////////////////////////////////////
module Cache(
    input logic [31:0] PC,
    input logic CLK,
    input logic RST,
    input logic update, 
    input logic invalidate, // invalidate the entire cache and prefetch buffer (fence.i)
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
    output logic [31:0] rd,
    output logic [31:0] rd_next,
    output logic hit,
    output logic miss,
    output logic next_valid,
    output logic prefetch_hit_event, 
    output logic prefetch_useless_event
);

    // 2 way set associative cache with LRU replacement and a one block next line buffer
    // for next line prefetching
    parameter int TOTAL_BLOCKS = 16;
    parameter int NUM_WAYS = 2; // 2 way
    parameter int NUM_SETS = TOTAL_BLOCKS / NUM_WAYS; 
    parameter int BLOCK_SIZE = 8;
    localparam int INDEX_SIZE = $clog2(NUM_SETS);
    localparam int WORD_OFFSET_SIZE = 3;
    localparam int BYTE_OFFSET_SIZE = 2;
    localparam int TAG_SIZE = 32 - INDEX_SIZE - WORD_OFFSET_SIZE - BYTE_OFFSET_SIZE;

    // assign default values to outputs to avoid latches
    logic [31:0] data [NUM_WAYS-1:0][NUM_SETS-1:0][BLOCK_SIZE-1:0]; // 2D array of cache lines, each containing 8 words of data
    logic [TAG_SIZE-1:0] tags [NUM_WAYS-1:0][NUM_SETS-1:0]; // 2D array of tags for each cache line
    logic valid_bits [NUM_WAYS-1:0][NUM_SETS-1:0];
    logic lru [NUM_SETS-1:0]; // 0 = way 0 is LRU, 1 = way 1 is LRU

    // Next-line prefetch buffer logics
    logic prefetch_valid; 
    logic [TAG_SIZE-1:0] prefetch_tag;  
    logic [INDEX_SIZE-1:0] prefetch_index;
    logic [31:0] prefetch_data [BLOCK_SIZE-1:0];
    // Tracks whether the current stream-buffer line ever supplied an instruction
    // before it got overwritten by the next prefetch opportunity.
    logic prefetch_used;

    // Decompose the PC into tag, index, and block offset for cache access
    logic [INDEX_SIZE-1:0] index;
    logic [WORD_OFFSET_SIZE-1:0] pc_offset;
    logic [TAG_SIZE-1:0] pc_tag;
    logic [31:0] next_pc;
    logic [INDEX_SIZE-1:0] next_fetch_index;
    logic [WORD_OFFSET_SIZE-1:0] next_fetch_offset;
    logic [TAG_SIZE-1:0] next_fetch_tag;
    logic [31:0] next_block_addr;
    logic [INDEX_SIZE-1:0] next_index;
    logic [TAG_SIZE-1:0] next_tag;

    logic [NUM_WAYS-1:0] way_hit;
    logic [NUM_WAYS-1:0] next_way_hit;
    logic cache_hit;
    logic next_cache_hit;
    logic prefetch_hit; // hit in the prefetch buffer, which is a hit for the current instruction but a miss for the main cache
    logic next_prefetch_hit;
    logic prefetch_only_hit; // hit in the prefetch buffer but not in the main cache, indicating a successful prefetch that avoided a miss on the next instruction
    logic hit_way; // which way hit, valid only if cache_hit is true
    logic next_hit_way; // next sequential word hit way for 2-wide fetch support
    logic replace_way; // which way to replace on a cache miss, valid only if update is true
    logic prefetch_refresh; 

    integer i; // for loops
    integer j;

    
    assign pc_offset = PC[BYTE_OFFSET_SIZE + WORD_OFFSET_SIZE - 1:BYTE_OFFSET_SIZE];
    assign index = PC[BYTE_OFFSET_SIZE + WORD_OFFSET_SIZE + INDEX_SIZE - 1:BYTE_OFFSET_SIZE + WORD_OFFSET_SIZE];
    assign pc_tag = PC[31:BYTE_OFFSET_SIZE + WORD_OFFSET_SIZE + INDEX_SIZE];
    assign next_pc = PC + 32'd4;
    assign next_fetch_offset = next_pc[BYTE_OFFSET_SIZE + WORD_OFFSET_SIZE - 1:BYTE_OFFSET_SIZE];
    assign next_fetch_index = next_pc[BYTE_OFFSET_SIZE + WORD_OFFSET_SIZE + INDEX_SIZE - 1:BYTE_OFFSET_SIZE + WORD_OFFSET_SIZE];
    assign next_fetch_tag = next_pc[31:BYTE_OFFSET_SIZE + WORD_OFFSET_SIZE + INDEX_SIZE];
    assign next_block_addr = {PC[31:5], 5'b0} + 32'd32; // address of the next sequential block, used for next-line prefetching
    assign next_index = next_block_addr[BYTE_OFFSET_SIZE + WORD_OFFSET_SIZE + INDEX_SIZE - 1:BYTE_OFFSET_SIZE + WORD_OFFSET_SIZE];
    assign next_tag = next_block_addr[31:BYTE_OFFSET_SIZE + WORD_OFFSET_SIZE + INDEX_SIZE];

    // Check for hits in both ways and determine which way to replace on a miss
    assign way_hit[0] = valid_bits[0][index] && (tags[0][index] == pc_tag);
    assign way_hit[1] = valid_bits[1][index] && (tags[1][index] == pc_tag);
    assign cache_hit = way_hit[0] | way_hit[1]; // if either way hits, it's a cache hit
    assign hit_way = way_hit[1]; // if way 1 hits, hit_way is 1; if way 0 hits, hit_way is 0
    // The extra lookup is always for PC+4 so IF1 can build a 2-wide fetch
    // packet without adding a second cache instance.
    assign next_way_hit[0] = valid_bits[0][next_fetch_index] && (tags[0][next_fetch_index] == next_fetch_tag);
    assign next_way_hit[1] = valid_bits[1][next_fetch_index] && (tags[1][next_fetch_index] == next_fetch_tag);
    assign next_cache_hit = next_way_hit[0] | next_way_hit[1];
    assign next_hit_way = next_way_hit[1];
    assign replace_way = ~valid_bits[0][index] ? 1'b0 :
                         ~valid_bits[1][index] ? 1'b1 :
                         lru[index]; // replace the invalid way if there is one, otherwise replace the LRU way
    // Check for a hit in the prefetch buffer, which is a hit if the buffer is valid and the tag and index match
    assign prefetch_hit = prefetch_valid &&
                          (prefetch_index == index) &&
                          (prefetch_tag == pc_tag);
    assign next_prefetch_hit = prefetch_valid &&
                               (prefetch_index == next_fetch_index) &&
                               (prefetch_tag == next_fetch_tag);
    assign prefetch_only_hit = prefetch_hit && ~cache_hit;  // if it's a prefetch hit but not a cache hit, 
                                                            // it means the prefetch buffer successfully supplied 
                                                            // the instruction that wasn't in the cache, which is a sign of a useful prefetch.
    // Any real instruction touch refreshes the one-line next-block prefetch buffer.
    assign prefetch_refresh = cache_hit || update || prefetch_only_hit;
    // prefetch buffer hit only counts as a hit if its not also a cache hit
    assign hit = cache_hit || prefetch_hit;
    assign miss = ~hit; 
    assign next_valid = next_cache_hit || next_prefetch_hit;
    assign prefetch_hit_event = prefetch_only_hit;
    // Count a useless prefetch when we are about to replace a valid prefetched line
    // that was never consumed as an instruction fetch.
    assign prefetch_useless_event = prefetch_refresh &&
                                    prefetch_valid &&
                                    ~prefetch_used &&
                                    ~prefetch_hit; // if the prefetched line was actually hit, 
                                                   // then it wasn't useless even if it was used, 
                                                   // so we check ~prefetch_hit to avoid counting useful prefetches as useless.

    // On a cache hit, return the requested word from the cache. 
    // On a miss, rd will be don't care (could be old data from the replaced line or just zero) since the pipeline will treat it as invalid and not use it.
    // On a prefetch buffer hit, return the requested word from the prefetch buffer. 
    // The prefetch buffer is only used for the current instruction and is not promoted to the main cache until the next instruction 
    // causes a refresh (either hit or miss), so it won't cause stale data to be returned on a cache hit.
    always_comb begin
        rd = 32'h0000_0013;
        rd_next = 32'h0000_0013;
        if (cache_hit)
            rd = data[hit_way][index][pc_offset];
        else if (prefetch_hit)
            rd = prefetch_data[pc_offset];

        // rd_next is only meaningful when next_valid is high. It feeds the
        // younger fetch slot in the same cycle as rd.
        if (next_cache_hit)
            rd_next = data[next_hit_way][next_fetch_index][next_fetch_offset];
        else if (next_prefetch_hit)
            rd_next = prefetch_data[next_fetch_offset];
    end

    always_ff @(negedge CLK) begin
        if (RST || invalidate) begin // due to fence.i
            // fence.i invalidates the same structures reset does: both cache ways and
            // the stream buffer contents derived from the old instruction image.
            prefetch_valid <= 1'b0; // invalidate the prefetch buffer
            prefetch_tag <= '0;
            prefetch_index <= '0;
            prefetch_used <= 1'b0;
            // invalidate all cache lines and reset the LRU bis
            for (i = 0; i < NUM_WAYS; i = i + 1) begin
                for (j = 0; j < NUM_SETS; j = j + 1) begin
                    tags[i][j] <= '0;
                    valid_bits[i][j] <= 1'b0;
                    if (i == 0)
                        lru[j] <= 1'b0;
                end
            end
        end else begin
            // on a cache hit, update the lru bit
            if (cache_hit)
                lru[index] <= ~hit_way;
            // on a cache miss, update the cache line with the new data and tag
            if (update) begin
                data[replace_way][index][0] <= w0;
                data[replace_way][index][1] <= w1;
                data[replace_way][index][2] <= w2;
                data[replace_way][index][3] <= w3;
                data[replace_way][index][4] <= w4;
                data[replace_way][index][5] <= w5;
                data[replace_way][index][6] <= w6;
                data[replace_way][index][7] <= w7;
                tags[replace_way][index] <= pc_tag;
                valid_bits[replace_way][index] <= 1'b1;
                lru[index] <= ~replace_way;
            end else if (prefetch_only_hit) begin
                // prefetch hit = the current instruction is in the prefetch buffer but not in icache
                // First use of a prefetched block promotes it into the main cache.
                data[replace_way][index][0] <= prefetch_data[0];
                data[replace_way][index][1] <= prefetch_data[1];
                data[replace_way][index][2] <= prefetch_data[2];
                data[replace_way][index][3] <= prefetch_data[3];
                data[replace_way][index][4] <= prefetch_data[4];
                data[replace_way][index][5] <= prefetch_data[5];
                data[replace_way][index][6] <= prefetch_data[6];
                data[replace_way][index][7] <= prefetch_data[7];
                tags[replace_way][index] <= pc_tag;
                valid_bits[replace_way][index] <= 1'b1;
                lru[index] <= ~replace_way;
            end

            // refresh the prefetch buffer
            if (prefetch_refresh) begin 
                prefetch_valid <= 1'b1;
                prefetch_tag <= next_tag;
                prefetch_index <= next_index;
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
//i love cpe333
