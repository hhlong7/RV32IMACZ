`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer: J. Callenes, P. Hummel
//
// Create Date: 01/27/2019 08:37:11 AM
// Module Name: OTTER_mem
// Project Name: Memory for OTTER RV32I RISC-V
// Tool Versions: Xilinx Vivado 2019.2
// Description: 64k Memory, dual access read single access write. Designed to
//              purposely utilize BRAM which requires synchronous reads and write
//              ADDR1 used for Program Memory Instruction. Word addressable so it
//              must be adapted from byte addresses in connection from PC
//              ADDR2 used for data access, both internal and external memory
//              mapped IO. ADDR2 is byte addressable.
//              RDEN1 and EDEN2 are read enables for ADDR1 and ADDR2. These are
//              needed due to synchronous reading
//              MEM_SIZE used to specify reads as byte (0), half (1), or word (2)
//              MEM_SIGN used to specify unsigned (1) vs signed (0) extension
//              IO_IN is data from external IO and synchronously buffered
//
// Memory OTTER_MEMORY (
//    .MEM_CLK   (),
//    .MEM_RDEN1 (),
//    .MEM_RDEN2 (),
//    .MEM_WE2   (),
//    .MEM_ADDR1 (),
//    .MEM_ADDR2 (),
//    .MEM_DIN2  (),
//    .MEM_SIZE  (),
//    .MEM_SIGN  (),
//    .IO_IN     (),
//    .IO_WR     (),
//    .MEM_DOUT1 (),
//    .MEM_DOUT2 ()  );
//
// Revision:
// Revision 0.01 - Original by J. Callenes
// Revision 1.02 - Rewrite to simplify logic by P. Hummel
// Revision 1.03 - changed signal names, added instantiation template
// Revision 1.04 - added defualt to write case statement
// Revision 1.05 - changed MEM_WD to MEM_DIN2, changed default to save nothing
// Revision 1.06 - removed typo in instantiation template
// Revision 1.07 - remove unused wordAddr1 signal
//
//////////////////////////////////////////////////////////////////////////////////
                                                                                                                             
  module Memory (
    input MEM_RST,
    input MEM_CLK,
    input MEM_RDEN1,        // read enable Instruction
    input MEM_RDEN2,        // read enable data
    input MEM_WE2,          // write enable.
    input [13:0] MEM_ADDR1, // Instruction Memory word Addr (Connect to PC[15:2])
    input [31:0] MEM_ADDR2, // Data Memory Addr
    input [31:0] MEM_DIN2,  // Data to save
    input [1:0] MEM_SIZE,   // 0-Byte, 1-Half, 2-Word
    input MEM_SIGN,         // 1-unsigned 0-signed
    input MEM_ATOMIC_VALID, // atomic LSU request
    input [3:0] MEM_ATOMIC_OP, // encoded LR/SC/AMO operation
    input MEM_ATOMIC_SC_OK, // reservation match for SC
    input [31:0] MEM_ATOMIC_ADDR, // atomic word address
    input [31:0] MEM_ATOMIC_DIN,  // atomic source operand / SC store word
    input [31:0] MEM_ATOMIC_PREVIEW_ADDR, // one-cycle-early preview for forwarding
    input [31:0] IO_IN,     // Data from IO
    //output ERR,           // only used for testing
    output logic IO_WR,     // IO 1-write 0-read
    output logic [31:0] MEM_DOUT1,  // Instruction
    output logic [31:0] MEM_DOUT2, // Data
    output logic [31:0] MEM_ATOMIC_PREVIEW_WORD,
    output logic [31:0] MEM_ATOMIC_RESULT,
    output logic MEM_ATOMIC_COMMIT_VALID,
    output logic MEM_ATOMIC_COMMIT_WRITE,
    output logic [3:0] MEM_ATOMIC_COMMIT_OP,
    output logic MEM_ATOMIC_COMMIT_SC_SUCCESS,
    output logic [31:0] MEM_ATOMIC_COMMIT_ADDR,
    output logic [31:0] MEM_ATOMIC_COMMIT_OLD_WORD,
    output logic [31:0] MEM_ATOMIC_COMMIT_NEW_WORD,
    output logic MEM_TIMER_INTERRUPT);

    import otter_defs_pkg::*;
    
    logic [13:0] wordAddr2;
    logic [13:0] atomicWordAddr;
    logic [31:0] memReadWord, memReadSized;
    logic [31:0] atomicReadWord;
    logic [31:0] mmioReadData;
    logic [1:0] byteOffset;
    logic weAddrValid;      // active when saving (WE) to valid memory address
    logic mmioSel;
       
    (* rom_style="{distributed | block}" *)
    (* ram_decomp = "power" *) logic [31:0] memory [0:16383];
    
    initial begin
        $readmemh("Test_All.mem", memory, 0, 16383);
    end
    
    assign wordAddr2 = MEM_ADDR2[15:2];
    assign atomicWordAddr = MEM_ATOMIC_ADDR[15:2];
    assign byteOffset = MEM_ADDR2[1:0];     // byte offset of memory address
    assign atomicReadWord = memory[atomicWordAddr];
    assign MEM_ATOMIC_PREVIEW_WORD = memory[MEM_ATOMIC_PREVIEW_ADDR[15:2]];

    // Keep all timer and external-MMIO policy in a side module so this block
    // only arbitrates BRAM accesses and atomic commits.
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
         
    // NOT USED IN OTTER
    //Check for misalligned or out of bounds memory accesses
    //assign ERR = ((MEM_ADDR1 >= 2**ACTUAL_WIDTH)|| (MEM_ADDR2 >= 2**ACTUAL_WIDTH)
    //                || MEM_ADDR1[1:0] != 2'b0 || MEM_ADDR2[1:0] !=2'b0)? 1 : 0;
            
    // BRAM requires all reads and writes to occur synchronously
    always_ff @(negedge MEM_CLK) begin
      logic [31:0] oldAtomicWord;
      logic [31:0] newAtomicWord;
      logic atomicDoWrite;

      if (MEM_RST) begin
        // Reset only clears the synchronous output state; the backing BRAM is
        // still initialized from Test_All.mem through the module initial block.
        memReadWord <= 32'b0;
        MEM_DOUT1 <= 32'b0;
        MEM_ATOMIC_COMMIT_VALID <= 1'b0;
        MEM_ATOMIC_COMMIT_WRITE <= 1'b0;
        MEM_ATOMIC_COMMIT_OP <= 4'b0;
        MEM_ATOMIC_COMMIT_SC_SUCCESS <= 1'b0;
        MEM_ATOMIC_COMMIT_ADDR <= 32'b0;
        MEM_ATOMIC_COMMIT_OLD_WORD <= 32'b0;
        MEM_ATOMIC_COMMIT_NEW_WORD <= 32'b0;
      end else begin
        // save data (WD) to memory (ADDR2)
        if (weAddrValid == 1) begin     // write enable and valid address space
          case({MEM_SIZE,byteOffset})
              4'b0000: memory[wordAddr2][7:0]   <= MEM_DIN2[7:0];     // sb at byte offsets
              4'b0001: memory[wordAddr2][15:8]  <= MEM_DIN2[7:0];
              4'b0010: memory[wordAddr2][23:16] <= MEM_DIN2[7:0];
              4'b0011: memory[wordAddr2][31:24] <= MEM_DIN2[7:0];
              4'b0100: memory[wordAddr2][15:0]  <= MEM_DIN2[15:0];    // sh at byte offsets
              4'b0101: memory[wordAddr2][23:8]  <= MEM_DIN2[15:0];
              4'b0110: memory[wordAddr2][31:16] <= MEM_DIN2[15:0];
              4'b1000: memory[wordAddr2]        <= MEM_DIN2;          // sw
  		        //default: memory[wordAddr2]      <= 32'b0   // unsupported size, byte offset
  		        // removed to avoid mistakes causing memory to be zeroed.
          endcase
        end

          // BRAM reads are synchronous, so both instruction fetch and data load
          // return on the following cycle.
          if (MEM_RDEN1)                       // need EN for extra load cycle to not change instruction
          MEM_DOUT1 <= memory[MEM_ADDR1];

          if (MEM_RDEN2 && ~mmioSel) begin          // Read word from memory only
          memReadWord <= memory[wordAddr2];
        end

        MEM_ATOMIC_COMMIT_VALID <= 1'b0;
        MEM_ATOMIC_COMMIT_WRITE <= 1'b0;
        MEM_ATOMIC_COMMIT_OP <= MEM_ATOMIC_OP;
        MEM_ATOMIC_COMMIT_SC_SUCCESS <= 1'b0;

        if (MEM_ATOMIC_VALID) begin
          if (MEM_RDEN2 || MEM_WE2)
            $fatal(1, "atomic request overlapped the normal data-memory port");
          if (MEM_ATOMIC_ADDR[1:0] != 2'b00)
            $fatal(1, "misaligned atomic word access at 0x%08x", MEM_ATOMIC_ADDR);
          if (MEM_ATOMIC_ADDR >= 32'h00010000)
            $fatal(1, "atomic access to unsupported MMIO address 0x%08x", MEM_ATOMIC_ADDR);

          oldAtomicWord = memory[atomicWordAddr];
          newAtomicWord = atomic_new_word(MEM_ATOMIC_OP, oldAtomicWord, MEM_ATOMIC_DIN);
          atomicDoWrite = atomic_op_writes(MEM_ATOMIC_OP, MEM_ATOMIC_SC_OK);

          if (atomicDoWrite)
            memory[atomicWordAddr] <= newAtomicWord;

          MEM_ATOMIC_COMMIT_VALID <= 1'b1;
          MEM_ATOMIC_COMMIT_WRITE <= atomicDoWrite;
          MEM_ATOMIC_COMMIT_OP <= MEM_ATOMIC_OP;
          MEM_ATOMIC_COMMIT_SC_SUCCESS <= (MEM_ATOMIC_OP == ATOMIC_SC) && atomicDoWrite;
          MEM_ATOMIC_COMMIT_ADDR <= MEM_ATOMIC_ADDR;
          MEM_ATOMIC_COMMIT_OLD_WORD <= oldAtomicWord;
          MEM_ATOMIC_COMMIT_NEW_WORD <= newAtomicWord;
        end
      end
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

    // Atomics reuse the same backing array but return the old word
    // combinationally so the existing ex_mem forwarding path still sees the
    // result in the same cycle as other single-cycle memory operations.
    always_comb begin
      MEM_ATOMIC_RESULT = 32'b0;

      if (MEM_ATOMIC_VALID)
        MEM_ATOMIC_RESULT = atomic_result_word(MEM_ATOMIC_OP, atomicReadWord, MEM_ATOMIC_SC_OK);
    end
 
    // Memory Mapped IO
    always_comb begin
      if(mmioSel) begin                    // external address range
        MEM_DOUT2 = mmioReadData;          // IO or timer read buffer
        weAddrValid = 0;                 // address beyond memory range
      end
      else begin
        MEM_DOUT2 = memReadSized;   // output sized and sign extended data
        weAddrValid = MEM_WE2;      // address in valid memory range
      end
    end
        
 endmodule
 // i love cpe333
