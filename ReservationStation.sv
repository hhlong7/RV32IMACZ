`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: ReservationStation
// Description:
//   Reservation station shared by every execution unit. Up to two entries are
//   inserted per cycle (one per dispatch slot); waiting operands capture
//   values broadcast on either common data bus; the oldest ready entry (by
//   ROB age) is offered to the unit, which takes it with issue_take.
//   A second port offers the second-oldest ready entry (two ALUs share one
//   station). IN_ORDER=1 only ever offers the oldest entry, which turns the station
//   into an in-order queue (used for memory operations). A squash drops
//   every entry younger than the mispredicted branch.
//
//   Wake-up happens on insertion too: an entry dispatched in the cycle its
//   producer broadcasts captures the value as it is written, so dispatch
//   needs no same-cycle bypass from the CDBs.
//
//   SPEC_WAKE=1 also accepts tag-only wake-ups (wk_*) from the ALUs: when an
//   ALU instruction is selected, its tag is broadcast at once; a consumer
//   waiting on it becomes ready (src*_spec) and may be selected in the very
//   next cycle, which is exactly the cycle the ALU drives the value on its
//   CDB. The offered entry then takes that value from the CDB, so dependent
//   ALU instructions still issue back to back.
//////////////////////////////////////////////////////////////////////////////////
module ReservationStation
    import ooo_pkg::*;
#(
    parameter int ENTRIES = 4,
    parameter bit IN_ORDER = 1'b0,
    parameter bit SPEC_WAKE = 1'b0
) (
    input  logic clk,
    input  logic rst,
    input  logic flush,
    input  logic squash,
    input  tag_t squash_tag,

    input  logic      ins0_en,
    input  rs_entry_t ins0,
    input  logic      ins1_en,
    input  rs_entry_t ins1,
    output logic [3:0] free_count,

    input  cdb_t cdb0,
    input  cdb_t cdb1,
    input  cdb_t cdb2,
    input  logic [1:0] wk_valid,          // tag-only wake-ups (SPEC_WAKE)
    input  tag_t [1:0] wk_tag,
    input  tag_t rob_head,

    output logic      issue_valid,
    output rs_entry_t issue_entry,
    input  logic      issue_take,

    // Second issue port (the second-oldest ready entry) for a station that
    // feeds two units; leave issue1_take low when unused.
    output logic      issue1_valid,
    output rs_entry_t issue1_entry,
    input  logic      issue1_take
);
    localparam int IDX_BITS = (ENTRIES <= 1) ? 1 : $clog2(ENTRIES);

    // Packed array: Icarus 13 cannot select fields from unpacked arrays of structs.
    rs_entry_t [ENTRIES-1:0] slots;
    logic [IDX_BITS-1:0] issue_idx, issue1_idx;

    always_comb begin
        free_count = '0;
        for (int i = 0; i < ENTRIES; i++)
            if (!slots[i].valid) free_count++;
    end

    // Selection, in parallel: every entry's age (ROB distance from the head)
    // is computed once; an entry's rank is how many candidates are older than
    // it (ties go to the lower index). Port 0 offers the rank-0 candidate,
    // port 1 the rank-1 candidate. A serial "oldest so far" loop would chain
    // all the comparisons one after another (two chains for two ports), which
    // made selection the longest path on the FPGA.
    // Candidates: valid and ready (IN_ORDER: valid; only offered if ready).
    localparam int RANK_BITS = $clog2(ENTRIES + 1);
    tag_t [ENTRIES-1:0] age;
    logic [ENTRIES-1:0] cand, ready, first, second;
    logic [ENTRIES-1:0][RANK_BITS-1:0] rank;

    always_comb begin
        for (int i = 0; i < ENTRIES; i++) begin
            age[i] = tag_age(slots[i].tag, rob_head);
            ready[i] = slots[i].valid && slots[i].src1_ready && slots[i].src2_ready;
            cand[i] = IN_ORDER ? slots[i].valid : ready[i];
        end
    end

    always_comb begin
        for (int i = 0; i < ENTRIES; i++) begin
            logic [RANK_BITS-1:0] n;
            n = '0;
            for (int j = 0; j < ENTRIES; j++)
                if (j != i && cand[j] && (age[j] < age[i] || (age[j] == age[i] && j < i)))
                    n = n + 1'b1;
            rank[i] = n;
        end
    end

    always_comb begin
        for (int i = 0; i < ENTRIES; i++) begin
            first[i] = cand[i] && (rank[i] == RANK_BITS'(0));
            second[i] = !IN_ORDER && cand[i] && (rank[i] == RANK_BITS'(1));
        end
    end

    // One-hot to index (0 when nothing is selected).
    always_comb begin
        logic [IDX_BITS-1:0] i0, i1;
        i0 = '0;
        i1 = '0;
        for (int i = 0; i < ENTRIES; i++) begin
            i0 = i0 | ({IDX_BITS{first[i]}} & IDX_BITS'(i));
            i1 = i1 | ({IDX_BITS{second[i]}} & IDX_BITS'(i));
        end
        issue_idx = i0;
        issue1_idx = i1;
        issue_valid = |(first & ready);
        issue1_valid = |second;
    end

    // The offered entries, with any speculatively woken operand taken from
    // the CDB that carries it this cycle (only stations built with SPEC_WAKE
    // have the CDB-value mux; synthesis cannot tell the spec bits stay 0). always @* (not always_comb): Icarus
    // 12 makes always_comb blocks that share a function re-trigger each other.
    function automatic rs_entry_t resolve(input rs_entry_t e, input cdb_t c0, input cdb_t c1, input cdb_t c2);
        resolve = e;
        if (SPEC_WAKE && e.src1_spec) begin
            if (c0.valid && c0.tag == e.src1_tag) resolve.src1 = c0.value;
            else if (c1.valid && c1.tag == e.src1_tag) resolve.src1 = c1.value;
            else if (c2.valid && c2.tag == e.src1_tag) resolve.src1 = c2.value;
        end
        if (SPEC_WAKE && e.src2_spec) begin
            if (c0.valid && c0.tag == e.src2_tag) resolve.src2 = c0.value;
            else if (c1.valid && c1.tag == e.src2_tag) resolve.src2 = c1.value;
            else if (c2.valid && c2.tag == e.src2_tag) resolve.src2 = c2.value;
        end
    endfunction

    always @* issue_entry = resolve(slots[issue_idx], cdb0, cdb1, cdb2);
    always @* issue1_entry = resolve(slots[issue1_idx], cdb0, cdb1, cdb2);

    // Value wake-up: also completes a speculative wake-up (the value arrives).
    function automatic rs_entry_t wake(input rs_entry_t e, input cdb_t c);
        wake = e;
        if (c.valid && (!e.src1_ready || e.src1_spec) && e.src1_tag == c.tag) begin
            wake.src1_ready = 1'b1;
            wake.src1_spec = 1'b0;
            wake.src1 = c.value;
        end
        if (c.valid && (!e.src2_ready || e.src2_spec) && e.src2_tag == c.tag) begin
            wake.src2_ready = 1'b1;
            wake.src2_spec = 1'b0;
            wake.src2 = c.value;
        end
    endfunction

    // Tag-only wake-up: ready now, value on a CDB next cycle.
    function automatic rs_entry_t spec_wake(input rs_entry_t e, input logic v, input tag_t t);
        spec_wake = e;
        if (SPEC_WAKE && v && !e.src1_ready && e.src1_tag == t) begin
            spec_wake.src1_ready = 1'b1;
            spec_wake.src1_spec = 1'b1;
        end
        if (SPEC_WAKE && v && !e.src2_ready && e.src2_tag == t) begin
            spec_wake.src2_ready = 1'b1;
            spec_wake.src2_spec = 1'b1;
        end
    endfunction

    function automatic rs_entry_t all_wakes(input rs_entry_t e, input cdb_t c0, input cdb_t c1, input cdb_t c2,
                                            input logic [1:0] wv, input tag_t [1:0] wt);
        all_wakes = spec_wake(spec_wake(wake(wake(wake(e, c0), c1), c2), wv[0], wt[0]), wv[1], wt[1]);
    endfunction

    always_ff @(posedge clk) begin
        if (rst || flush) begin
            for (int i = 0; i < ENTRIES; i++)
                slots[i] <= '0;
        end else begin
            logic placed0, placed1;
            placed0 = !ins0_en;
            placed1 = !ins1_en;
            for (int i = 0; i < ENTRIES; i++) begin
                rs_entry_t e;
                e = slots[i];
                if (e.valid) begin
                    e = all_wakes(e, cdb0, cdb1, cdb2, wk_valid, wk_tag);
                    if (issue_take && issue_valid && IDX_BITS'(i) == issue_idx)
                        e.valid = 1'b0;
                    if (issue1_take && issue1_valid && IDX_BITS'(i) == issue1_idx)
                        e.valid = 1'b0;
                    if (squash && tag_younger(e.tag, squash_tag, rob_head))
                        e.valid = 1'b0;
                end else if (!placed0) begin
                    e = all_wakes(ins0, cdb0, cdb1, cdb2, wk_valid, wk_tag);
                    e.valid = 1'b1;
                    placed0 = 1'b1;
                end else if (!placed1) begin
                    e = all_wakes(ins1, cdb0, cdb1, cdb2, wk_valid, wk_tag);
                    e.valid = 1'b1;
                    placed1 = 1'b1;
                end
                slots[i] <= e;
            end
        end
    end
endmodule
