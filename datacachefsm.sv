`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: California Polytechnic University, San Luis Obispo
// Engineer: Long Ho
// Create Date: 02/23/2023 09:39:49 AM
// Module Name: datacachefsm
//////////////////////////////////////////////////////////////////////////////////
module datacachefsm(
    input logic clk,
    input logic rst,
    input logic exmemRead,
    input logic exmemWrite,
    input logic [31:0] exmemAddr,
    input logic [1:0] exmemSize,
    input logic exmemSign,

    input logic cacheMemReady,
    input logic hit,
    input logic l2Hit,
    input logic loadForwardHit,
    input logic loadForwardConflict,

    input logic storebufFull,
    input logic storebufEmpty,
    input logic storebufDrainValid,
    input logic [31:0] storebufDrainAddr,
    input logic [31:0] storebufDrainData,
    input logic [3:0] storebufDrainMask,

    output logic stall,
    output logic enable_write,
    output logic [2:0] select,
    output logic last,
    output logic refill_from_l2,

    output logic l2_fill_write,
    output logic [2:0] l2_fill_select,
    output logic l2_fill_last,

    output logic mem_rden2,
    output logic mem_we2,
    output logic [31:0] mem_addr2,
    output logic [31:0] mem_din2,
    output logic [1:0] mem_size,
    output logic mem_sign,
    output logic storebufDrainAccept,

    output logic miss_start,
    output logic busy,
    output logic drain_event
);
    logic fill_cache;
    logic fill_from_l2_q;
    logic uncached_wait; // waiting for the single-cycle uncached read to return data
    logic [3:0] count; // counts from 1 to 8 while filling cache lines on a miss

    logic cached_load_miss;
    logic uncached_load;
    logic start_fill;
    logic start_l2_fill;
    logic start_mem_fill;
    logic start_uncached_load;
    logic load_waiting_for_store;
    logic [31:0] block_addr;
    logic drain_issue;

    // Convert a drained store's byte mask back into the memory-port size code
    // because the backing BRAM interface still speaks byte/half/word writes.
    function automatic [1:0] size_from_mask(input logic [3:0] mask);
        begin
            unique case (mask)
                4'b0001, 4'b0010, 4'b0100, 4'b1000: size_from_mask = 2'd0;
                4'b0011, 4'b0110, 4'b1100: size_from_mask = 2'd1;
                4'b1111: size_from_mask = 2'd2;
                default: size_from_mask = 2'd0;
            endcase
        end
    endfunction

    // A cacheable miss may be satisfied either from L2 or from main memory,
    // while uncached reads bypass the refill path entirely.
    assign cached_load_miss = exmemRead && cacheMemReady &&
                              ~hit && ~loadForwardHit && ~loadForwardConflict;
    assign uncached_load = exmemRead && ~cacheMemReady &&
                           ~loadForwardHit && ~loadForwardConflict;

    // Preserve in-order behavior by draining all older stores before any
    // memory-backed load can claim the single D-side memory port.
    assign load_waiting_for_store = (cached_load_miss || uncached_load) && ~storebufEmpty;
    assign start_fill = cached_load_miss && ~fill_cache && ~uncached_wait && storebufEmpty;
    assign start_l2_fill = start_fill && l2Hit;
    assign start_mem_fill = start_fill && ~l2Hit;
    assign start_uncached_load = uncached_load && ~fill_cache && ~uncached_wait && storebufEmpty;
    assign block_addr = {exmemAddr[31:5], 5'b0};

    // The oldest store may drain whenever the load-miss machinery is idle.
    // During a normal posted-store burst we avoid draining in the same cycle as
    // a new store arrival so the buffer can actually absorb the burst. Once the
    // buffer is full, draining is re-enabled immediately to break the stall.
    assign drain_issue = storebufDrainValid &&
                         ~fill_cache &&
                         ~start_fill &&
                         ~uncached_wait &&
                         ~start_uncached_load &&
                         (~exmemWrite || storebufFull);

    assign miss_start = start_fill;
    assign busy = fill_cache || uncached_wait || ~storebufEmpty || start_fill || start_uncached_load;
    assign storebufDrainAccept = drain_issue;
    assign drain_event = drain_issue;

    always_ff @(posedge clk) begin
        if (rst) begin
            fill_cache <= 1'b0;
            fill_from_l2_q <= 1'b0;
            uncached_wait <= 1'b0;
            count <= 4'd0;
        end else begin
            if (fill_cache) begin
                // Count tracks the eight words in a cache line; once the last
                // beat has been requested, the refill state drops back to idle.
                if (count == 4'd8) begin
                    fill_cache <= 1'b0;
                    fill_from_l2_q <= 1'b0;
                    count <= 4'd0;
                end else begin
                    count <= count + 4'd1;
                end
            end else if (start_fill) begin
                fill_cache <= 1'b1;
                fill_from_l2_q <= l2Hit;
                count <= 4'd1;
            end else begin
                fill_from_l2_q <= 1'b0;
                count <= 4'd0;
            end

            // Uncached loads are a fixed one-read/one-wait transaction with the synchronous memory.
            if (uncached_wait)
                uncached_wait <= 1'b0;
            else if (start_uncached_load)
                uncached_wait <= 1'b1;
        end
    end

    always_comb begin
        enable_write = 1'b0;
        select = 3'b000;
        last = 1'b0;
        refill_from_l2 = fill_cache && fill_from_l2_q;

        l2_fill_write = 1'b0;
        l2_fill_select = 3'b000;
        l2_fill_last = 1'b0;

        mem_rden2 = 1'b0;
        mem_we2 = 1'b0;
        mem_addr2 = exmemAddr;
        mem_din2 = 32'b0;
        mem_size = exmemSize;
        mem_sign = exmemSign;

        stall = 1'b0;

        if (start_l2_fill) begin
            // L2 refill data is already available through the cache-side read
            // path, so only the front end needs to remain stalled.
            stall = 1'b1;
        end else if (start_mem_fill) begin
            // Main-memory refill starts by requesting the first word of the line.
            stall = 1'b1;
            mem_rden2 = 1'b1;
            mem_addr2 = block_addr;
            mem_size = 2'd2;
            mem_sign = 1'b0;
        end else if (fill_cache) begin
            stall = 1'b1;

            if (count <= 4'd7) begin
                enable_write = 1'b1;
                select = count[2:0] - 3'b001;

                if (fill_from_l2_q) begin
                    // L2-hit refills consume words from the side cache path and
                    // therefore do not need to drive the external memory port.
                    mem_size = exmemSize;
                    mem_sign = exmemSign;
                end else begin
                    // Memory refill streams one word into L1 and mirrors the same
                    // word into L2 so the next miss can hit there first.
                    mem_rden2 = 1'b1;
                    mem_addr2 = block_addr + (count * 4);
                    mem_size = 2'd2;
                    mem_sign = 1'b0;
                    l2_fill_write = 1'b1;
                    l2_fill_select = count[2:0] - 3'b001;
                end
            end else begin
                enable_write = 1'b1;
                select = 3'b111;
                last = 1'b1;

                if (fill_from_l2_q) begin
                    mem_size = exmemSize;
                    mem_sign = exmemSign;
                end else begin
                    // The last beat also marks the L2 fill line as complete.
                    mem_size = 2'd2;
                    mem_sign = 1'b0;
                    l2_fill_write = 1'b1;
                    l2_fill_select = 3'b111;
                    l2_fill_last = 1'b1;
                end
            end
        end else begin
            // A load stalls either because an older buffered store overlaps it
            // ambiguously, or because the memory side still owes older stores.
            if (loadForwardConflict || load_waiting_for_store || start_uncached_load)
                stall = 1'b1;

            if (drain_issue) begin
                // Draining uses the same memory port as misses, so it only runs
                // while the refill/uncached state machines are idle.
                mem_we2 = 1'b1;
                mem_addr2 = storebufDrainAddr;
                mem_din2 = storebufDrainData;
                mem_size = size_from_mask(storebufDrainMask);
                mem_sign = 1'b0;
            end else if (start_uncached_load) begin
                mem_rden2 = 1'b1;
            end
        end
    end
endmodule
// i love cpe333
