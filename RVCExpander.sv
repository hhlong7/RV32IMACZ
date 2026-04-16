`timescale 1ns/1ps

module RVCExpander(
    input logic [31:0] raw_i,
    output logic [31:0] expanded_ir_o,
    output logic is_compressed_o
);

    // RVC encodes registers x8-x15 in a compact 3-bit field; rebuild the full
    // architectural register number before emitting the expanded 32-bit form.
    function automatic logic [4:0] compact_reg(input logic [2:0] reg_idx);
        begin
            compact_reg = {2'b01, reg_idx};
        end
    endfunction

    always_comb begin
        logic [15:0] cinst;
        logic illegal_c;

        cinst = raw_i[15:0];
        illegal_c = 1'b0;

        expanded_ir_o = raw_i;
        is_compressed_o = (raw_i[1:0] != 2'b11);

        if (is_compressed_o) begin
            // Expand the 16-bit RVC encoding into the equivalent 32-bit base-I
            // instruction so the existing decode / execute path can stay mostly
            // unchanged. Any unsupported or reserved pattern falls through as an
            // illegal instruction and gets trapped by the normal decoder.
            unique case (cinst[1:0])
                2'b00: begin
                    // Quadrant 0 contains stack-pointer adds plus compact
                    // load/store forms that target the x8-x15 register window.
                    unique case (cinst[15:13])
                        3'b000: begin
                            expanded_ir_o = {2'b00, cinst[10:7], cinst[12:11], cinst[5], cinst[6], 2'b00,
                                             5'd2, 3'b000, compact_reg(cinst[4:2]), 7'b0010011};
                            illegal_c = (cinst[12:5] == 8'b0);
                        end
                        3'b010: begin
                            expanded_ir_o = {5'b0, cinst[5], cinst[12:10], cinst[6], 2'b00,
                                             compact_reg(cinst[9:7]), 3'b010, compact_reg(cinst[4:2]), 7'b0000011};
                        end
                        3'b110: begin
                            expanded_ir_o = {5'b0, cinst[5], cinst[12], compact_reg(cinst[4:2]),
                                             compact_reg(cinst[9:7]), 3'b010, cinst[11:10], cinst[6], 2'b00, 7'b0100011};
                        end
                        default: illegal_c = 1'b1;
                    endcase
                end

                2'b01: begin
                    // Quadrant 1 carries immediate ALU ops plus short jumps and
                    // branches that stay in the normal control-flow path after
                    // expansion.
                    unique case (cinst[15:13])
                        3'b000: begin
                            expanded_ir_o = {{6{cinst[12]}}, cinst[12], cinst[6:2],
                                             cinst[11:7], 3'b000, cinst[11:7], 7'b0010011};
                        end
                        3'b001,
                        3'b101: begin
                            expanded_ir_o = {cinst[12], cinst[8], cinst[10:9], cinst[6], cinst[7], cinst[2],
                                             cinst[11], cinst[5:3], {9{cinst[12]}}, 4'b0, ~cinst[15], 7'b1101111};
                        end
                        3'b010: begin
                            expanded_ir_o = {{6{cinst[12]}}, cinst[12], cinst[6:2],
                                             5'd0, 3'b000, cinst[11:7], 7'b0010011};
                        end
                        3'b011: begin
                            if (cinst[11:7] == 5'd2) begin
                                expanded_ir_o = {{3{cinst[12]}}, cinst[4:3], cinst[5], cinst[2], cinst[6], 4'b0,
                                                 5'd2, 3'b000, 5'd2, 7'b0010011};
                            end else begin
                                expanded_ir_o = {{15{cinst[12]}}, cinst[6:2], cinst[11:7], 7'b0110111};
                            end
                            illegal_c = ({cinst[12], cinst[6:2]} == 6'b0);
                        end
                        3'b100: begin
                            unique case (cinst[11:10])
                                2'b00,
                                2'b01: begin
                                    expanded_ir_o = {1'b0, cinst[10], 5'b0, cinst[6:2],
                                                     compact_reg(cinst[9:7]), 3'b101, compact_reg(cinst[9:7]), 7'b0010011};
                                    illegal_c = cinst[12];
                                end
                                2'b10: begin
                                    expanded_ir_o = {{6{cinst[12]}}, cinst[12], cinst[6:2],
                                                     compact_reg(cinst[9:7]), 3'b111, compact_reg(cinst[9:7]), 7'b0010011};
                                end
                                2'b11: begin
                                    unique case ({cinst[12], cinst[6:5]})
                                        3'b000: expanded_ir_o = {7'b0100000, compact_reg(cinst[4:2]), compact_reg(cinst[9:7]),
                                                                 3'b000, compact_reg(cinst[9:7]), 7'b0110011};
                                        3'b001: expanded_ir_o = {7'b0000000, compact_reg(cinst[4:2]), compact_reg(cinst[9:7]),
                                                                 3'b100, compact_reg(cinst[9:7]), 7'b0110011};
                                        3'b010: expanded_ir_o = {7'b0000000, compact_reg(cinst[4:2]), compact_reg(cinst[9:7]),
                                                                 3'b110, compact_reg(cinst[9:7]), 7'b0110011};
                                        3'b011: expanded_ir_o = {7'b0000000, compact_reg(cinst[4:2]), compact_reg(cinst[9:7]),
                                                                 3'b111, compact_reg(cinst[9:7]), 7'b0110011};
                                        default: illegal_c = 1'b1;
                                    endcase
                                end
                                default: illegal_c = 1'b1;
                            endcase
                        end
                        3'b110,
                        3'b111: begin
                            expanded_ir_o = {{4{cinst[12]}}, cinst[6:5], cinst[2], 5'd0,
                                             compact_reg(cinst[9:7]), 2'b00, cinst[13],
                                             cinst[11:10], cinst[4:3], cinst[12], 7'b1100011};
                        end
                        default: illegal_c = 1'b1;
                    endcase
                end

                2'b10: begin
                    // Quadrant 2 covers shifts, stack-relative transfers, and
                    // jalr/jr/mv/add encodings depending on rd/rs2 presence.
                    unique case (cinst[15:13])
                        3'b000: begin
                            expanded_ir_o = {7'b0000000, cinst[6:2], cinst[11:7], 3'b001, cinst[11:7], 7'b0010011};
                            illegal_c = cinst[12];
                        end
                        3'b010: begin
                            expanded_ir_o = {4'b0, cinst[3:2], cinst[12], cinst[6:4], 2'b00,
                                             5'd2, 3'b010, cinst[11:7], 7'b0000011};
                            illegal_c = (cinst[11:7] == 5'd0);
                        end
                        3'b100: begin
                            if (~cinst[12]) begin
                                if (cinst[6:2] != 5'b0) begin
                                    expanded_ir_o = {7'b0000000, cinst[6:2], 5'd0, 3'b000, cinst[11:7], 7'b0110011};
                                end else begin
                                    expanded_ir_o = {12'b0, cinst[11:7], 3'b000, 5'd0, 7'b1100111};
                                    illegal_c = (cinst[11:7] == 5'd0);
                                end
                            end else begin
                                if (cinst[6:2] != 5'b0) begin
                                    expanded_ir_o = {7'b0000000, cinst[6:2], cinst[11:7], 3'b000, cinst[11:7], 7'b0110011};
                                end else if (cinst[11:7] == 5'd0) begin
                                    expanded_ir_o = 32'h0010_0073;
                                end else begin
                                    expanded_ir_o = {12'b0, cinst[11:7], 3'b000, 5'd1, 7'b1100111};
                                end
                            end
                        end
                        3'b110: begin
                            expanded_ir_o = {4'b0, cinst[8:7], cinst[12], cinst[6:2],
                                             5'd2, 3'b010, cinst[11:9], 2'b00, 7'b0100011};
                        end
                        default: illegal_c = 1'b1;
                    endcase
                end

                default: illegal_c = 1'b1;
            endcase

            // Unsupported compressed encodings collapse to zero so the normal
            // decode legality checks raise an illegal-instruction trap.
            if (illegal_c)
                expanded_ir_o = 32'b0;
        end
    end

endmodule