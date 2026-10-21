`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: CdbArbiter
// Description:
//   Grants the three common data buses to the three oldest requesting units
//   (by ROB age), so the instruction blocking commit always makes progress. A
//   unit whose request is not granted holds its result and retries.
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
    // Three passes, each taking the oldest request not yet granted. Built in
    // locals (no local arrays: Icarus 12 asserts on them in always_comb, and
    // an always_comb that reads its own output loops forever there).
    always_comb begin
        int p0, p1, p2;
        logic [REQUESTERS-1:0] g;
        g = '0;
        p0 = -1;
        for (int i = 0; i < REQUESTERS; i++)
            if (req[i].valid && (p0 < 0 || tag_age(req[i].tag, rob_head) < tag_age(req[p0].tag, rob_head)))
                p0 = i;
        if (p0 >= 0) g[p0] = 1'b1;
        p1 = -1;
        for (int i = 0; i < REQUESTERS; i++)
            if (req[i].valid && !g[i] && (p1 < 0 || tag_age(req[i].tag, rob_head) < tag_age(req[p1].tag, rob_head)))
                p1 = i;
        if (p1 >= 0) g[p1] = 1'b1;
        p2 = -1;
        for (int i = 0; i < REQUESTERS; i++)
            if (req[i].valid && !g[i] && (p2 < 0 || tag_age(req[i].tag, rob_head) < tag_age(req[p2].tag, rob_head)))
                p2 = i;
        if (p2 >= 0) g[p2] = 1'b1;
        grant = g;
        cdb0 = (p0 >= 0) ? req[p0] : '0;
        cdb1 = (p1 >= 0) ? req[p1] : '0;
        cdb2 = (p2 >= 0) ? req[p2] : '0;
    end
endmodule
