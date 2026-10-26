`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: California Polytechnic University, San Luis Obispo
// Engineer: Long Ho
// Create Date: 02/23/2023 09:39:49 AM
// Module Name: imem
// Description:
//   64 KB instruction memory that returns a whole 32-byte cache line per read.
//   It is eight word banks (bank b holds the words whose address bits [4:2]
//   are b), each a 2048 x 32 block RAM with:
//     a synchronous read of line a[15:5]: w0..w7 hold that line from the next
//       cycle on, and line_q names the line they hold
//     a byte-enabled write mirroring data-side stores (snoop_*), so code
//       written by stores is fetched correctly after fence.i
//   Simulation loads the banks from MEM_FILE; synthesis loads bank b from
//   MEM_FILE.bank<b>.mem (tools/vivado/otter_common.tcl writes those files;
//   the .mem ending lets a Vivado project recognize them as memory files).
//////////////////////////////////////////////////////////////////////////////////
module imem #(
    parameter MEM_FILE = "Test_All.mem"
) (
    input logic CLK,
    input logic [31:0] a,               // byte address; its line is read
    input logic snoop_we,               // data-side store
    input logic [31:0] snoop_addr,
    input logic [31:0] snoop_wdata,
    input logic [1:0] snoop_size,
    output logic [26:0] line_q,         // line address of w0..w7
    output logic [31:0] w0,
    output logic [31:0] w1,
    output logic [31:0] w2,
    output logic [31:0] w3,
    output logic [31:0] w4,
    output logic [31:0] w5,
    output logic [31:0] w6,
    output logic [31:0] w7
);
    logic [10:0] read_line;
    logic [10:0] snoop_line;
    logic [2:0] snoop_bank;
    logic [3:0] byte_enable;
    logic [31:0] write_word;
    logic snoop_in_ram;

    assign read_line = a[15:5];
    assign snoop_line = snoop_addr[15:5];
    assign snoop_bank = snoop_addr[4:2];
    assign snoop_in_ram = snoop_we && (snoop_addr < 32'h0001_0000);

    // Store data arrives in the low bytes; place it in its byte lanes.
    always_comb begin
        byte_enable = 4'b0000;
        write_word = 32'b0;
        unique case ({snoop_size, snoop_addr[1:0]})
            4'b0000: begin byte_enable = 4'b0001; write_word = {24'b0, snoop_wdata[7:0]}; end
            4'b0001: begin byte_enable = 4'b0010; write_word = {16'b0, snoop_wdata[7:0], 8'b0}; end
            4'b0010: begin byte_enable = 4'b0100; write_word = {8'b0, snoop_wdata[7:0], 16'b0}; end
            4'b0011: begin byte_enable = 4'b1000; write_word = {snoop_wdata[7:0], 24'b0}; end
            4'b0100: begin byte_enable = 4'b0011; write_word = {16'b0, snoop_wdata[15:0]}; end
            4'b0101: begin byte_enable = 4'b0110; write_word = {8'b0, snoop_wdata[15:0], 8'b0}; end
            4'b0110: begin byte_enable = 4'b1100; write_word = {snoop_wdata[15:0], 16'b0}; end
            4'b1000: begin byte_enable = 4'b1111; write_word = snoop_wdata; end
            default: ;
        endcase
    end

`ifndef SYNTHESIS
    // Simulation: one linear image, dealt out to the banks below.
    logic [31:0] image [0:16383];
    initial $readmemh(MEM_FILE, image, 0, 16383);
`endif

    generate
        for (genvar b = 0; b < 8; b++) begin : g_bank
            (* ram_style = "block" *) logic [31:0] ram [0:2047];
            logic [31:0] q;                 // registered read data
`ifdef SYNTHESIS
            localparam logic [7:0] DIGIT = 8'h30 + b;
            initial $readmemh({MEM_FILE, ".bank", DIGIT, ".mem"}, ram);
`else
            initial begin
                #0;     // after the image is loaded
                for (int l = 0; l < 2048; l++)
                    ram[l] = image[l * 8 + b];
            end
`endif

            always_ff @(posedge CLK) begin
                if (snoop_in_ram && snoop_bank == 3'(b)) begin
                    for (int i = 0; i < 4; i++)
                        if (byte_enable[i])
                            ram[snoop_line][i*8 +: 8] <= write_word[i*8 +: 8];
                end
                q <= ram[read_line];
            end
        end
    endgenerate

    always_ff @(posedge CLK)
        line_q <= a[31:5];

    assign w0 = g_bank[0].q;
    assign w1 = g_bank[1].q;
    assign w2 = g_bank[2].q;
    assign w3 = g_bank[3].q;
    assign w4 = g_bank[4].q;
    assign w5 = g_bank[5].q;
    assign w6 = g_bank[6].q;
    assign w7 = g_bank[7].q;
endmodule
// i love cpe333
