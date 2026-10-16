`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: cache_tags
// Description:
//   Tag, valid, and replacement state for a fully associative cache. The
//   I-cache, D-cache, and L2 each keep their own data array and use this
//   module for everything else.
//
//   Lookups: LOOKUPS independent combinational ports. Each compares its tag
//   against every line at once (LINES comparators per port) and reports
//   hit / hit line.
//
//   Victim: the lowest-numbered invalid line if there is one, otherwise the
//   line chosen by the replacement policy.
//
//   Updates (falling edge, like the caches' data arrays), highest priority
//   first; the owning cache drives at most one of these per cycle:
//     flush       invalidate every line (reset, fence.i)
//     fill_en     install fill_tag in the victim line and mark it used
//     inval_en    invalidate line inval_line
//     touch_en    mark line touch_line most recently used
//   The victim is stable while nothing is written, so a multi-beat refill
//   that only asserts fill_en on its last beat writes one line throughout.
//
//   Replacement policy (TRUE_LRU parameter):
//     0  tree pseudo-LRU: LINES-1 state bits; each touch rewrites the
//        log2(LINES) bits on the path to point away from that line
//     1  true LRU: a log2(LINES)-bit age per line; the oldest line is the
//        victim
//////////////////////////////////////////////////////////////////////////////////

module cache_tags #(
    parameter int LINES = 16,
    parameter int TAG_BITS = 27,
    parameter int LOOKUPS = 1,
    parameter bit TRUE_LRU = 1'b0,
    localparam int LINE_BITS = $clog2(LINES)
) (
    input  logic clk,
    input  logic rst,

    input  logic [LOOKUPS-1:0][TAG_BITS-1:0] lookup_tag,
    output logic [LOOKUPS-1:0] lookup_hit,
    output logic [LOOKUPS-1:0][LINE_BITS-1:0] lookup_line,

    output logic [LINE_BITS-1:0] victim_line,

    input  logic flush,
    input  logic fill_en,
    input  logic [TAG_BITS-1:0] fill_tag,
    input  logic inval_en,
    input  logic [LINE_BITS-1:0] inval_line,
    input  logic touch_en,
    input  logic [LINE_BITS-1:0] touch_line
);

    logic [TAG_BITS-1:0] tags [LINES];
    logic [LINES-1:0] valid;

    // Lookup ports.
    always_comb begin
        for (int p = 0; p < LOOKUPS; p++) begin
            lookup_hit[p] = 1'b0;
            lookup_line[p] = '0;
            for (int l = 0; l < LINES; l++) begin
                if (valid[l] && (tags[l] == lookup_tag[p])) begin
                    lookup_hit[p] = 1'b1;
                    lookup_line[p] = LINE_BITS'(l);
                end
            end
        end
    end

    // Victim selection: fill invalid lines first.
    logic [LINE_BITS-1:0] policy_victim;
    logic any_invalid;
    logic [LINE_BITS-1:0] first_invalid;

    always_comb begin
        any_invalid = 1'b0;
        first_invalid = '0;
        for (int l = LINES - 1; l >= 0; l--) begin
            if (!valid[l]) begin
                any_invalid = 1'b1;
                first_invalid = LINE_BITS'(l);
            end
        end
    end

    assign victim_line = any_invalid ? first_invalid : policy_victim;

    logic touch_now;
    logic [LINE_BITS-1:0] touch_target;

    // A fill makes the filled line the most recently used.
    assign touch_now = !flush && (fill_en || (!inval_en && touch_en));
    assign touch_target = fill_en ? victim_line : touch_line;

    generate
        if (!TRUE_LRU) begin : g_plru
            // Heap-ordered binary tree: node n has children 2n+1 and 2n+2;
            // leaves LINES-1 .. 2*LINES-2 are lines 0 .. LINES-1. A node bit
            // of 0 means "the victim is on the left".
            logic [LINES-2:0] tree;

            always_comb begin
                int node;
                node = 0;
                for (int level = 0; level < LINE_BITS; level++)
                    node = 2 * node + (tree[node] ? 2 : 1);
                policy_victim = LINE_BITS'(node - (LINES - 1));
            end

            always_ff @(negedge clk) begin
                if (rst || flush) begin
                    tree <= '0;
                end else if (touch_now) begin
                    int node;
                    node = int'(touch_target) + LINES - 1;
                    for (int level = 0; level < LINE_BITS; level++) begin
                        // Point the parent away from the child we came from:
                        // coming from the left child (odd index) means the
                        // victim should now be found on the right.
                        tree[(node - 1) / 2] <= node[0];
                        node = (node - 1) / 2;
                    end
                end
            end
        end else begin : g_lru
            // Ages form a permutation of 0..LINES-1; 0 is most recent.
            logic [LINE_BITS-1:0] age [LINES];

            always_comb begin
                policy_victim = '0;
                for (int l = 0; l < LINES; l++)
                    if (age[l] == LINE_BITS'(LINES - 1))
                        policy_victim = LINE_BITS'(l);
            end

            always_ff @(negedge clk) begin
                if (rst || flush) begin
                    for (int l = 0; l < LINES; l++)
                        age[l] <= LINE_BITS'(l);
                end else if (touch_now) begin
                    for (int l = 0; l < LINES; l++) begin
                        if (LINE_BITS'(l) == touch_target)
                            age[l] <= '0;
                        else if (age[l] < age[touch_target])
                            age[l] <= age[l] + 1'b1;
                    end
                end
            end
        end
    endgenerate

    always_ff @(negedge clk) begin
        if (rst || flush) begin
            valid <= '0;
        end else if (fill_en) begin
            tags[victim_line] <= fill_tag;
            valid[victim_line] <= 1'b1;
        end else if (inval_en) begin
            valid[inval_line] <= 1'b0;
        end
    end
endmodule
