`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: CdbArbiter
// Description:
//   Grants the three common data buses to the three oldest requesting units
//   (by ROB age), so the instruction blocking commit always makes progress. A
//   unit whose request is not granted holds its result and retries.
//
//   Each request's age is computed once from its tag; each request's rank is
//   the number of valid requests older than it (ties go to the lower index);
//   CDB k carries the request of rank k, selected one-hot with an AND-OR.
//   Only the small tags are compared, never the wide request records.
//////////////////////////////////////////////////////////////////////////////////
module CdbArbiter
    import ooo_pkg::*;
#(
    parameter int REQUESTERS = 6
) (
    input  cdb_t [REQUESTERS-1:0] req,
    input  tag_t rob_head,
    output logic [REQUESTERS-1:0] grant,
    output cdb_t cdb0,
    output cdb_t cdb1,
    output cdb_t cdb2
);
    localparam int RANK_BITS = $clog2(REQUESTERS + 1);

    // Separate blocks over module-level packed arrays: Icarus 12 aborts on
    // local arrays in always_comb and loops on blocks that read their own
    // outputs.
    logic [REQUESTERS-1:0] valid;
    tag_t [REQUESTERS-1:0] age;
    logic [REQUESTERS-1:0][RANK_BITS-1:0] rank;
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

    always_comb begin
        for (int i = 0; i < REQUESTERS; i++) begin
            sel0[i] = valid[i] && (rank[i] == RANK_BITS'(0));
            sel1[i] = valid[i] && (rank[i] == RANK_BITS'(1));
            sel2[i] = valid[i] && (rank[i] == RANK_BITS'(2));
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
        cdb0 = c0;
        cdb1 = c1;
        cdb2 = c2;
        grant = sel0 | sel1 | sel2;
    end
endmodule
