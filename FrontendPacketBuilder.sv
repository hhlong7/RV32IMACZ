`timescale 1ns/1ps

module FrontendPacketBuilder(
    input logic valid_i,
    input logic [31:0] pc_i,
    input logic [31:0] ir_i,
    input logic instr_is_compressed_i,
    input logic ras_valid_i,
    input logic [31:0] ras_top_i,
    input logic btb_hit_i,
    input logic [31:0] btb_target_i,
    input logic bht_taken_i,
    output otter_defs_pkg::frontend_t packet_o
);

    import otter_defs_pkg::*;

    always_comb begin
        packet_o = '0;

        packet_o.valid = valid_i;
        packet_o.pc = pc_i;
        // The struct field keeps its historical name, but it now carries the
        // architectural fall-through PC for either a 16-bit or 32-bit instruction.
        packet_o.pc_4 = pc_i + (instr_is_compressed_i ? 32'd2 : 32'd4);
        packet_o.ir = ir_i;

        // Classify the instruction once here so the fetch stages can carry a
        // fully annotated packet instead of re-decoding branch intent later.
        packet_o.is_branch = (ir_i[6:0] == 7'b1100011);
        packet_o.is_jal = (ir_i[6:0] == 7'b1101111);
        packet_o.is_jalr = (ir_i[6:0] == 7'b1100111) && (ir_i[14:12] == 3'b000);
        packet_o.rd_is_link = (ir_i[11:7] == 5'd1) || (ir_i[11:7] == 5'd5);
        packet_o.rs1_is_link = (ir_i[19:15] == 5'd1) || (ir_i[19:15] == 5'd5);
        packet_o.jal_offset = {{12{ir_i[31]}}, ir_i[19:12], ir_i[20], ir_i[30:21], 1'b0};
        packet_o.is_return = packet_o.is_jalr &&
                             (ir_i[11:7] == 5'd0) &&
                             packet_o.rs1_is_link &&
                             (ir_i[31:20] == 12'd0);
        packet_o.predicted_taken = 1'b0;
        packet_o.predicted_target = packet_o.pc_4;

        if (valid_i) begin
            if (packet_o.is_jal) begin
                // JAL has an immediate target in the instruction itself, so it
                // can be predicted taken without consulting BTB state.
                packet_o.predicted_taken = 1'b1;
                packet_o.predicted_target = pc_i + packet_o.jal_offset;
            end else if (packet_o.is_return && ras_valid_i) begin
                // Returns use the RAS when available because the BTB target is
                // less reliable than the architecturally paired call stack.
                packet_o.predicted_taken = 1'b1;
                packet_o.predicted_target = ras_top_i;
            end else if (btb_hit_i) begin
                if (packet_o.is_jalr) begin
                    // Non-return jalr relies entirely on the remembered BTB target.
                    packet_o.predicted_taken = 1'b1;
                    packet_o.predicted_target = btb_target_i;
                end else if (packet_o.is_branch && bht_taken_i) begin
                    // Conditional branches only redirect when both BTB and BHT agree.
                    packet_o.predicted_taken = 1'b1;
                    packet_o.predicted_target = btb_target_i;
                end
            end
        end
    end

endmodule
