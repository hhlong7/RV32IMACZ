`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: RenameTable
// Description:
//   Register alias table for x0-x31 (index 0-31) and f0-f31 (index 32-63).
//   A busy register's newest value will come from ROB entry `tag`; a register
//   that is not busy reads its committed value from the register file.
//   Dispatch marks destinations busy (the younger slot wins on a clash);
//   commit clears an entry only if no younger instruction has renamed the
//   register since. A flush (only ever with the ROB empty afterwards) clears
//   everything.
//
//   Checkpoints: a dispatching branch saves the table as it will be after
//   this cycle (its own bundle's renames and this cycle's commits applied).
//   Commits keep clearing busy bits inside every checkpoint, so restoring one
//   when the branch turns out mispredicted gives exactly the mapping of the
//   instructions older than (and including) the branch.
//////////////////////////////////////////////////////////////////////////////////
module RenameTable
    import ooo_pkg::*;
(
    input  logic clk,
    input  logic rst,
    input  logic flush,

    input  logic [3:0][5:0] lookup_idx,
    output logic [3:0]      lookup_busy,
    output tag_t [3:0]      lookup_tag,

    input  logic       set0_en,
    input  logic [5:0] set0_idx,
    input  tag_t       set0_tag,
    input  logic       set1_en,
    input  logic [5:0] set1_idx,
    input  tag_t       set1_tag,

    input  logic       clear0_en,
    input  logic [5:0] clear0_idx,
    input  tag_t       clear0_tag,
    input  logic       clear1_en,
    input  logic [5:0] clear1_idx,
    input  tag_t       clear1_tag,

    input  logic       save_en,          // checkpoint the next-state table
    input  ckpt_t      save_id,
    input  logic       save_after_slot0, // ...without slot 1's rename (the
                                         // branch is slot 0, slot 1 younger)
    input  logic       restore_en,       // replace the table with a checkpoint
    input  ckpt_t      restore_id
);
    // One process per register (and per checkpoint copy of it): no loops of
    // nonblocking array writes, which Verilator 5.0 cannot unroll at this size.
    logic busy [64];
    tag_t tags [64];
    logic next_busy [64];                 // table after this cycle's updates
    tag_t next_tags [64];
    logic save_busy [64];                 // what a checkpoint saved now holds
    tag_t save_tags [64];
    logic ck_busy [CKPTS][64];
    tag_t ck_tags [CKPTS][64];

    always_comb begin
        for (int p = 0; p < 4; p++) begin
            lookup_busy[p] = busy[lookup_idx[p]];
            lookup_tag[p] = tags[lookup_idx[p]];
        end
    end

    for (genvar r = 0; r < 64; r++) begin : reg_g
        // Next state: restore (instead of this cycle's renames) or renames,
        // with this cycle's commit clears applied either way.
        always @* begin
            logic b;
            tag_t t;
            b = restore_en ? ck_busy[restore_id][r] : busy[r];
            t = restore_en ? ck_tags[restore_id][r] : tags[r];
            if ((clear0_en && clear0_idx == 6'(r) && t == clear0_tag) ||
                (clear1_en && clear1_idx == 6'(r) && t == clear1_tag))
                b = 1'b0;
            if (!restore_en && set0_en && set0_idx == 6'(r)) begin
                b = 1'b1;
                t = set0_tag;
            end
            save_busy[r] = b;
            save_tags[r] = t;
            if (!restore_en && set1_en && set1_idx == 6'(r)) begin
                b = 1'b1;
                t = set1_tag;
            end
            next_busy[r] = b;
            next_tags[r] = t;
            if (!save_after_slot0) begin
                save_busy[r] = b;
                save_tags[r] = t;
            end
        end

        always_ff @(posedge clk) begin
            if (rst || flush)
                busy[r] <= 1'b0;
            else
                busy[r] <= next_busy[r];
            tags[r] <= next_tags[r];
        end

        // Checkpoint copies: saved from the next-state table, and kept
        // current by the same commit clears.
        for (genvar k = 0; k < CKPTS; k++) begin : ck_g
            always_ff @(posedge clk) begin
                if (rst || flush) begin
                    ck_busy[k][r] <= 1'b0;
                end else if (save_en && save_id == ckpt_t'(k)) begin
                    ck_busy[k][r] <= save_busy[r];
                    ck_tags[k][r] <= save_tags[r];
                end else if ((clear0_en && clear0_idx == 6'(r) && ck_tags[k][r] == clear0_tag) ||
                             (clear1_en && clear1_idx == 6'(r) && ck_tags[k][r] == clear1_tag)) begin
                    ck_busy[k][r] <= 1'b0;
                end
            end
        end
    end
endmodule
