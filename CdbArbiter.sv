`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: CdbArbiter
// Description:
//   Shares the common data buses that the fixed-latency units leave free.
//   ALU 0, ALU 1, and the branch unit own CDB 0, 1, and 2 in any cycle they
//   execute; the other units (LSU, FP, integer multiply/divide, CSR reads)
//   request a bus and the oldest requests (by ROB age) get the free ones, so
//   the instruction blocking commit always makes progress. A unit whose
//   request is not granted holds its result and retries.
//
//   Each request's age is computed once from its tag; its rank is the number
//   of valid requests older than it (ties go to the lower index); the rank-k
//   request takes the k-th free bus, selected one-hot with an AND-OR. Only
//   the small tags are compared, never the wide request records.
//////////////////////////////////////////////////////////////////////////////////
module CdbArbiter
    import ooo_pkg::*;
#(
    parameter int REQUESTERS = 7
) (
    input  cdb_t [REQUESTERS-1:0] req,
    input  tag_t rob_head,
    input  logic [2:0] bus_free,          // bus j is not driven by its owner unit
    output logic [REQUESTERS-1:0] grant,
    output cdb_t bus0,                    // the request granted bus j ('0 if none)
    output cdb_t bus1,
    output cdb_t bus2
);
    localparam int RANK_BITS = $clog2(REQUESTERS + 1);

    // Separate blocks over module-level packed arrays: Icarus 12 aborts on
    // local arrays in always_comb and loops on blocks that read their own
    // outputs.
    logic [REQUESTERS-1:0] valid;
    tag_t [REQUESTERS-1:0] age;
    logic [REQUESTERS-1:0][RANK_BITS-1:0] rank;
    logic [1:0] slot1, slot2;             // rank carried by bus 1 / bus 2 if free
    logic [REQUESTERS-1:0] sel0, sel1, sel2;

    always_comb begin
        for (int i = 0; i < REQUESTERS; i++) begin
            valid[i] = req[i].valid;
            age[i] = tag_t'(req[i].tag - rob_head);
        end
    end

    always_comb begin
        for (int i = 0; i < REQUESTERS; i++) begin
            logic [RANK_BITS-1:0] n;
            n = '0;
            for (int j = 0; j < REQUESTERS; j++)
                if (j != i && valid[j] && (age[j] < age[i] || (age[j] == age[i] && j < i)))
                    n = n + 1'b1;
            rank[i] = n;
        end
    end

    // Free buses are filled in order: rank 0 takes the first free bus.
    always_comb begin
        slot1 = {1'b0, bus_free[0]};
        slot2 = 2'(bus_free[0]) + 2'(bus_free[1]);
    end

    always_comb begin
        for (int i = 0; i < REQUESTERS; i++) begin
            sel0[i] = valid[i] && bus_free[0] && (rank[i] == RANK_BITS'(0));
            sel1[i] = valid[i] && bus_free[1] && (rank[i] == RANK_BITS'(slot1));
            sel2[i] = valid[i] && bus_free[2] && (rank[i] == RANK_BITS'(slot2));
        end
    end

    always_comb begin
        cdb_t c0, c1, c2;
        c0 = '0;
        c1 = '0;
        c2 = '0;
        for (int i = 0; i < REQUESTERS; i++) begin
            c0 = c0 | ({$bits(cdb_t){sel0[i]}} & req[i]);
            c1 = c1 | ({$bits(cdb_t){sel1[i]}} & req[i]);
            c2 = c2 | ({$bits(cdb_t){sel2[i]}} & req[i]);
        end
        bus0 = c0;
        bus1 = c1;
        bus2 = c2;
        grant = sel0 | sel1 | sel2;
    end
endmodule
