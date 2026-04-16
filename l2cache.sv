module l2cache(
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
    parameter int TOTAL_BLOCKS = 32;
    parameter int NUM_WAYS = 2;
    parameter int NUM_SETS = TOTAL_BLOCKS / NUM_WAYS;
    parameter int BLOCK_SIZE = 8;
    localparam int INDEX_SIZE = $clog2(NUM_SETS);
    localparam int OFFSET_SIZE = 3;
    localparam int BYTE_OFFSET_SIZE = 2;
    localparam int TAG_SIZE = 32 - INDEX_SIZE - OFFSET_SIZE - BYTE_OFFSET_SIZE;

    logic [31:0] cache [NUM_WAYS-1:0][NUM_SETS-1:0][BLOCK_SIZE-1:0];
    logic [TAG_SIZE-1:0] tags [NUM_WAYS-1:0][NUM_SETS-1:0];
    logic valid [NUM_WAYS-1:0][NUM_SETS-1:0];
    logic lru [NUM_SETS-1:0];

    logic [INDEX_SIZE-1:0] query_index;
    logic [TAG_SIZE-1:0] query_tag;
    logic [NUM_WAYS-1:0] query_way_hit;
    logic query_cache_hit;
    logic query_hit_way;

    logic [INDEX_SIZE-1:0] line_read_index;
    logic [TAG_SIZE-1:0] line_read_tag;
    logic [NUM_WAYS-1:0] line_read_way_hit;
    logic line_read_cache_hit;
    logic line_read_hit_way;

    logic [INDEX_SIZE-1:0] fill_index;
    logic [TAG_SIZE-1:0] fill_tag;
    logic fill_replace_way;

    logic drain_store_cacheable;
    logic [INDEX_SIZE-1:0] drain_index;
    logic [OFFSET_SIZE-1:0] drain_offset;
    logic [TAG_SIZE-1:0] drain_tag;
    logic [NUM_WAYS-1:0] drain_way_hit;
    logic drain_cache_hit;
    logic drain_hit_way;

    logic atomic_invalidate_cacheable;
    logic [INDEX_SIZE-1:0] atomic_invalidate_index;
    logic [TAG_SIZE-1:0] atomic_invalidate_tag;

    integer i;
    integer j;

    // Drained stores arrive in a packed form from the store buffer, so rebuild
    // the bytes into their addressed lane positions before merging into a line.
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

    // L2 is indexed/tagged exactly like L1, but only serves whole-line refill
    // traffic and opportunistic write updates from drained stores.
    assign query_index = queryAddr[BYTE_OFFSET_SIZE + OFFSET_SIZE + INDEX_SIZE - 1:BYTE_OFFSET_SIZE + OFFSET_SIZE];
    assign query_tag = queryAddr[31:BYTE_OFFSET_SIZE + OFFSET_SIZE + INDEX_SIZE];
    assign line_read_index = lineReadAddr[BYTE_OFFSET_SIZE + OFFSET_SIZE + INDEX_SIZE - 1:BYTE_OFFSET_SIZE + OFFSET_SIZE];
    assign line_read_tag = lineReadAddr[31:BYTE_OFFSET_SIZE + OFFSET_SIZE + INDEX_SIZE];
    assign fill_index = fillAddr[BYTE_OFFSET_SIZE + OFFSET_SIZE + INDEX_SIZE - 1:BYTE_OFFSET_SIZE + OFFSET_SIZE];
    assign fill_tag = fillAddr[31:BYTE_OFFSET_SIZE + OFFSET_SIZE + INDEX_SIZE];
    assign drain_index = drainStoreAddr[BYTE_OFFSET_SIZE + OFFSET_SIZE + INDEX_SIZE - 1:BYTE_OFFSET_SIZE + OFFSET_SIZE];
    assign drain_offset = drainStoreAddr[BYTE_OFFSET_SIZE + OFFSET_SIZE - 1:BYTE_OFFSET_SIZE];
    assign drain_tag = drainStoreAddr[31:BYTE_OFFSET_SIZE + OFFSET_SIZE + INDEX_SIZE];
    assign atomic_invalidate_index = atomicInvalidateAddr[BYTE_OFFSET_SIZE + OFFSET_SIZE + INDEX_SIZE - 1:BYTE_OFFSET_SIZE + OFFSET_SIZE];
    assign atomic_invalidate_tag = atomicInvalidateAddr[31:BYTE_OFFSET_SIZE + OFFSET_SIZE + INDEX_SIZE];

    assign queryCacheable = (queryAddr < 32'h0001_0000);
    assign drain_store_cacheable = (drainStoreAddr < 32'h0001_0000);
    assign atomic_invalidate_cacheable = (atomicInvalidateAddr < 32'h0001_0000);

    assign query_way_hit[0] = valid[0][query_index] && (tags[0][query_index] == query_tag);
    assign query_way_hit[1] = valid[1][query_index] && (tags[1][query_index] == query_tag);
    assign query_cache_hit = query_way_hit[0] | query_way_hit[1];
    assign query_hit_way = query_way_hit[1];

    assign line_read_way_hit[0] = valid[0][line_read_index] && (tags[0][line_read_index] == line_read_tag);
    assign line_read_way_hit[1] = valid[1][line_read_index] && (tags[1][line_read_index] == line_read_tag);
    assign line_read_cache_hit = line_read_way_hit[0] | line_read_way_hit[1];
    assign line_read_hit_way = line_read_way_hit[1];

    assign fill_replace_way = ~valid[0][fill_index] ? 1'b0 :
                              ~valid[1][fill_index] ? 1'b1 :
                              lru[fill_index];

    assign drain_way_hit[0] = valid[0][drain_index] && (tags[0][drain_index] == drain_tag);
    assign drain_way_hit[1] = valid[1][drain_index] && (tags[1][drain_index] == drain_tag);
    assign drain_cache_hit = drain_way_hit[0] | drain_way_hit[1];
    assign drain_hit_way = drain_way_hit[1];

    // The front-side query path only reports hits for cacheable addresses.
    assign queryHit = queryValid && queryCacheable && query_cache_hit;
    assign queryMiss = queryValid && queryCacheable && ~query_cache_hit;

    always_comb begin
        lineReadData = 32'b0;

        // Refills stream words back out of the hit way one word at a time.
        if (line_read_cache_hit)
            lineReadData = cache[line_read_hit_way][line_read_index][lineReadSelect];
    end

    always_ff @(negedge clk) begin
        if (rst) begin
            for (i = 0; i < NUM_WAYS; i = i + 1) begin
                for (j = 0; j < NUM_SETS; j = j + 1) begin
                    tags[i][j] <= '0;
                    valid[i][j] <= 1'b0;
                    if (i == 0)
                        lru[j] <= 1'b0;
                end
            end
        end else begin
            // Fills write one word per cycle, then publish the tag/valid bit on
            // the last beat so partially filled lines are never visible as hits.
            if (fillWrite) begin
                cache[fill_replace_way][fill_index][fillSelect] <= fillWordData;
                if (fillLast) begin
                    tags[fill_replace_way][fill_index] <= fill_tag;
                    valid[fill_replace_way][fill_index] <= 1'b1;
                    lru[fill_index] <= ~fill_replace_way;
                end
            end else if (atomicInvalidateValid && atomic_invalidate_cacheable) begin
                // Atomic commits may update backing memory behind the cache, so
                // invalidate any matching resident line to avoid stale reads.
                if (valid[0][atomic_invalidate_index] &&
                    (tags[0][atomic_invalidate_index] == atomic_invalidate_tag))
                    valid[0][atomic_invalidate_index] <= 1'b0;
                if (valid[1][atomic_invalidate_index] &&
                    (tags[1][atomic_invalidate_index] == atomic_invalidate_tag))
                    valid[1][atomic_invalidate_index] <= 1'b0;
            end else if (drainStoreValid && drain_store_cacheable && drain_cache_hit) begin
                logic [31:0] new_word;
                logic [31:0] aligned_drain_word;
                integer lane;

                // Keep L2 coherent with the drained store stream when the line
                // is already present, instead of forcing a later refill.
                new_word = cache[drain_hit_way][drain_index][drain_offset];
                aligned_drain_word = align_store_word(drainStoreData, drainStoreMask);

                for (lane = 0; lane < 4; lane = lane + 1) begin
                    if (drainStoreMask[lane])
                        new_word[(lane * 8) +: 8] = aligned_drain_word[(lane * 8) +: 8];
                end

                cache[drain_hit_way][drain_index][drain_offset] <= new_word;
                lru[drain_index] <= ~drain_hit_way;
            end else if (queryHit) begin
                // Normal read hits still refresh the replacement bit.
                lru[query_index] <= ~query_hit_way;
            end
        end
    end
endmodule
