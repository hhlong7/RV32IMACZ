`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer: J. Callenes, P. Hummel
//
// Create Date: 01/27/2019 08:37:11 AM
// Module Name: OTTER_mem
// Project Name: Memory for OTTER RV32I RISC-V
// Description: 64 KB data memory plus the memory-mapped IO block.
//              One port: a synchronous read (data on the next cycle) and a
//              byte-enabled write, the shape of a Xilinx block RAM, so the
//              same RTL simulates and builds on an FPGA.
//              MEM_ADDR2 is a byte address. Addresses at or above 0x10000
//              are memory-mapped IO (OTTER_MMIO: CLINT timer, IO bus).
//              MEM_SIZE selects byte (0), half (1), or word (2); MEM_SIGN
//              selects unsigned (1) or signed (0) extension of loads.
//              Atomics run in the load/store unit as an ordinary read
//              followed by an ordinary write through this port.
//              IO reads must not have side effects: the core may issue a
//              load speculatively and then discard it.
//
// Revision:
// Revision 0.01 - Original by J. Callenes
// Revision 1.02 - Rewrite to simplify logic by P. Hummel
// Revision 1.03 - changed signal names, added instantiation template
// Revision 1.04 - added defualt to write case statement
// Revision 1.05 - changed MEM_WD to MEM_DIN2, changed default to save nothing
// Revision 1.06 - removed typo in instantiation template
// Revision 1.07 - remove unused wordAddr1 signal
// Revision 1.08 - one block-RAM port; atomics moved to the LSU
//
//////////////////////////////////////////////////////////////////////////////////

module Memory #(
    parameter MEM_FILE = "Test_All.mem"   // initial contents ($readmemh)
) (
    input MEM_RST,
    input MEM_CLK,
    input MEM_RDEN2,        // read enable
    input MEM_WE2,          // write enable
    input [31:0] MEM_ADDR2, // byte address
    input [31:0] MEM_DIN2,  // store data (low bytes)
    input [1:0] MEM_SIZE,   // 0-Byte, 1-Half, 2-Word
    input MEM_SIGN,         // 1-unsigned 0-signed
    input [31:0] IO_IN,     // data from IO
    output logic IO_WR,     // IO write strobe
    output logic [31:0] MEM_DOUT2,
    output logic MEM_TIMER_INTERRUPT
);
    import otter_defs_pkg::*;

    logic [13:0] wordAddr2;
    logic [1:0] byteOffset;
    logic [31:0] memReadWord, memReadSized;
    logic [31:0] mmioReadData;
    logic mmioSel;
    logic [3:0] byteEnable;
    logic [31:0] writeWord;

    (* ram_style = "block" *) logic [31:0] memory [0:16383];

    initial begin
        $readmemh(MEM_FILE, memory, 0, 16383);
    end

    assign wordAddr2 = MEM_ADDR2[15:2];
    assign byteOffset = MEM_ADDR2[1:0];

    // Keep all timer and external-MMIO policy in a side module so this block
    // only holds the RAM.
    OTTER_MMIO MMIO_BLOCK(
      .CLK(MEM_CLK),
      .RST(MEM_RST),
      .RDEN2(MEM_RDEN2),
      .WE2(MEM_WE2),
      .ADDR2(MEM_ADDR2),
      .DIN2(MEM_DIN2),
      .SIZE(MEM_SIZE),
      .IO_IN(IO_IN),
      .MMIO_SEL(mmioSel),
      .IO_WR(IO_WR),
      .DOUT2(mmioReadData),
      .TIMER_INTERRUPT(MEM_TIMER_INTERRUPT)
    );

    // Store data arrives in the low bytes; place it in its byte lanes.
    always_comb begin
      byteEnable = 4'b0000;
      writeWord = 32'b0;
      case ({MEM_SIZE, byteOffset})
        4'b0000: begin byteEnable = 4'b0001; writeWord = {24'b0, MEM_DIN2[7:0]}; end
        4'b0001: begin byteEnable = 4'b0010; writeWord = {16'b0, MEM_DIN2[7:0], 8'b0}; end
        4'b0010: begin byteEnable = 4'b0100; writeWord = {8'b0, MEM_DIN2[7:0], 16'b0}; end
        4'b0011: begin byteEnable = 4'b1000; writeWord = {MEM_DIN2[7:0], 24'b0}; end
        4'b0100: begin byteEnable = 4'b0011; writeWord = {16'b0, MEM_DIN2[15:0]}; end
        4'b0101: begin byteEnable = 4'b0110; writeWord = {8'b0, MEM_DIN2[15:0], 8'b0}; end
        4'b0110: begin byteEnable = 4'b1100; writeWord = {MEM_DIN2[15:0], 16'b0}; end
        4'b1000: begin byteEnable = 4'b1111; writeWord = MEM_DIN2; end
        default: ;  // unsupported size/offset: write nothing
      endcase
    end

    // Block RAM: byte-enabled write, read-first synchronous read.
    always_ff @(posedge MEM_CLK) begin
      if (MEM_WE2 && ~mmioSel) begin
        for (int i = 0; i < 4; i++)
          if (byteEnable[i])
            memory[wordAddr2][i*8 +: 8] <= writeWord[i*8 +: 8];
      end
      if (MEM_RDEN2 && ~mmioSel)
        memReadWord <= memory[wordAddr2];
    end

    // Change the data word into sized bytes and sign extend
    always_comb begin
      case({MEM_SIGN,MEM_SIZE,byteOffset})
        5'b00011: memReadSized = {{24{memReadWord[31]}},memReadWord[31:24]};  // signed byte
        5'b00010: memReadSized = {{24{memReadWord[23]}},memReadWord[23:16]};
        5'b00001: memReadSized = {{24{memReadWord[15]}},memReadWord[15:8]};
        5'b00000: memReadSized = {{24{memReadWord[7]}},memReadWord[7:0]};

        5'b00110: memReadSized = {{16{memReadWord[31]}},memReadWord[31:16]};  // signed half
        5'b00101: memReadSized = {{16{memReadWord[23]}},memReadWord[23:8]};
        5'b00100: memReadSized = {{16{memReadWord[15]}},memReadWord[15:0]};

        5'b01000: memReadSized = memReadWord;                   // word

        5'b10011: memReadSized = {24'd0,memReadWord[31:24]};    // unsigned byte
        5'b10010: memReadSized = {24'd0,memReadWord[23:16]};
        5'b10001: memReadSized = {24'd0,memReadWord[15:8]};
        5'b10000: memReadSized = {24'd0,memReadWord[7:0]};

        5'b10110: memReadSized = {16'd0,memReadWord[31:16]};    // unsigned half
        5'b10101: memReadSized = {16'd0,memReadWord[23:8]};
        5'b10100: memReadSized = {16'd0,memReadWord[15:0]};

        default:  memReadSized = 32'b0;     // unsupported size, byte offset combination
      endcase
    end

    assign MEM_DOUT2 = mmioSel ? mmioReadData : memReadSized;
endmodule
// i love cpe333
