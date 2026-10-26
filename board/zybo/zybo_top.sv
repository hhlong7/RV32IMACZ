`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: zybo_top
// Target: Digilent Zybo Z7-20 (Zynq-7020, xc7z020clg400-1), programmable
//         logic only (the ARM processing system is not used).
// Description:
//   The OTTER core with its block-RAM memories, a 35.7 MHz clock from the
//   board's 125 MHz oscillator, and these memory-mapped devices:
//
//     0x11000000  read   switches: [3:0] SW3..SW0, [6:4] BTN3..BTN1
//     0x11000020  write  LEDs: [3:0] LD3..LD0, [6:4] LD5 red/green/blue,
//                        [9:7] LD6 red/green/blue
//     0x11000040  write  seven-segment register of the test programs (kept
//                        so they run unchanged; the Zybo has no display)
//     0x11000080  write  UART: send the byte in [7:0] (only while ready)
//                 read   UART: oldest received byte in [7:0]
//     0x11000084  read   UART status: [0] transmitter ready, [1] a byte is
//                        waiting, [2] a byte was lost (16-byte queue full)
//                 write  UART: acknowledge the oldest received byte (removes
//                        it, clears [2]); reads never change state, since
//                        the core may issue a load speculatively and
//                        discard it
//
//   BTN0 resets the core. The UART (115200 8N1) is on Pmod JE: the core
//   transmits on JE2 and receives on JE3 (a Digilent PmodUSBUART plugs into
//   the top row; with a USB-serial cable, connect its RX to JE2, its TX to
//   JE3, and ground to JE5).
//
//   With HOST = 1, a host bridge (board/host_bridge.sv) behind Vivado's
//   JTAG-to-AXI master lets the laptop hold the core, load a program into
//   its memory, run it, and use a console over the USB-JTAG cable
//   (tools/vivado/host.tcl). The console is a second path for the UART
//   registers above: bytes the core sends also go to the host, and bytes the
//   host sends arrive as received bytes. Without a host the core runs the
//   bitstream's built-in program, as with HOST = 0.
//////////////////////////////////////////////////////////////////////////////////
module zybo_top #(
    parameter bit HOST = 1'b1,              // include the JTAG host bridge
    parameter int CLK_HZ = 35_714_286,      // core clock (keep in step with the MMCM)
    parameter int BAUD = 115_200
) (
    input  logic       sysclk,              // 125 MHz
    input  logic [3:0] btn,
    input  logic [3:0] sw,
    output logic [3:0] led,
    output logic       led5_r,
    output logic       led5_g,
    output logic       led5_b,
    output logic       led6_r,
    output logic       led6_g,
    output logic       led6_b,
    output logic       uart_tx,
    input  logic       uart_rx
);
    localparam logic [31:0] SWITCHES_AD    = 32'h1100_0000;
    localparam logic [31:0] LEDS_AD        = 32'h1100_0020;
    localparam logic [31:0] SSEG_AD        = 32'h1100_0040;
    localparam logic [31:0] UART_DATA_AD   = 32'h1100_0080;
    localparam logic [31:0] UART_STATUS_AD = 32'h1100_0084;

    logic clk, locked;

`ifdef SYNTHESIS
    // 125 MHz x 6 = 750 MHz VCO, / 21 = 35.714 MHz. (/ 20 = 37.5 MHz missed
    // timing by 0.1 ns on the fetch loop; / 21 leaves about 1.2 ns.)
    logic clkfb, clkfb_buf, clk_mmcm;

    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKIN1_PERIOD(8.000),
        .DIVCLK_DIVIDE(1),
        .CLKFBOUT_MULT_F(6.000),
        .CLKOUT0_DIVIDE_F(21.000),
        .CLKOUT0_DUTY_CYCLE(0.500),
        .CLKOUT0_PHASE(0.000),
        .REF_JITTER1(0.010),
        .STARTUP_WAIT("FALSE")
    ) MMCM (
        .CLKIN1(sysclk),
        .CLKFBIN(clkfb_buf),
        .RST(1'b0),
        .PWRDWN(1'b0),
        .CLKFBOUT(clkfb),
        .CLKFBOUTB(),
        .CLKOUT0(clk_mmcm),
        .CLKOUT0B(),
        .CLKOUT1(),
        .CLKOUT1B(),
        .CLKOUT2(),
        .CLKOUT2B(),
        .CLKOUT3(),
        .CLKOUT3B(),
        .CLKOUT4(),
        .CLKOUT5(),
        .CLKOUT6(),
        .LOCKED(locked)
    );

    BUFG FB_BUFG (.I(clkfb), .O(clkfb_buf));
    BUFG CLK_BUFG (.I(clk_mmcm), .O(clk));
`else
    // Simulation: the testbench drives sysclk at the core frequency.
    assign clk = sysclk;
    assign locked = 1'b1;
`endif

    // ---- reset ----------------------------------------------------------------
    // Held while BTN0 is pressed or the MMCM is unlocked; released on the core
    // clock so the whole core leaves reset in the same cycle.
    logic reset_req, reset;
    logic [1:0] reset_sync;

    assign reset_req = btn[0] | ~locked;

    always_ff @(posedge clk or posedge reset_req) begin
        if (reset_req)
            reset_sync <= 2'b11;
        else
            reset_sync <= {1'b0, reset_sync[1]};
    end
    assign reset = reset_sync[0];

    // The host bridge resets only with the clock (not with BTN0), and can
    // hold the core in reset itself.
    logic board_reset, host_hold, core_reset;
    logic [1:0] board_sync = 2'b11;     // power-up value (FPGA register init)
    always_ff @(posedge clk or negedge locked) begin
        if (!locked)
            board_sync <= 2'b11;
        else
            board_sync <= {1'b0, board_sync[1]};
    end
    assign board_reset = board_sync[0];
    assign core_reset = reset | host_hold;

    // ---- inputs ---------------------------------------------------------------
    logic [6:0] inputs_meta, inputs_sync;
    always_ff @(posedge clk) begin
        inputs_meta <= {btn[3:1], sw};
        inputs_sync <= inputs_meta;
    end

    // ---- core -----------------------------------------------------------------
    logic [31:0] iobus_in, iobus_out, iobus_addr;
    logic iobus_wr;

    logic load_en, load_we, load_re;
    logic [31:0] load_addr, load_data, load_rdata;

    OTTER_MCU CPU (
        .CLK(clk),
        .RESET(core_reset),
        .INTR(1'b0),
        .IOBUS_IN(iobus_in),
        .IOBUS_OUT(iobus_out),
        .IOBUS_ADDR(iobus_addr),
        .IOBUS_WR(iobus_wr),
        .LOAD_EN(load_en),
        .LOAD_WE(load_we),
        .LOAD_RE(load_re),
        .LOAD_ADDR(load_addr),
        .LOAD_DATA(load_data),
        .LOAD_RDATA(load_rdata)
    );

    // ---- host bridge (JTAG) -----------------------------------------------------
    logic console_push, console_room;
    logic host_in_valid, host_in_ack;
    logic [7:0] host_in_byte;
    logic [15:0] sseg_q;

    assign console_push = iobus_wr && iobus_addr == UART_DATA_AD;

    generate
        if (HOST) begin : g_host
            logic [11:0] awaddr, araddr;
            logic awvalid, awready, wvalid, wready, bvalid, bready;
            logic arvalid, arready, rvalid, rready;
            logic [31:0] wdata, rdata;
            logic [3:0] wstrb;
            logic [1:0] bresp, rresp;

            host_axi_master JTAG (
                .aclk(clk), .aresetn(!board_reset),
                .m_axi_awaddr(awaddr), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
                .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wvalid(wvalid), .m_axi_wready(wready),
                .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
                .m_axi_araddr(araddr), .m_axi_arvalid(arvalid), .m_axi_arready(arready),
                .m_axi_rdata(rdata), .m_axi_rresp(rresp), .m_axi_rvalid(rvalid), .m_axi_rready(rready)
            );

            host_bridge BRIDGE (
                .clk(clk), .rst(board_reset),
                .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
                .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
                .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
                .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
                .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
                .hold_core(host_hold), .core_running(!core_reset),
                .load_en(load_en), .load_we(load_we), .load_re(load_re),
                .load_addr(load_addr), .load_data(load_data), .load_rdata(load_rdata),
                .console_push(console_push), .console_byte(iobus_out[7:0]), .console_room(console_room),
                .console_in_valid(host_in_valid), .console_in_byte(host_in_byte),
                .console_in_ack(host_in_ack),
                .sseg(sseg_q)
            );
        end else begin : g_no_host
            assign host_hold = 1'b0;
            assign load_en = 1'b0;
            assign load_we = 1'b0;
            assign load_re = 1'b0;
            assign load_addr = 32'b0;
            assign load_data = 32'b0;
            assign console_room = 1'b1;
            assign host_in_valid = 1'b0;
            assign host_in_byte = 8'b0;
        end
    endgenerate

    // ---- UART -----------------------------------------------------------------
    logic tx_busy, uart_rx_valid, rx_overrun, rx_valid, rx_ack;
    logic [7:0] uart_rx_data, rx_data;

    // Received bytes: the host's console first, then the Pmod UART's.
    assign rx_ack = iobus_wr && iobus_addr == UART_STATUS_AD;
    assign rx_valid = host_in_valid || uart_rx_valid;
    assign rx_data = host_in_valid ? host_in_byte : uart_rx_data;
    assign host_in_ack = rx_ack && host_in_valid;

    uart #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) UART (
        .clk(clk),
        .rst(reset),
        .tx_start(iobus_wr && iobus_addr == UART_DATA_AD),
        .tx_data(iobus_out[7:0]),
        .tx_busy(tx_busy),
        .tx(uart_tx),
        .rx(uart_rx),
        .rx_data(uart_rx_data),
        .rx_valid(uart_rx_valid),
        .rx_overrun(rx_overrun),
        .rx_ack(rx_ack && !host_in_valid)
    );

    // ---- IO bus ---------------------------------------------------------------
    // Reads: the memory block registers this value in the cycle the load is
    // issued, so it only has to depend on the address.
    always_comb begin
        unique case (iobus_addr)
            SWITCHES_AD:    iobus_in = {25'b0, inputs_sync};
            UART_DATA_AD:   iobus_in = {24'b0, rx_data};
            // Ready to send: the UART is free and the host console has room.
            UART_STATUS_AD: iobus_in = {29'b0, rx_overrun, rx_valid, !tx_busy && console_room};
            default:        iobus_in = 32'b0;
        endcase
    end

    logic [9:0] leds_q;

    always_ff @(posedge clk) begin
        if (core_reset) begin
            leds_q <= 10'b0;
            sseg_q <= 16'b0;
        end else if (iobus_wr) begin
            if (iobus_addr == LEDS_AD) leds_q <= iobus_out[9:0];
            if (iobus_addr == SSEG_AD) sseg_q <= iobus_out[15:0];
        end
    end

    assign led = leds_q[3:0];
    assign {led5_r, led5_g, led5_b} = {leds_q[4], leds_q[5], leds_q[6]};
    assign {led6_r, led6_g, led6_b} = {leds_q[7], leds_q[8], leds_q[9]};
endmodule
