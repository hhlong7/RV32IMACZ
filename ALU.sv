`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: Cal Poly San Luis Obispo
// Engineer: Diversity
// Create Date: 02/07/2023 10:11:42 AM
// Module Name: ALU
//////////////////////////////////////////////////////////////////////////////////

module ALU(
    input logic [31:0] SRC_A,
    input logic [31:0] SRC_B,
    input logic [4:0] ALU_FUN,
    output logic [31:0] RESULT
    );

    // The upper ALU_FUN bit now distinguishes the RV32M operations from the base RV32I ones.
    logic signed [63:0] ss_product;
    logic signed [63:0] su_product;
    logic [63:0] uu_product;

    assign ss_product = $signed({{32{SRC_A[31]}}, SRC_A}) * $signed({{32{SRC_B[31]}}, SRC_B});
    assign su_product = $signed({{32{SRC_A[31]}}, SRC_A}) * $signed({32'b0, SRC_B});
    assign uu_product = {32'b0, SRC_A} * {32'b0, SRC_B};

    // ALU_FUN determines which operation is carried out with the operands A and B.
    always_comb begin
        case(ALU_FUN)
            5'b00000: RESULT = SRC_A + SRC_B; // add
            5'b01000: RESULT = SRC_A - SRC_B; // sub

            // logic
            5'b00110: RESULT = SRC_A | SRC_B; // or
            5'b00111: RESULT = SRC_A & SRC_B; // and
            5'b00100: RESULT = SRC_A ^ SRC_B; // xor

            // shifting
            5'b00101: RESULT = SRC_A >> SRC_B[4:0]; // srl
            5'b00001: RESULT = SRC_A << SRC_B[4:0]; // sll
            5'b01101: RESULT = $signed(SRC_A) >>> SRC_B[4:0]; // sra

            // setting
            5'b00010: RESULT = ($signed(SRC_A) < $signed(SRC_B)) ? 32'd1 : 32'd0; // slt
            5'b00011: RESULT = (SRC_A < SRC_B) ? 32'd1 : 32'd0; // sltu

            // copy
            5'b01001: RESULT = SRC_A; // lui-copy

            // RV32M multiply/divide
            5'b10000: RESULT = ss_product[31:0];  // mul
            5'b10001: RESULT = ss_product[63:32]; // mulh
            5'b10010: RESULT = su_product[63:32]; // mulhsu
            5'b10011: RESULT = uu_product[63:32]; // mulhu

            5'b10100: begin // div
                if (SRC_B == 32'b0)
                    RESULT = 32'hFFFF_FFFF;
                else if ((SRC_A == 32'h8000_0000) && (SRC_B == 32'hFFFF_FFFF))
                    RESULT = 32'h8000_0000;
                else
                    RESULT = $signed(SRC_A) / $signed(SRC_B);
            end

            5'b10101: begin // divu
                if (SRC_B == 32'b0)
                    RESULT = 32'hFFFF_FFFF;
                else
                    RESULT = SRC_A / SRC_B;
            end

            5'b10110: begin // rem
                if (SRC_B == 32'b0)
                    RESULT = SRC_A;
                else if ((SRC_A == 32'h8000_0000) && (SRC_B == 32'hFFFF_FFFF))
                    RESULT = 32'b0;
                else
                    RESULT = $signed(SRC_A) % $signed(SRC_B);
            end

            5'b10111: begin // remu
                if (SRC_B == 32'b0)
                    RESULT = SRC_A;
                else
                    RESULT = SRC_A % SRC_B;
            end

            default: RESULT = 32'd0;
        endcase
    end
endmodule
