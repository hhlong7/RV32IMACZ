`timescale 1ns/1ps
/////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer: Long
//
// Create Date: 01/20/2019 10:36:50 AM
// Module Name: CSR_FILE
// Description: 
//
// Revision: 
/////////////////////////////////////////////////////////////////////////////
module CSR_FILE(
    input logic CLK,
    input logic RST,

    input logic [11:0] read_addr, // CSR address is encoded in the instruction imm[11:0] field
    output logic [31:0] read_data, // CSR read data is returned to the execute stage for use in the ALU source muxes
    input logic access_write_attempt, // True when the instruction is a CSR write (CSRxS/CSRxC/CSRxI); used to gate illegal access traps for read-only CSRs.
    output logic access_illegal, // True when the instruction is a CSR access to an unsupported CSR or an attempt to write a read-only CSR; used to trigger illegal-instruction traps in the decode stage.

    input logic write_en, // True when writing to a CSR
    input logic [11:0] write_addr, // CSR address for write operations
    input logic [31:0] write_data, // Data to write to the CSR

    // trap interface from the execute stage; used to update CSRs on trap entry/exit
    input logic trap_en,
    input logic [31:0] trap_pc,
    input logic [31:0] trap_cause,
    input logic [31:0] trap_tval,
    input logic mret_en,
    input logic timer_interrupt_pending,
    input logic external_interrupt_pending,

    // Performance counters. retire_count is 0/1/2 retired instructions from
    // the ordered dual-writeback point each cycle.
    input logic [1:0] retire_count,
    input logic branch_flush_event,
    input logic load_use_stall_event,
    input logic icache_miss_event,
    input logic dcache_miss_event,
    input logic prefetch_hit_event,
    input logic prefetch_useless_event,
    input logic trap_event,
    input logic mext_busy_event,
    input logic mext_stall_event,
    input logic storebuf_enqueue_event,
    input logic storebuf_full_stall_event,
    input logic store_to_load_forward_event,
    input logic store_conflict_stall_event,
    input logic dcache_store_drain_event,
    input logic fence_wait_event,

    // CSRs with direct architectural visibility are output for use in the execute stage
    output logic [31:0] mtvec,
    output logic [31:0] mepc,
    output logic interrupt_pending,
    output logic [31:0] interrupt_cause
);
    // Advertise the exact ISA subset this core now implements in machine mode:
    // RV32I + M + Zicsr + Zifencei.
    localparam logic [31:0] MISA_VALUE = 32'h4000_1100;

    // The full set of implemented CSRs is defined here as logic regs; 
    // the CSR read/write logic below selects among them based on the requested address.
    logic [31:0] mstatus_reg; 
    logic [31:0] mie_reg;
    logic [31:0] mtvec_reg;
    logic [31:0] mscratch_reg;
    logic [31:0] mepc_reg;
    logic [31:0] mcause_reg;
    logic [31:0] mtval_reg;
    logic [31:0] mip_reg;

    // 64-bit counters are accessed via separate 32-bit high/low CSRs
    // 11 counters for design scope, instead of 32 as RISC-V counter spec
    logic [63:0] mcycle_reg;
    logic [63:0] time_reg;
    logic [63:0] minstret_reg;
    logic [63:0] mhpmcounter3_reg;
    logic [63:0] mhpmcounter4_reg;
    logic [63:0] mhpmcounter5_reg;
    logic [63:0] mhpmcounter6_reg;
    logic [63:0] mhpmcounter7_reg;
    logic [63:0] mhpmcounter8_reg;
    logic [63:0] mhpmcounter9_reg;
    logic [63:0] mhpmcounter10_reg;
    logic [63:0] mhpmcounter11_reg;
    logic [63:0] mhpmcounter12_reg;
    logic [63:0] mhpmcounter13_reg;
    logic [63:0] mhpmcounter14_reg;
    logic [63:0] mhpmcounter15_reg;
    logic [63:0] mhpmcounter16_reg;
    logic [63:0] mhpmcounter17_reg;
    logic [31:0] mip_live;

    localparam logic [31:0] MIP_MTIP_MASK = 32'h0000_0080;
    localparam logic [31:0] MIP_MEIP_MASK = 32'h0000_0800;
    localparam logic [31:0] MIP_IRQ_MASK = MIP_MTIP_MASK | MIP_MEIP_MASK;
    localparam logic [31:0] MCAUSE_M_TIMER_INTERRUPT = 32'h8000_0007;
    localparam logic [31:0] MCAUSE_M_EXTERNAL_INTERRUPT = 32'h8000_000B;

    // Only the implemented machine CSRs are exposed; unsupported accesses are
    // treated as illegal instructions by the decode stage.
    function automatic logic csr_supported(input logic [11:0] addr);
        begin
            unique case (addr)
                12'h300, 12'h301, 12'h304, 12'h305,
                12'h340, 12'h341, 12'h342, 12'h343, 12'h344,
                12'hb00, 12'hb02, 12'hb03, 12'hb04, 12'hb05,
                12'hb06, 12'hb07, 12'hb08, 12'hb09, 12'hb0a,
                12'hb0b, 12'hb0c, 12'hb0d, 12'hb0e, 12'hb0f,
                12'hb10, 12'hb11, 12'hb80, 12'hb82, 12'hb83, 12'hb84,
                12'hb85, 12'hb86, 12'hb87, 12'hb88, 12'hb89,
                12'hb8a, 12'hb8b, 12'hb8c, 12'hb8d, 12'hb8e,
                12'hb8f, 12'hb90, 12'hb91, 12'hc00, 12'hc01, 12'hc02, 12'hc03,
                12'hc04, 12'hc05, 12'hc06, 12'hc07, 12'hc08,
                12'hc09, 12'hc0a, 12'hc0b, 12'hc0c, 12'hc0d,
                12'hc0e, 12'hc0f, 12'hc10, 12'hc11, 12'hc80, 12'hc81, 12'hc82,
                12'hc83, 12'hc84, 12'hc85, 12'hc86, 12'hc87,
                12'hc88, 12'hc89, 12'hc8a, 12'hc8b, 12'hc8c,
                12'hc8d, 12'hc8e, 12'hc8f, 12'hc90, 12'hc91, 12'hf11,
                12'hf12, 12'hf13, 12'hf14: csr_supported = 1'b1;
                default: csr_supported = 1'b0;
            endcase
        end
    endfunction

    // read-only
    function automatic logic csr_readonly(input logic [11:0] addr);
        begin
            unique case (addr)
                12'h301,
                12'hc00, 12'hc01, 12'hc02, 12'hc03, 12'hc04, 12'hc05,
                12'hc06, 12'hc07, 12'hc08, 12'hc09, 12'hc0a,
                12'hc0b, 12'hc0c, 12'hc0d, 12'hc0e, 12'hc0f,
                12'hc10, 12'hc11, 12'hc80, 12'hc81, 12'hc82, 12'hc83, 12'hc84,
                12'hc85, 12'hc86, 12'hc87, 12'hc88, 12'hc89,
                12'hc8a, 12'hc8b, 12'hc8c, 12'hc8d, 12'hc8e,
                12'hc8f, 12'hc90, 12'hc91, 12'hf11, 12'hf12, 12'hf13,
                12'hf14: csr_readonly = 1'b1;
                default: csr_readonly = 1'b0;
            endcase
        end
    endfunction

    // counter_low and counter_high functions select the appropriate 32-bit half of the requested 64-bit counter based on the CSR address; 
    // unsupported addresses return zero and are treated as illegal accesses by the decode stage.
    function automatic logic [31:0] csr_counter_low(input logic [11:0] addr);
        begin
            unique case (addr)
                12'hb00, 12'hc00: csr_counter_low = mcycle_reg[31:0];
                12'hc01: csr_counter_low = time_reg[31:0];
                12'hb02, 12'hc02: csr_counter_low = minstret_reg[31:0];
                12'hb03, 12'hc03: csr_counter_low = mhpmcounter3_reg[31:0];
                12'hb04, 12'hc04: csr_counter_low = mhpmcounter4_reg[31:0];
                12'hb05, 12'hc05: csr_counter_low = mhpmcounter5_reg[31:0];
                12'hb06, 12'hc06: csr_counter_low = mhpmcounter6_reg[31:0];
                12'hb07, 12'hc07: csr_counter_low = mhpmcounter7_reg[31:0];
                12'hb08, 12'hc08: csr_counter_low = mhpmcounter8_reg[31:0];
                12'hb09, 12'hc09: csr_counter_low = mhpmcounter9_reg[31:0];
                12'hb0a, 12'hc0a: csr_counter_low = mhpmcounter10_reg[31:0];
                12'hb0b, 12'hc0b: csr_counter_low = mhpmcounter11_reg[31:0];
                12'hb0c, 12'hc0c: csr_counter_low = mhpmcounter12_reg[31:0];
                12'hb0d, 12'hc0d: csr_counter_low = mhpmcounter13_reg[31:0];
                12'hb0e, 12'hc0e: csr_counter_low = mhpmcounter14_reg[31:0];
                12'hb0f, 12'hc0f: csr_counter_low = mhpmcounter15_reg[31:0];
                12'hb10, 12'hc10: csr_counter_low = mhpmcounter16_reg[31:0];
                12'hb11, 12'hc11: csr_counter_low = mhpmcounter17_reg[31:0];
                default: csr_counter_low = 32'b0;
            endcase
        end
    endfunction

    function automatic logic [31:0] csr_counter_high(input logic [11:0] addr);
        begin
            unique case (addr)
                12'hb80, 12'hc80: csr_counter_high = mcycle_reg[63:32];
                12'hc81: csr_counter_high = time_reg[63:32];
                12'hb82, 12'hc82: csr_counter_high = minstret_reg[63:32];
                12'hb83, 12'hc83: csr_counter_high = mhpmcounter3_reg[63:32];
                12'hb84, 12'hc84: csr_counter_high = mhpmcounter4_reg[63:32];
                12'hb85, 12'hc85: csr_counter_high = mhpmcounter5_reg[63:32];
                12'hb86, 12'hc86: csr_counter_high = mhpmcounter6_reg[63:32];
                12'hb87, 12'hc87: csr_counter_high = mhpmcounter7_reg[63:32];
                12'hb88, 12'hc88: csr_counter_high = mhpmcounter8_reg[63:32];
                12'hb89, 12'hc89: csr_counter_high = mhpmcounter9_reg[63:32];
                12'hb8a, 12'hc8a: csr_counter_high = mhpmcounter10_reg[63:32];
                12'hb8b, 12'hc8b: csr_counter_high = mhpmcounter11_reg[63:32];
                12'hb8c, 12'hc8c: csr_counter_high = mhpmcounter12_reg[63:32];
                12'hb8d, 12'hc8d: csr_counter_high = mhpmcounter13_reg[63:32];
                12'hb8e, 12'hc8e: csr_counter_high = mhpmcounter14_reg[63:32];
                12'hb8f, 12'hc8f: csr_counter_high = mhpmcounter15_reg[63:32];
                12'hb90, 12'hc90: csr_counter_high = mhpmcounter16_reg[63:32];
                12'hb91, 12'hc91: csr_counter_high = mhpmcounter17_reg[63:32];
                default: csr_counter_high = 32'b0;
            endcase
        end
    endfunction

    // mtvec and mepc are output with their lower two bits forced to zero, since the hardware ignores them and this prevents the execute stage from needing to do extra shifting/masking for alignment checks and updates.
    assign mtvec = {mtvec_reg[31:2], 2'b00};
    assign mepc = {mepc_reg[31:2], 2'b00};
    // mip_live merges the software-visible mip bits with the live external and
    // timer interrupt sources so reads always reflect the current hardware view.
    assign mip_live = (mip_reg & ~MIP_IRQ_MASK) |
                      (timer_interrupt_pending ? MIP_MTIP_MASK : 32'b0) |
                      (external_interrupt_pending ? MIP_MEIP_MASK : 32'b0);
    // The decode stage only needs a single pending flag plus the highest-priority
    // cause, so compute both here at the CSR boundary.
    assign interrupt_pending = mstatus_reg[3] &&
                               ((mie_reg[11] && mip_live[11]) ||
                                (mie_reg[7] && mip_live[7]));
    assign interrupt_cause = (mie_reg[11] && mip_live[11]) ?
                             MCAUSE_M_EXTERNAL_INTERRUPT :
                             MCAUSE_M_TIMER_INTERRUPT;
    // Read-only CSRs trap only when the instruction actually tries to modify them.
    assign access_illegal = ~csr_supported(read_addr) ||
                            (access_write_attempt && csr_readonly(read_addr));

    // CSR read data is selected from the appropriate register based on the requested address; unsupported addresses return zero and are treated as illegal accesses by the decode stage.
    always_comb begin
        unique case (read_addr)
            12'h300: read_data = mstatus_reg;
            12'h301: read_data = MISA_VALUE;
            12'h304: read_data = mie_reg;
            12'h305: read_data = mtvec_reg;
            12'h340: read_data = mscratch_reg;
            12'h341: read_data = mepc_reg;
            12'h342: read_data = mcause_reg;
            12'h343: read_data = mtval_reg;
            12'h344: read_data = mip_live;
            12'hb00, 12'hb02, 12'hb03, 12'hb04, 12'hb05,
            12'hb06, 12'hb07, 12'hb08, 12'hb09, 12'hb0a,
            12'hb0b, 12'hb0c, 12'hb0d, 12'hb0e, 12'hb0f,
            12'hb10, 12'hb11, 12'hc00, 12'hc02, 12'hc03, 12'hc04,
            12'hc05, 12'hc06, 12'hc07, 12'hc08, 12'hc09,
            12'hc0a, 12'hc0b, 12'hc0c, 12'hc0d, 12'hc0e,
            12'hc0f, 12'hc10, 12'hc11: read_data = csr_counter_low(read_addr);
            12'hb80, 12'hb82, 12'hb83, 12'hb84, 12'hb85,
            12'hb86, 12'hb87, 12'hb88, 12'hb89, 12'hb8a,
            12'hb8b, 12'hb8c, 12'hb8d, 12'hb8e, 12'hb8f,
            12'hb90, 12'hb91, 12'hc80, 12'hc82, 12'hc83, 12'hc84,
            12'hc85, 12'hc86, 12'hc87, 12'hc88, 12'hc89,
            12'hc8a, 12'hc8b, 12'hc8c, 12'hc8d, 12'hc8e,
            12'hc8f, 12'hc90, 12'hc91: read_data = csr_counter_high(read_addr);
            12'hf11, 12'hf12, 12'hf13, 12'hf14: read_data = 32'b0;
            default: read_data = 32'b0;
        endcase
    end

    always_ff @(posedge CLK) begin
        // Next-state temps let normal CSR writes, trap side effects, mret, and
        // performance-counter bumps merge into one architectural commit point.
        logic [31:0] next_mstatus;
        logic [31:0] next_mie;
        logic [31:0] next_mtvec;
        logic [31:0] next_mscratch;
        logic [31:0] next_mepc;
        logic [31:0] next_mcause;
        logic [31:0] next_mtval;
        logic [31:0] next_mip;

        logic [63:0] next_mcycle;
        logic [63:0] next_time;
        logic [63:0] next_minstret;
        logic [63:0] next_mhpmcounter3;
        logic [63:0] next_mhpmcounter4;
        logic [63:0] next_mhpmcounter5;
        logic [63:0] next_mhpmcounter6;
        logic [63:0] next_mhpmcounter7;
        logic [63:0] next_mhpmcounter8;
        logic [63:0] next_mhpmcounter9;
        logic [63:0] next_mhpmcounter10;
        logic [63:0] next_mhpmcounter11;
        logic [63:0] next_mhpmcounter12;
        logic [63:0] next_mhpmcounter13;
        logic [63:0] next_mhpmcounter14;
        logic [63:0] next_mhpmcounter15;
        logic [63:0] next_mhpmcounter16;
        logic [63:0] next_mhpmcounter17;

    // reset initialization
        if (RST) begin
            mstatus_reg <= 32'b0;
            mie_reg <= 32'b0;
            mtvec_reg <= 32'b0;
            mscratch_reg <= 32'b0;
            mepc_reg <= 32'b0;
            mcause_reg <= 32'b0;
            mtval_reg <= 32'b0;
            mip_reg <= 32'b0;

            mcycle_reg <= 64'b0;
            time_reg <= 64'b0;
            minstret_reg <= 64'b0;
            mhpmcounter3_reg <= 64'b0;
            mhpmcounter4_reg <= 64'b0;
            mhpmcounter5_reg <= 64'b0;
            mhpmcounter6_reg <= 64'b0;
            mhpmcounter7_reg <= 64'b0;
            mhpmcounter8_reg <= 64'b0;
            mhpmcounter9_reg <= 64'b0;
            mhpmcounter10_reg <= 64'b0;
            mhpmcounter11_reg <= 64'b0;
            mhpmcounter12_reg <= 64'b0;
            mhpmcounter13_reg <= 64'b0;
            mhpmcounter14_reg <= 64'b0;
            mhpmcounter15_reg <= 64'b0;
            mhpmcounter16_reg <= 64'b0;
            mhpmcounter17_reg <= 64'b0;
        end else begin
            next_mstatus = mstatus_reg;
            next_mie = mie_reg;
            next_mtvec = mtvec_reg;
            next_mscratch = mscratch_reg;
            next_mepc = mepc_reg;
            next_mcause = mcause_reg;
            next_mtval = mtval_reg;
            next_mip = mip_reg;

            // increment for next cycles
            next_mcycle = mcycle_reg; // mcycle incrementations
            next_time = time_reg; // time CSR increments as a simple architectural timer source
            next_minstret = minstret_reg; // minstret incrementations
            next_mhpmcounter3 = mhpmcounter3_reg;
            next_mhpmcounter4 = mhpmcounter4_reg;
            next_mhpmcounter5 = mhpmcounter5_reg;
            next_mhpmcounter6 = mhpmcounter6_reg;
            next_mhpmcounter7 = mhpmcounter7_reg;
            next_mhpmcounter8 = mhpmcounter8_reg;
            next_mhpmcounter9 = mhpmcounter9_reg;
            next_mhpmcounter10 = mhpmcounter10_reg;
            next_mhpmcounter11 = mhpmcounter11_reg;
            next_mhpmcounter12 = mhpmcounter12_reg;
            next_mhpmcounter13 = mhpmcounter13_reg;
            next_mhpmcounter14 = mhpmcounter14_reg;
            next_mhpmcounter15 = mhpmcounter15_reg;
            next_mhpmcounter16 = mhpmcounter16_reg;
            next_mhpmcounter17 = mhpmcounter17_reg;

            if (write_en) begin
                // Writable counters use the machine-view aliases (mcycle/minstret/mhpmcounter*).
                unique case (write_addr) // Architectural CSRs:
                // This block of code is for handling CSR write operations. 
                // When a write enable signal is asserted, the code checks the address of the CSR 
                // being written to and updates the corresponding next state variable with the 
                // provided write data. This allows the CSR file to maintain the correct values 
                // for each CSR based on write operations from instructions that modify them.
                    12'h300: next_mstatus = write_data;
                    12'h304: next_mie = write_data;
                    12'h305: next_mtvec = write_data;
                    12'h340: next_mscratch = write_data;
                    12'h341: next_mepc = {write_data[31:2], 2'b00};
                    12'h342: next_mcause = write_data;
                    12'h343: next_mtval = write_data;
                    12'h344: next_mip = write_data;
                    
                    12'hb00: next_mcycle[31:0] = write_data;
                    12'hb80: next_mcycle[63:32] = write_data;
                    12'hb02: next_minstret[31:0] = write_data;
                    12'hb82: next_minstret[63:32] = write_data;

                    12'hb03: next_mhpmcounter3[31:0] = write_data;
                    12'hb83: next_mhpmcounter3[63:32] = write_data;
                    12'hb04: next_mhpmcounter4[31:0] = write_data;
                    12'hb84: next_mhpmcounter4[63:32] = write_data;
                    12'hb05: next_mhpmcounter5[31:0] = write_data;
                    12'hb85: next_mhpmcounter5[63:32] = write_data;
                    12'hb06: next_mhpmcounter6[31:0] = write_data;
                    12'hb86: next_mhpmcounter6[63:32] = write_data;
                    12'hb07: next_mhpmcounter7[31:0] = write_data;
                    12'hb87: next_mhpmcounter7[63:32] = write_data;
                    12'hb08: next_mhpmcounter8[31:0] = write_data;
                    12'hb88: next_mhpmcounter8[63:32] = write_data;
                    12'hb09: next_mhpmcounter9[31:0] = write_data;
                    12'hb89: next_mhpmcounter9[63:32] = write_data;
                    12'hb0a: next_mhpmcounter10[31:0] = write_data;
                    12'hb8a: next_mhpmcounter10[63:32] = write_data;
                    12'hb0b: next_mhpmcounter11[31:0] = write_data;
                    12'hb8b: next_mhpmcounter11[63:32] = write_data;
                    12'hb0c: next_mhpmcounter12[31:0] = write_data;
                    12'hb8c: next_mhpmcounter12[63:32] = write_data;
                    12'hb0d: next_mhpmcounter13[31:0] = write_data;
                    12'hb8d: next_mhpmcounter13[63:32] = write_data;
                    12'hb0e: next_mhpmcounter14[31:0] = write_data;
                    12'hb8e: next_mhpmcounter14[63:32] = write_data;
                    12'hb0f: next_mhpmcounter15[31:0] = write_data;
                    12'hb8f: next_mhpmcounter15[63:32] = write_data;
                    12'hb10: next_mhpmcounter16[31:0] = write_data;
                    12'hb90: next_mhpmcounter16[63:32] = write_data;
                    12'hb11: next_mhpmcounter17[31:0] = write_data;
                    12'hb91: next_mhpmcounter17[63:32] = write_data;
                    default: ;
                endcase
            end

            if (trap_en) begin
                // Trap entry snapshots the faulting PC/cause/value and performs the
                // standard M-mode MIE->MPIE save/disable transition.
                next_mepc = {trap_pc[31:2], 2'b00};
                next_mcause = trap_cause;
                next_mtval = trap_tval;
                next_mstatus[7] = next_mstatus[3];
                next_mstatus[3] = 1'b0;
                next_mstatus[12:11] = 2'b11;
            end

            if (mret_en) begin
                // MRET restores interrupt-enable state and drops back out of handler context.
                next_mstatus[3] = next_mstatus[7];
                next_mstatus[7] = 1'b1;
                next_mstatus[12:11] = 2'b00;
            end

            next_mip[7] = timer_interrupt_pending;
            next_mip[11] = external_interrupt_pending;

            // mhpmcounter3..17 map to the requested microarchitectural events in order.
            next_mcycle = next_mcycle + 64'd1;
            next_time = next_time + 64'd1;
            // Dual-issue retirement still commits in program order, but
            // minstret must count both architecturally retired instructions.
            next_minstret = next_minstret + {62'd0, retire_count};
            if (branch_flush_event) // mhpmcounter3 counts branch mispredictions (i.e. pipeline flushes caused by control-transfer instructions)
                next_mhpmcounter3 = next_mhpmcounter3 + 64'd1;
            if (load_use_stall_event) // mhpmcounter4 counts load-use stalls (i.e. pipeline stalls caused by data hazards on load instructions) 
                next_mhpmcounter4 = next_mhpmcounter4 + 64'd1;
            if (icache_miss_event) // mhpmcounter5 counts instruction cache misses
                next_mhpmcounter5 = next_mhpmcounter5 + 64'd1;
            if (dcache_miss_event) // mhpmcounter6 counts data cache misses
                next_mhpmcounter6 = next_mhpmcounter6 + 64'd1;
            if (prefetch_hit_event) // mhpmcounter7 counts prefetch hits
                next_mhpmcounter7 = next_mhpmcounter7 + 64'd1;
            if (prefetch_useless_event) // mhpmcounter8 counts useless prefetches (i.e. prefetches that were not followed by a demand access to the same cache block within some reasonable time window)
                next_mhpmcounter8 = next_mhpmcounter8 + 64'd1;
            if (trap_event) // mhpmcounter9 counts traps taken (i.e. pipeline flushes caused by exceptions and interrupts)
                next_mhpmcounter9 = next_mhpmcounter9 + 64'd1;
            if (mext_busy_event) // mhpmcounter10 counts cycles when the multiply/divide unit is busy (i.e. multi-cycle multiply/divide instructions that are still in progress and have not yet updated the architectural register file)
                next_mhpmcounter10 = next_mhpmcounter10 + 64'd1;
            if (mext_stall_event) // mhpmcounter11 counts cycles when the multiply/divide unit is stalled waiting for a result (i.e. instructions that have issued and updated the architectural register file but are still waiting for the multi-cycle multiply/divide to complete and update the CSR file)
                next_mhpmcounter11 = next_mhpmcounter11 + 64'd1;
            // The appended counters track the new LSU behavior without
            // disturbing the older counter map used by the stage-1/2 tests.
            if (storebuf_enqueue_event) // mhpmcounter12 counts store-buffer enqueues
                next_mhpmcounter12 = next_mhpmcounter12 + 64'd1;
            if (storebuf_full_stall_event) // mhpmcounter13 counts cycles stalled on a full store buffer
                next_mhpmcounter13 = next_mhpmcounter13 + 64'd1;
            if (store_to_load_forward_event) // mhpmcounter14 counts store-to-load forwards
                next_mhpmcounter14 = next_mhpmcounter14 + 64'd1;
            if (store_conflict_stall_event) // mhpmcounter15 counts cycles blocked by unresolved store overlap
                next_mhpmcounter15 = next_mhpmcounter15 + 64'd1;
            if (dcache_store_drain_event) // mhpmcounter16 counts stores drained to memory
                next_mhpmcounter16 = next_mhpmcounter16 + 64'd1;
            if (fence_wait_event) // mhpmcounter17 counts fence wait cycles
                next_mhpmcounter17 = next_mhpmcounter17 + 64'd1;

            // update every register at the end of the cycle so that all updates happen in the same architectural commit point
            mstatus_reg <= next_mstatus;
            mie_reg <= next_mie;
            mtvec_reg <= next_mtvec;
            mscratch_reg <= next_mscratch;
            mepc_reg <= next_mepc;
            mcause_reg <= next_mcause;
            mtval_reg <= next_mtval;
            mip_reg <= next_mip;

            mcycle_reg <= next_mcycle;
            time_reg <= next_time;
            minstret_reg <= next_minstret;
            mhpmcounter3_reg <= next_mhpmcounter3;
            mhpmcounter4_reg <= next_mhpmcounter4;
            mhpmcounter5_reg <= next_mhpmcounter5;
            mhpmcounter6_reg <= next_mhpmcounter6;
            mhpmcounter7_reg <= next_mhpmcounter7;
            mhpmcounter8_reg <= next_mhpmcounter8;
            mhpmcounter9_reg <= next_mhpmcounter9;
            mhpmcounter10_reg <= next_mhpmcounter10;
            mhpmcounter11_reg <= next_mhpmcounter11;
            mhpmcounter12_reg <= next_mhpmcounter12;
            mhpmcounter13_reg <= next_mhpmcounter13;
            mhpmcounter14_reg <= next_mhpmcounter14;
            mhpmcounter15_reg <= next_mhpmcounter15;
            mhpmcounter16_reg <= next_mhpmcounter16;
            mhpmcounter17_reg <= next_mhpmcounter17;
        end
    end
endmodule
// i love cpe333
