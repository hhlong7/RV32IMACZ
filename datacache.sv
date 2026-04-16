module datacache(
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
    input logic [2:0] select, // which word inside the cache line to update during a fill
    input logic last,         // asserted on the final fill beat so tag/valid/LRU can commit
    input logic [31:0] word_data,

    output logic loadHit,
    output logic loadMiss,
    output logic loadCacheable,
    output logic [31:0] loadRData
);
    // 2-way set-associative D$ with LRU replacement.
    // Drained stores update the cache on hits only; there is still no
    // write-allocate path for stores that miss in the cache.
    parameter int TOTAL_BLOCKS = 16;
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

    logic [INDEX_SIZE-1:0] load_index;
    logic [OFFSET_SIZE-1:0] load_offset;
    logic [BYTE_OFFSET_SIZE-1:0] load_byte_offset;
    logic [TAG_SIZE-1:0] load_tag;
    logic [NUM_WAYS-1:0] load_way_hit;
    logic load_cache_hit;
    logic load_hit_way;
    logic load_replace_way;
    logic [31:0] load_selected_word;

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

    assign load_index = loadAddr[BYTE_OFFSET_SIZE + OFFSET_SIZE + INDEX_SIZE - 1:BYTE_OFFSET_SIZE + OFFSET_SIZE];
    assign load_offset = loadAddr[BYTE_OFFSET_SIZE + OFFSET_SIZE - 1:BYTE_OFFSET_SIZE];
    assign load_byte_offset = loadAddr[BYTE_OFFSET_SIZE-1:0];
    assign load_tag = loadAddr[31:BYTE_OFFSET_SIZE + OFFSET_SIZE + INDEX_SIZE];

    assign drain_index = drainStoreAddr[BYTE_OFFSET_SIZE + OFFSET_SIZE + INDEX_SIZE - 1:BYTE_OFFSET_SIZE + OFFSET_SIZE];
    assign drain_offset = drainStoreAddr[BYTE_OFFSET_SIZE + OFFSET_SIZE - 1:BYTE_OFFSET_SIZE];
    assign drain_tag = drainStoreAddr[31:BYTE_OFFSET_SIZE + OFFSET_SIZE + INDEX_SIZE];
    assign atomic_invalidate_index = atomicInvalidateAddr[BYTE_OFFSET_SIZE + OFFSET_SIZE + INDEX_SIZE - 1:BYTE_OFFSET_SIZE + OFFSET_SIZE];
    assign atomic_invalidate_tag = atomicInvalidateAddr[31:BYTE_OFFSET_SIZE + OFFSET_SIZE + INDEX_SIZE];

    // Internal BRAM-backed data memory is cacheable; MMIO stays uncached.
    assign loadCacheable = (loadAddr < 32'h0001_0000);
    assign drain_store_cacheable = (drainStoreAddr < 32'h0001_0000);
    assign atomic_invalidate_cacheable = (atomicInvalidateAddr < 32'h0001_0000);

    assign load_way_hit[0] = valid[0][load_index] && (tags[0][load_index] == load_tag);
    assign load_way_hit[1] = valid[1][load_index] && (tags[1][load_index] == load_tag);
    assign load_cache_hit = load_way_hit[0] | load_way_hit[1];
    assign load_hit_way = load_way_hit[1];

    assign drain_way_hit[0] = valid[0][drain_index] && (tags[0][drain_index] == drain_tag);
    assign drain_way_hit[1] = valid[1][drain_index] && (tags[1][drain_index] == drain_tag);
    assign drain_cache_hit = drain_way_hit[0] | drain_way_hit[1];
    assign drain_hit_way = drain_way_hit[1];

    // Use an invalid way first; otherwise evict the least-recently-used way.
    assign load_replace_way = ~valid[0][load_index] ? 1'b0 :
                              ~valid[1][load_index] ? 1'b1 :
                              lru[load_index];

    assign loadHit = loadRead & loadCacheable & load_cache_hit;
    assign loadMiss = loadRead & loadCacheable & ~load_cache_hit;

    always_comb begin
        logic [7:0] loaded_byte;
        logic [15:0] loaded_half;

        load_selected_word = 32'b0;
        loadRData = 32'b0;
        loaded_byte = 8'b0;
        loaded_half = 16'b0;

        if (load_cache_hit)
            load_selected_word = cache[load_hit_way][load_index][load_offset];

        if (loadHit) begin
            unique case (loadSize)
                2'd0: begin
                    unique case (load_byte_offset)
                        2'd0: loaded_byte = load_selected_word[7:0];
                        2'd1: loaded_byte = load_selected_word[15:8];
                        2'd2: loaded_byte = load_selected_word[23:16];
                        2'd3: loaded_byte = load_selected_word[31:24];
                        default: loaded_byte = 8'b0;
                    endcase
                    loadRData = loadSign ? {24'd0, loaded_byte} : {{24{loaded_byte[7]}}, loaded_byte};
                end

                2'd1: begin
                    unique case (load_byte_offset)
                        2'd0: loaded_half = load_selected_word[15:0];
                        2'd1: loaded_half = load_selected_word[23:8];
                        2'd2: loaded_half = load_selected_word[31:16];
                        default: loaded_half = 16'b0;
                    endcase
                    loadRData = loadSign ? {16'd0, loaded_half} : {{16{loaded_half[15]}}, loaded_half};
                end

                2'd2: loadRData = load_selected_word;
                default: loadRData = 32'b0;
            endcase
        end
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
            // A fill writes one word per beat into the chosen replacement way.
            // Because the pipeline is stalled during the fill, loadAddr/index/tag stay stable.
            if (enable_write) begin
                cache[load_replace_way][load_index][select] <= word_data;
                if (last) begin
                    tags[load_replace_way][load_index] <= load_tag;
                    valid[load_replace_way][load_index] <= 1'b1;
                    lru[load_index] <= ~load_replace_way;
                end
            end else if (atomicInvalidateValid && atomic_invalidate_cacheable) begin
                // Atomics bypass the posted-store update path, so invalidate any
                // matching cached copy immediately and let the next load refetch
                // the architecturally committed memory word.
                if (valid[0][atomic_invalidate_index] &&
                    (tags[0][atomic_invalidate_index] == atomic_invalidate_tag))
                    valid[0][atomic_invalidate_index] <= 1'b0;
                if (valid[1][atomic_invalidate_index] &&
                    (tags[1][atomic_invalidate_index] == atomic_invalidate_tag))
                    valid[1][atomic_invalidate_index] <= 1'b0;
            end else if (drainStoreValid && drain_store_cacheable && drain_cache_hit) begin
                // Drained stores update cached copies lazily here instead of at
                // pipeline issue time, so the D$ only sees architecturally
                // accepted stores from the buffer.
                logic [31:0] new_word;
                logic [31:0] aligned_drain_word;
                integer lane;

                new_word = cache[drain_hit_way][drain_index][drain_offset];
                aligned_drain_word = align_store_word(drainStoreData, drainStoreMask);

                for (lane = 0; lane < 4; lane = lane + 1) begin
                    if (drainStoreMask[lane])
                        new_word[(lane * 8) +: 8] = aligned_drain_word[(lane * 8) +: 8];
                end

                cache[drain_hit_way][drain_index][drain_offset] <= new_word;
                lru[drain_index] <= ~drain_hit_way;
            end else if (loadHit) begin
                // Read hits also refresh LRU state.
                lru[load_index] <= ~load_hit_way;
            end
        end
    end
endmodule
// i love cpe333
