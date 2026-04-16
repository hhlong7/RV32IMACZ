`timescale 1ns/1ps

module BranchPredictor #(
    parameter int BHT_ENTRIES = 16,
    parameter int BTB_ENTRIES = 8,
    parameter int RAS_DEPTH = 4,
    parameter logic [1:0] BHT_RESET_VALUE = 2'b01
) (
    input logic clk,
    input logic rst,

    input logic [31:0] fetch0_pc,
    output logic fetch0_bht_taken,
    output logic fetch0_btb_hit,
    output logic [31:0] fetch0_btb_target,

    input logic [31:0] fetch1_pc,
    output logic fetch1_bht_taken,
    output logic fetch1_btb_hit,
    output logic [31:0] fetch1_btb_target,

    output logic ras_valid,
    output logic [31:0] ras_top,

    input logic train_enable,

    input logic branch_update_valid,
    input logic branch_taken,
    input logic [31:0] branch_pc,

    input logic btb_update_valid,
    input logic [31:0] btb_update_pc,
    input logic [31:0] btb_update_target,

    input logic ras_pop,
    input logic ras_push,
    input logic [31:0] ras_push_addr
);

    localparam int BHT_INDEX_WIDTH = (BHT_ENTRIES <= 1) ? 1 : $clog2(BHT_ENTRIES);
    localparam int BTB_INDEX_WIDTH = (BTB_ENTRIES <= 1) ? 1 : $clog2(BTB_ENTRIES);
    localparam int RAS_PTR_WIDTH = (RAS_DEPTH <= 1) ? 1 : $clog2(RAS_DEPTH);
    localparam int RAS_COUNT_WIDTH = $clog2(RAS_DEPTH + 1);
    localparam int LAST_RAS_ENTRY = RAS_DEPTH - 1;
    localparam logic [RAS_COUNT_WIDTH-1:0] RAS_COUNT_MAX = RAS_DEPTH;

    logic [1:0] bht [0:BHT_ENTRIES-1];
    logic       btb_valid [0:BTB_ENTRIES-1];
    logic [31:0] btb_pc [0:BTB_ENTRIES-1];
    logic [31:0] btb_target_mem [0:BTB_ENTRIES-1];
    logic [31:0] ras_stack [0:RAS_DEPTH-1];
    logic [RAS_PTR_WIDTH-1:0] ras_sp;
    logic [RAS_COUNT_WIDTH-1:0] ras_count;

    logic [BHT_INDEX_WIDTH-1:0] bht_ridx0, bht_ridx1, bht_widx;
    logic [BTB_INDEX_WIDTH-1:0] btb_ridx0, btb_ridx1, btb_widx;
    integer pred_i;

    assign bht_ridx0 = fetch0_pc[BHT_INDEX_WIDTH+1:2];
    assign bht_ridx1 = fetch1_pc[BHT_INDEX_WIDTH+1:2];
    assign bht_widx = branch_pc[BHT_INDEX_WIDTH+1:2];
    assign btb_ridx0 = fetch0_pc[BTB_INDEX_WIDTH+1:2];
    assign btb_ridx1 = fetch1_pc[BTB_INDEX_WIDTH+1:2];
    assign btb_widx = btb_update_pc[BTB_INDEX_WIDTH+1:2];

    assign fetch0_bht_taken = bht[bht_ridx0][1];
    assign fetch0_btb_hit = btb_valid[btb_ridx0] && (btb_pc[btb_ridx0] == fetch0_pc);
    assign fetch0_btb_target = btb_target_mem[btb_ridx0];

    assign fetch1_bht_taken = bht[bht_ridx1][1];
    assign fetch1_btb_hit = btb_valid[btb_ridx1] && (btb_pc[btb_ridx1] == fetch1_pc);
    assign fetch1_btb_target = btb_target_mem[btb_ridx1];

    assign ras_valid = (ras_count != '0);
    assign ras_top = ras_stack[(ras_sp == '0) ? LAST_RAS_ENTRY : (ras_sp - 1'b1)];

    always_ff @(posedge clk) begin
        if (rst) begin
            ras_sp <= '0;
            ras_count <= '0;

            for (pred_i = 0; pred_i < BHT_ENTRIES; pred_i = pred_i + 1)
                bht[pred_i] <= BHT_RESET_VALUE;

            for (pred_i = 0; pred_i < BTB_ENTRIES; pred_i = pred_i + 1) begin
                btb_valid[pred_i] <= 1'b0;
                btb_pc[pred_i] <= 32'b0;
                btb_target_mem[pred_i] <= 32'b0;
            end

            for (pred_i = 0; pred_i < RAS_DEPTH; pred_i = pred_i + 1)
                ras_stack[pred_i] <= 32'b0;
        end else if (train_enable) begin
            if (branch_update_valid) begin
                unique case (bht[bht_widx])
                    2'b00: bht[bht_widx] <= branch_taken ? 2'b01 : 2'b00;
                    2'b01: bht[bht_widx] <= branch_taken ? 2'b10 : 2'b00;
                    2'b10: bht[bht_widx] <= branch_taken ? 2'b11 : 2'b01;
                    2'b11: bht[bht_widx] <= branch_taken ? 2'b11 : 2'b10;
                    default: bht[bht_widx] <= BHT_RESET_VALUE;
                endcase
            end

            if (btb_update_valid) begin
                btb_valid[btb_widx] <= 1'b1;
                btb_pc[btb_widx] <= btb_update_pc;
                btb_target_mem[btb_widx] <= btb_update_target;
            end

            if (ras_pop && ras_valid) begin
                ras_sp <= ras_sp - 1'b1;
                ras_count <= ras_count - 1'b1;
            end

            if (ras_push) begin
                ras_stack[ras_sp] <= ras_push_addr;
                ras_sp <= ras_sp + 1'b1;
                if (ras_count != RAS_COUNT_MAX)
                    ras_count <= ras_count + 1'b1;
            end
        end
    end
endmodule
