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
//////////////////////////////////////////////////////////////////////////////////
module ReservationStation
    import ooo_pkg::*;
#(
    parameter int ENTRIES = 4,
    parameter bit IN_ORDER = 1'b0
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

    // Offer the oldest ready entry (IN_ORDER: the oldest entry, if ready).
    always_comb begin
        tag_t best_age;
        logic found;
        best_age = '1;
        found = 1'b0;
        issue_idx = '0;
        for (int i = 0; i < ENTRIES; i++) begin
            if (slots[i].valid && (!found || tag_age(slots[i].tag, rob_head) < best_age)) begin
                if (IN_ORDER || (slots[i].src1_ready && slots[i].src2_ready)) begin
                    found = 1'b1;
                    best_age = tag_age(slots[i].tag, rob_head);
                    issue_idx = IDX_BITS'(i);
                end
            end
        end
        issue_entry = slots[issue_idx];
        issue_valid = found && slots[issue_idx].src1_ready && slots[issue_idx].src2_ready;
    end

    // Second-oldest ready entry (never in IN_ORDER mode).
    always_comb begin
        tag_t best_age;
        logic found;
        best_age = '1;
        found = 1'b0;
        issue1_idx = '0;
        for (int i = 0; i < ENTRIES; i++) begin
            if (!IN_ORDER && issue_valid && IDX_BITS'(i) != issue_idx &&
                slots[i].valid && slots[i].src1_ready && slots[i].src2_ready &&
                (!found || tag_age(slots[i].tag, rob_head) < best_age)) begin
                found = 1'b1;
                best_age = tag_age(slots[i].tag, rob_head);
                issue1_idx = IDX_BITS'(i);
            end
        end
        issue1_entry = slots[issue1_idx];
        issue1_valid = found;
    end

    function automatic rs_entry_t wake(input rs_entry_t e, input cdb_t c);
        wake = e;
        if (c.valid && !e.src1_ready && e.src1_tag == c.tag) begin
            wake.src1_ready = 1'b1;
            wake.src1 = c.value;
        end
        if (c.valid && !e.src2_ready && e.src2_tag == c.tag) begin
            wake.src2_ready = 1'b1;
            wake.src2 = c.value;
        end
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
                    e = wake(wake(wake(e, cdb0), cdb1), cdb2);
                    if (issue_take && issue_valid && IDX_BITS'(i) == issue_idx)
                        e.valid = 1'b0;
                    if (issue1_take && issue1_valid && IDX_BITS'(i) == issue1_idx)
                        e.valid = 1'b0;
                    if (squash && tag_younger(e.tag, squash_tag, rob_head))
                        e.valid = 1'b0;
                end else if (!placed0) begin
                    e = ins0;
                    e.valid = 1'b1;
                    placed0 = 1'b1;
                end else if (!placed1) begin
                    e = ins1;
                    e.valid = 1'b1;
                    placed1 = 1'b1;
                end
                slots[i] <= e;
            end
        end
    end
endmodule
