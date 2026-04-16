`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: California Polytechnic University, San Luis Obispo
// Engineer: Long Ho
// Create Date: 02/23/2023 09:39:49 AM
// Module Name: imem
//////////////////////////////////////////////////////////////////////////////////
module imem(
    input logic CLK,
    input logic [31:0] a, // address from ex_mem for snooping
    input logic snoop_we, // write enable for snooping (data-side stores)
    input logic [31:0] snoop_addr, // address for snooping (data-side stores)
    input logic [31:0] snoop_wdata, // write data for snooping (data-side stores)
    input logic [1:0] snoop_size, // size for snooping (data-side stores) 
    input logic atomic_valid, // atomic write intent from the LSU
    input logic [3:0] atomic_op,
    input logic atomic_sc_ok,
    input logic [31:0] atomic_addr,
    input logic [31:0] atomic_wdata,
    output logic [31:0] w0, // word-aligned instruction outputs for the addressed block
    output logic [31:0] w1,
    output logic [31:0] w2,
    output logic [31:0] w3,
    output logic [31:0] w4,
    output logic [31:0] w5,
    output logic [31:0] w6,
    output logic [31:0] w7
);

    import otter_defs_pkg::*;

    // 64KB instruction RAM, word-addressable for simplicity (256K total bytes).
    logic [31:0] ram[0:16383];
    logic [29:0] addr; // word-aligned address (ignore bottom 2 bits since instructions are 4 bytes)
    logic [13:0] snoop_word_addr; // word-aligned address for snooping (ignore bottom 2 bits since instructions are 4 bytes)
    logic [1:0] snoop_byte_offset; // byte offset within the word for snooping
    logic [13:0] atomic_word_addr; // word-aligned address for mirrored atomic writes

    // The I$ reads whole 8-word aligned blocks at a time for fills and next-line prefetch.
    assign addr = {a[31:5], 3'b000};
    assign snoop_word_addr = snoop_addr[15:2];
    assign snoop_byte_offset = snoop_addr[1:0];
    assign atomic_word_addr = atomic_addr[15:2];

    initial $readmemh("Test_All.mem", ram, 0, 16383);

    assign w0 = ram[addr+0];
    assign w1 = ram[addr+1];
    assign w2 = ram[addr+2];
    assign w3 = ram[addr+3];
    assign w4 = ram[addr+4];
    assign w5 = ram[addr+5];
    assign w6 = ram[addr+6];
    assign w7 = ram[addr+7];

    always_ff @(negedge CLK) begin
        logic [31:0] old_atomic_word;
        logic [31:0] new_atomic_word;
        logic atomic_do_write;

        // Mirror data-side stores into the backing instruction RAM so self-modifying
        // code becomes visible after fence.i invalidates stale I$ contents.
        if (snoop_we && (snoop_addr < 32'h0001_0000)) begin
            unique case ({snoop_size, snoop_byte_offset}) // handle byte, halfword, and word stores
                4'b0000: ram[snoop_word_addr][7:0] <= snoop_wdata[7:0];
                4'b0001: ram[snoop_word_addr][15:8] <= snoop_wdata[7:0];
                4'b0010: ram[snoop_word_addr][23:16] <= snoop_wdata[7:0];
                4'b0011: ram[snoop_word_addr][31:24] <= snoop_wdata[7:0];
                4'b0100: ram[snoop_word_addr][15:0] <= snoop_wdata[15:0];
                4'b0101: ram[snoop_word_addr][23:8] <= snoop_wdata[15:0];
                4'b0110: ram[snoop_word_addr][31:16] <= snoop_wdata[15:0];
                4'b1000: ram[snoop_word_addr] <= snoop_wdata;
                default: ;
            endcase
        end

        if (atomic_valid && (atomic_addr < 32'h0001_0000)) begin
            if (atomic_addr[1:0] != 2'b00)
                $fatal(1, "imem atomic mirror saw misaligned word address 0x%08x", atomic_addr);

            old_atomic_word = ram[atomic_word_addr];
            new_atomic_word = atomic_new_word(atomic_op, old_atomic_word, atomic_wdata);
            atomic_do_write = atomic_op_writes(atomic_op, atomic_sc_ok);

            if (atomic_do_write)
                ram[atomic_word_addr] <= new_atomic_word;
        end
    end
endmodule
// i love cpe333
