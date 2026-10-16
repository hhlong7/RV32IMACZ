`timescale 1ns/1ps
/////////////////////////////////////////////////////////////////////////////
// Engineer: Long
// Module Name: CSR_FILE
// Description: Machine-mode CSRs, trap entry/exit state, and the 64-bit
//              performance counters for an M-only RV32IMAC hart.
//
// Implemented CSRs
//   fflags   0x001   accrued FP exception flags {NV, DZ, OF, UF, NX}
//   frm      0x002   FP rounding mode
//   fcsr     0x003   {frm, fflags}; FP CSRs trap while mstatus.FS is Off
//   mstatus  0x300   MIE, MPIE, and FS writable; MPP reads as M (M-only
//                    hart); SD reads as 1 when FS is Dirty
//   misa     0x301   RV32IMAFC (F: the supported single-precision subset);
//                    writes are ignored (WARL)
//   mie      0x304   MTIE and MEIE writable
//   mtvec    0x305   direct mode only (MODE is read-only zero)
//   mscratch 0x340
//   mepc     0x341   bit 0 is always zero (IALIGN=16 with RVC)
//   mcause   0x342
//   mtval    0x343
//   mip      0x344   read-only view of the live MTIP/MEIP sources
//   mcycle / minstret / mhpmcounter3..17   0xB00..0xB11 (+0x80: high half)
//   cycle / time / instret / hpmcounter3..17  0xC00..0xC11 (read-only)
//   mvendorid / marchid / mimpid / mhartid 0xF11..0xF14 (read as zero)
//
// mhpmcounterN counts event N below (see hpm_event).
/////////////////////////////////////////////////////////////////////////////
module CSR_FILE(
    input logic CLK,
    input logic RST,

    // Decode-time read port. access_illegal flags unsupported CSRs and writes
    // to read-only CSRs so decode can raise an illegal-instruction trap.
    input logic [11:0] read_addr,
    output logic [31:0] read_data,
    input logic access_write_attempt,
    output logic access_illegal,

    // Writeback-time write port.
    input logic write_en,
    input logic [11:0] write_addr,
    input logic [31:0] write_data,

    // Trap entry and MRET from EX1.
    input logic trap_en,
    input logic [31:0] trap_pc,
    input logic [31:0] trap_cause,
    input logic [31:0] trap_tval,
    input logic mret_en,
    input logic timer_interrupt_pending,
    input logic external_interrupt_pending,

    // Performance events. retire_count is 0/1/2 instructions retired by the
    // ordered dual-writeback point this cycle.
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

    // Floating-point state. fp_dirty marks mstatus.FS Dirty (an FP register
    // is being written); fflags_accrue ORs a retiring FP op's flags in.
    input logic fp_dirty,
    input logic fflags_accrue,
    input logic [4:0] fflags_new,
    output logic [2:0] frm,
    output logic [1:0] fs,

    output logic [31:0] mtvec,
    output logic [31:0] mepc,
    output logic interrupt_pending,
    output logic [31:0] interrupt_cause
);
    // MXL=1 (32-bit) | M | I | F | C | A
    localparam logic [31:0] MISA_VALUE = 32'h4000_1125;

    localparam int MSTATUS_MIE = 3;
    localparam int MSTATUS_MPIE = 7;
    localparam logic [31:0] MSTATUS_MPP_M = 32'h0000_1800;
    localparam logic [31:0] MSTATUS_WRITABLE = 32'h0000_6088;   // FS, MPIE, MIE
    localparam int MSTATUS_FS_LO = 13;
    localparam logic [1:0] FS_DIRTY = 2'b11;

    localparam int MIP_MTIP = 7;
    localparam int MIP_MEIP = 11;
    localparam logic [31:0] MIE_WRITABLE = 32'h0000_0880;
    localparam logic [31:0] MCAUSE_M_TIMER_INTERRUPT = 32'h8000_0007;
    localparam logic [31:0] MCAUSE_M_EXTERNAL_INTERRUPT = 32'h8000_000B;

    // Counter index space shared by the machine (0xB..) and user (0xC..)
    // views: 0 = cycle, 1 = time (user view only), 2 = instret, 3..17 = hpm.
    localparam int FIRST_HPM = 3;
    localparam int LAST_COUNTER = 17;

    logic [31:0] mstatus_reg;
    logic [31:0] mie_reg;
    logic [31:0] mtvec_reg;
    logic [31:0] mscratch_reg;
    logic [31:0] mepc_reg;
    logic [31:0] mcause_reg;
    logic [31:0] mtval_reg;
    logic [31:0] mip_live;
    logic [4:0] fflags_reg;
    logic [2:0] frm_reg;

    logic [63:0] counters [0:LAST_COUNTER];
    logic [LAST_COUNTER:FIRST_HPM] hpm_event;

    assign hpm_event = {
        fence_wait_event,             // 17
        dcache_store_drain_event,     // 16
        store_conflict_stall_event,   // 15
        store_to_load_forward_event,  // 14
        storebuf_full_stall_event,    // 13
        storebuf_enqueue_event,       // 12
        mext_stall_event,             // 11
        mext_busy_event,              // 10
        trap_event,                   // 9
        prefetch_useless_event,       // 8
        prefetch_hit_event,           // 7
        dcache_miss_event,            // 6
        icache_miss_event,            // 5
        load_use_stall_event,         // 4
        branch_flush_event            // 3
    };

    // A counter CSR address is 0xB or 0xC in [11:8], the high-half flag in
    // [7], zeros in [6:5], and the counter index in [4:0].
    function automatic logic is_counter_csr(input logic [11:0] addr);
        is_counter_csr = ((addr[11:8] == 4'hB) || (addr[11:8] == 4'hC)) &&
                         (addr[6:5] == 2'b00) &&
                         (addr[4:0] <= LAST_COUNTER) &&
                         !((addr[11:8] == 4'hB) && (addr[4:0] == 5'd1)); // no mtime CSR
    endfunction

    function automatic logic csr_supported(input logic [11:0] addr);
        unique case (addr)
            12'h001, 12'h002, 12'h003,
            12'h300, 12'h301, 12'h304, 12'h305,
            12'h340, 12'h341, 12'h342, 12'h343, 12'h344,
            12'hF11, 12'hF12, 12'hF13, 12'hF14: csr_supported = 1'b1;
            default: csr_supported = is_counter_csr(addr);
        endcase
    endfunction

    // CSR address bits [11:10] == 2'b11 mark read-only CSRs.
    function automatic logic csr_readonly(input logic [11:0] addr);
        csr_readonly = (addr[11:10] == 2'b11);
    endfunction

    function automatic logic is_fp_csr(input logic [11:0] addr);
        is_fp_csr = (addr == 12'h001) || (addr == 12'h002) || (addr == 12'h003);
    endfunction

    assign mtvec = mtvec_reg;
    assign mepc = mepc_reg;
    assign frm = frm_reg;
    assign fs = mstatus_reg[MSTATUS_FS_LO +: 2];

    assign mip_live = (timer_interrupt_pending ? (32'd1 << MIP_MTIP) : 32'b0) |
                      (external_interrupt_pending ? (32'd1 << MIP_MEIP) : 32'b0);
    // External interrupts outrank timer interrupts (privileged spec 3.1.9).
    assign interrupt_pending = mstatus_reg[MSTATUS_MIE] && ((mie_reg & mip_live) != 32'b0);
    assign interrupt_cause = (mie_reg[MIP_MEIP] && mip_live[MIP_MEIP]) ? MCAUSE_M_EXTERNAL_INTERRUPT
                                                                       : MCAUSE_M_TIMER_INTERRUPT;

    assign access_illegal = ~csr_supported(read_addr) ||
                            (access_write_attempt && csr_readonly(read_addr)) ||
                            (is_fp_csr(read_addr) && (fs == 2'b00));

    always_comb begin
        unique case (read_addr)
            12'h001: read_data = {27'b0, fflags_reg};
            12'h002: read_data = {29'b0, frm_reg};
            12'h003: read_data = {24'b0, frm_reg, fflags_reg};
            12'h300: read_data = {fs == FS_DIRTY, mstatus_reg[30:0]};
            12'h301: read_data = MISA_VALUE;
            12'h304: read_data = mie_reg;
            12'h305: read_data = mtvec_reg;
            12'h340: read_data = mscratch_reg;
            12'h341: read_data = mepc_reg;
            12'h342: read_data = mcause_reg;
            12'h343: read_data = mtval_reg;
            12'h344: read_data = mip_live;
            default: begin
                read_data = 32'b0;
                if (is_counter_csr(read_addr))
                    read_data = read_addr[7] ? counters[read_addr[4:0]][63:32]
                                             : counters[read_addr[4:0]][31:0];
            end
        endcase
    end

    // Software writes land first, then trap/MRET side effects, then counter
    // increments, so everything commits at one architectural point per cycle.
    function automatic logic [63:0] counter_increment(input int idx);
        if (idx <= 1)
            counter_increment = 64'd1;                  // mcycle, time
        else if (idx == 2)
            counter_increment = 64'(retire_count);      // minstret
        else
            counter_increment = 64'(hpm_event[idx]);
    endfunction

    always_ff @(posedge CLK) begin
        logic [31:0] next_mstatus;
        logic [63:0] next_count;

        if (RST) begin
            mstatus_reg <= MSTATUS_MPP_M;
            mie_reg <= 32'b0;
            mtvec_reg <= 32'b0;
            mscratch_reg <= 32'b0;
            mepc_reg <= 32'b0;
            mcause_reg <= 32'b0;
            mtval_reg <= 32'b0;
            fflags_reg <= 5'b0;
            frm_reg <= 3'b0;
            for (int i = 0; i <= LAST_COUNTER; i++)
                counters[i] <= 64'b0;
        end else begin
            next_mstatus = mstatus_reg;

            if (write_en) begin
                unique case (write_addr)
                    // Writing FP state also marks it Dirty.
                    12'h001: begin fflags_reg <= write_data[4:0]; next_mstatus[MSTATUS_FS_LO +: 2] = FS_DIRTY; end
                    12'h002: begin frm_reg <= write_data[2:0]; next_mstatus[MSTATUS_FS_LO +: 2] = FS_DIRTY; end
                    12'h003: begin
                        fflags_reg <= write_data[4:0];
                        frm_reg <= write_data[7:5];
                        next_mstatus[MSTATUS_FS_LO +: 2] = FS_DIRTY;
                    end
                    12'h300: next_mstatus = (write_data & MSTATUS_WRITABLE) | MSTATUS_MPP_M;
                    12'h304: mie_reg <= write_data & MIE_WRITABLE;
                    12'h305: mtvec_reg <= {write_data[31:2], 2'b00};
                    12'h340: mscratch_reg <= write_data;
                    12'h341: mepc_reg <= {write_data[31:1], 1'b0};
                    12'h342: mcause_reg <= write_data;
                    12'h343: mtval_reg <= write_data;
                    // misa and mip accept writes but have no writable bits;
                    // counter writes are merged in the loop below.
                    default: ;
                endcase
            end

            if (trap_en) begin
                mepc_reg <= {trap_pc[31:1], 1'b0};
                mcause_reg <= trap_cause;
                mtval_reg <= trap_tval;
                next_mstatus[MSTATUS_MPIE] = next_mstatus[MSTATUS_MIE];
                next_mstatus[MSTATUS_MIE] = 1'b0;
            end

            // MRET returns to M-mode (the only mode), so MPP stays M.
            if (mret_en) begin
                next_mstatus[MSTATUS_MIE] = next_mstatus[MSTATUS_MPIE];
                next_mstatus[MSTATUS_MPIE] = 1'b1;
            end

            if (fp_dirty)
                next_mstatus[MSTATUS_FS_LO +: 2] = FS_DIRTY;
            // FP ops never retire in the same cycle as an FP CSR write (they
            // do not dual-issue), so accruing flags cannot race a write.
            if (fflags_accrue)
                fflags_reg <= fflags_reg | fflags_new;

            for (int i = 0; i <= LAST_COUNTER; i++) begin
                next_count = counters[i];
                if (write_en && (write_addr[11:8] == 4'hB) && is_counter_csr(write_addr) &&
                    (write_addr[4:0] == i[4:0])) begin
                    if (write_addr[7])
                        next_count[63:32] = write_data;
                    else
                        next_count[31:0] = write_data;
                end
                counters[i] <= next_count + counter_increment(i);
            end

            mstatus_reg <= next_mstatus;
        end
    end
endmodule
