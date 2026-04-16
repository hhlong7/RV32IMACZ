`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer: Long Ho
// Create Date: 04/16/2026
// Module Name: OTTER_MMIO
// Description:
//   Handles external MMIO accesses and the CLINT-style machine timer block so
//   the main memory module can stay focused on BRAM-backed data and atomics.
//////////////////////////////////////////////////////////////////////////////////

module OTTER_MMIO(
    input  logic        CLK,
    input  logic        RST,
    input  logic        RDEN2,
    input  logic        WE2,
    input  logic [31:0] ADDR2,
    input  logic [31:0] DIN2,
    input  logic [1:0]  SIZE,
    input  logic [31:0] IO_IN,

    output logic        MMIO_SEL,
    output logic        IO_WR,
    output logic [31:0] DOUT2,
    output logic        TIMER_INTERRUPT
);

    logic [31:0] ioBuffer;
    logic [31:0] timerReadWord;
    logic timerReadSel;
    logic timerWriteSel;
    logic [63:0] mtime_reg;
    logic [63:0] mtimecmp_reg;

    localparam logic [31:0] MMIO_BASE         = 32'h0001_0000;
    localparam logic [31:0] CLINT_MTIMECMP_LO = 32'h0200_4000;
    localparam logic [31:0] CLINT_MTIMECMP_HI = 32'h0200_4004;
    localparam logic [31:0] CLINT_MTIME_LO    = 32'h0200_BFF8;
    localparam logic [31:0] CLINT_MTIME_HI    = 32'h0200_BFFC;

    // The memory block treats everything above BRAM space as MMIO, but only a
    // small CLINT-style subset is interpreted internally here.
    assign MMIO_SEL = (ADDR2 >= MMIO_BASE);
    assign timerReadSel = (ADDR2 == CLINT_MTIMECMP_LO) ||
                          (ADDR2 == CLINT_MTIMECMP_HI) ||
                          (ADDR2 == CLINT_MTIME_LO) ||
                          (ADDR2 == CLINT_MTIME_HI);
    assign timerWriteSel = WE2 && timerReadSel;
    // External devices still use the original IO write path; timer writes stay
    // inside this block so they do not leak onto the general MMIO bus.
    assign IO_WR = MMIO_SEL && WE2 && ~timerWriteSel;
    assign DOUT2 = timerReadSel ? timerReadWord : ioBuffer;
    // FreeRTOS uses the standard mtime >= mtimecmp condition to request a tick.
    assign TIMER_INTERRUPT = (mtime_reg >= mtimecmp_reg);

    always_ff @(negedge CLK) begin
        if (RST) begin
            ioBuffer <= 32'b0;
            timerReadWord <= 32'b0;
            // Reset starts time from zero and leaves compare disabled until
            // software programs a smaller threshold.
            mtime_reg <= 64'b0;
            mtimecmp_reg <= 64'hFFFF_FFFF_FFFF_FFFF;
        end else begin
            mtime_reg <= mtime_reg + 64'd1;

            // External MMIO reads sample the shared IO input one cycle before
            // the memory block returns the buffered value.
            if (RDEN2 && MMIO_SEL && ~timerReadSel)
                ioBuffer <= IO_IN;

            if (timerWriteSel) begin
                if ((SIZE != 2'd2) || (ADDR2[1:0] != 2'b00))
                    $fatal(1, "timer MMIO requires aligned word writes at 0x%08x", ADDR2);

                // Software updates the 64-bit registers as two aligned words.
                unique case (ADDR2)
                    CLINT_MTIMECMP_LO: mtimecmp_reg[31:0] <= DIN2;
                    CLINT_MTIMECMP_HI: mtimecmp_reg[63:32] <= DIN2;
                    CLINT_MTIME_LO: mtime_reg[31:0] <= DIN2;
                    CLINT_MTIME_HI: mtime_reg[63:32] <= DIN2;
                    default: ;
                endcase
            end

            if (RDEN2 && timerReadSel) begin
                // Reads mirror the same split-word layout expected by the
                // upstream RISC-V CLINT port.
                unique case (ADDR2)
                    CLINT_MTIMECMP_LO: timerReadWord <= mtimecmp_reg[31:0];
                    CLINT_MTIMECMP_HI: timerReadWord <= mtimecmp_reg[63:32];
                    CLINT_MTIME_LO: timerReadWord <= mtime_reg[31:0];
                    CLINT_MTIME_HI: timerReadWord <= mtime_reg[63:32];
                    default: timerReadWord <= 32'b0;
                endcase
            end
        end
    end
endmodule
