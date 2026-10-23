`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Stand-ins for the simulation memory models, for synthesizing and
// implementing the core (OTTER_MCU) on an FPGA flow without its memory.
//
// Memory (otter_memory_v1_07.sv) and imem (imem.sv) model the external RAM:
// 64 KB each, with more ports than FPGA block RAM supports (Memory reads four
// words and writes one per cycle; imem returns a whole 8-word cache line at
// once). Vivado cannot map them (Synth 8-3391), so a core-only estimate uses
// these port-for-port stand-ins instead.
//
// They are not empty black boxes because place and route rejects those
// (DRC INBB-3). Each one registers its ports the way a synchronous block RAM
// would: every input feeds a flip-flop (all inputs are XORed into one bit,
// so the core logic that drives them is kept), and every output comes from
// its own flip-flop in a shift register (so no two outputs are equal and
// synthesis cannot simplify the logic that reads them). Timing therefore
// covers core-to-memory and memory-to-core paths up to a register at the
// memory port. They cost a few hundred flip-flops and hold no data; a board
// build needs real block RAM or a DRAM controller behind the caches.
//
// Keep the ports identical to the real modules.
//////////////////////////////////////////////////////////////////////////////////

module Memory (
    input MEM_RST,
    input MEM_CLK,
    input MEM_RDEN1,
    input MEM_RDEN2,
    input MEM_WE2,
    input [13:0] MEM_ADDR1,
    input [31:0] MEM_ADDR2,
    input [31:0] MEM_DIN2,
    input [1:0] MEM_SIZE,
    input MEM_SIGN,
    input MEM_ATOMIC_VALID,
    input [3:0] MEM_ATOMIC_OP,
    input MEM_ATOMIC_SC_OK,
    input [31:0] MEM_ATOMIC_ADDR,
    input [31:0] MEM_ATOMIC_DIN,
    input [31:0] MEM_ATOMIC_PREVIEW_ADDR,
    input [31:0] IO_IN,
    output logic IO_WR,
    output logic [31:0] MEM_DOUT1,
    output logic [31:0] MEM_DOUT2,
    output logic [31:0] MEM_ATOMIC_PREVIEW_WORD,
    output logic [31:0] MEM_ATOMIC_RESULT,
    output logic MEM_ATOMIC_COMMIT_VALID,
    output logic MEM_ATOMIC_COMMIT_WRITE,
    output logic [3:0] MEM_ATOMIC_COMMIT_OP,
    output logic MEM_ATOMIC_COMMIT_SC_SUCCESS,
    output logic [31:0] MEM_ATOMIC_COMMIT_ADDR,
    output logic [31:0] MEM_ATOMIC_COMMIT_OLD_WORD,
    output logic [31:0] MEM_ATOMIC_COMMIT_NEW_WORD,
    output logic MEM_TIMER_INTERRUPT
);
    (* shreg_extract = "no" *) logic [232:0] port_q;
    always_ff @(posedge MEM_CLK)
        port_q <= {port_q[231:0], ^{MEM_RST, MEM_RDEN1, MEM_RDEN2, MEM_WE2, MEM_ADDR1, MEM_ADDR2, MEM_DIN2, MEM_SIZE, MEM_SIGN, MEM_ATOMIC_VALID, MEM_ATOMIC_OP, MEM_ATOMIC_SC_OK, MEM_ATOMIC_ADDR, MEM_ATOMIC_DIN, MEM_ATOMIC_PREVIEW_ADDR, IO_IN}};
    assign {IO_WR, MEM_DOUT1, MEM_DOUT2, MEM_ATOMIC_PREVIEW_WORD, MEM_ATOMIC_RESULT, MEM_ATOMIC_COMMIT_VALID, MEM_ATOMIC_COMMIT_WRITE, MEM_ATOMIC_COMMIT_OP, MEM_ATOMIC_COMMIT_SC_SUCCESS, MEM_ATOMIC_COMMIT_ADDR, MEM_ATOMIC_COMMIT_OLD_WORD, MEM_ATOMIC_COMMIT_NEW_WORD, MEM_TIMER_INTERRUPT} = port_q;
endmodule

module imem (
    input logic CLK,
    input logic [31:0] a,
    input logic snoop_we,
    input logic [31:0] snoop_addr,
    input logic [31:0] snoop_wdata,
    input logic [1:0] snoop_size,
    input logic atomic_valid,
    input logic [3:0] atomic_op,
    input logic atomic_sc_ok,
    input logic [31:0] atomic_addr,
    input logic [31:0] atomic_wdata,
    output logic [31:0] w0,
    output logic [31:0] w1,
    output logic [31:0] w2,
    output logic [31:0] w3,
    output logic [31:0] w4,
    output logic [31:0] w5,
    output logic [31:0] w6,
    output logic [31:0] w7
);
    (* shreg_extract = "no" *) logic [255:0] port_q;
    always_ff @(posedge CLK)
        port_q <= {port_q[254:0], ^{a, snoop_we, snoop_addr, snoop_wdata, snoop_size, atomic_valid, atomic_op, atomic_sc_ok, atomic_addr, atomic_wdata}};
    assign {w0, w1, w2, w3, w4, w5, w6, w7} = port_q;
endmodule
