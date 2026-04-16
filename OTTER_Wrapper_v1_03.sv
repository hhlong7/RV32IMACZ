`timescale 1ns / 1ps
/////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer: J. Calllenes
//           P. Hummel
//
// Create Date: 01/20/2019 10:36:50 AM
// Module Name: OTTER_Wrapper
// Target Devices: OTTER MCU on Basys3
// Description: OTTER_WRAPPER with Switches, LEDs, and 7-segment display
//
// Revision:
// Revision 0.01 - File Created
// Revision 0.02 - Updated MMIO Addresses, signal names
/////////////////////////////////////////////////////////////////////////////

module OTTER_Wrapper(
    input CLK,
    //input BTNL,
    input BTNC,
    input [15:0] SWITCHES,
    output logic [15:0] LEDS,
    output [7:0] CATHODES,
    output [3:0] ANODES
  );

  // INPUT PORT IDS ///////////////////////////////////////////////////////
  // Right now, the only possible inputs are the switches
  // In future labs you can add more MMIO, and you'll have
  // to add constants here for the mux below
  localparam SWITCHES_AD = 32'h11000000;

  // OUTPUT PORT IDS //////////////////////////////////////////////////////
  // In future labs you can add more MMIO
  localparam LEDS_AD    = 32'h11000020; //32'h11000020
  localparam SSEG_AD    = 32'h11000040; //32'h11000040

  // Signals for connecting OTTER_MCU to OTTER_wrapper /////////////////////
  logic clk_50;

  logic [31:0] IOBUS_out, IOBUS_in, IOBUS_addr;
  logic s_reset, reset_req, IOBUS_wr;
  logic mmcm_locked;
  logic clkfb, clkfb_buf;
  logic clk_50_mmcm;
  logic [1:0] reset_sync;

  // Registers for buffering outputs  /////////////////////////////////////
  logic [15:0] r_SSEG;

  // Declare OTTER_CPU ////////////////////////////////////////////////////
  OTTER_MCU CPU (
              .CLK(clk_50),
              .RESET(s_reset),
              .INTR(1'b0),
              .IOBUS_IN(IOBUS_in),
              .IOBUS_OUT(IOBUS_out),
              .IOBUS_ADDR(IOBUS_addr),
              .IOBUS_WR(IOBUS_wr)
            );

  // Declare Seven Segment Display /////////////////////////////////////////
  SevSegDisp SSG_DISP (.DATA_IN(r_SSEG), .CLK(CLK), .MODE(1'b0),
                       .CATHODES(CATHODES), .ANODES(ANODES));


  // 7-series compatible 100 MHz -> 50 MHz generation.
  // MMCM output is routed through BUFG onto the global clock network.
  // helped by code-ex to divide the clock from 100MHz to 50MHz using the MMCM, and by Xilinx's Clocking Wizard IP core generator
  MMCME2_BASE #(
      .BANDWIDTH("OPTIMIZED"),
      .CLKIN1_PERIOD(10.000),
      .DIVCLK_DIVIDE(1),
      .CLKFBOUT_MULT_F(10.000),
      .CLKOUT0_DIVIDE_F(20.000),
      .CLKOUT0_DUTY_CYCLE(0.500),
      .CLKOUT0_PHASE(0.000),
      .CLKOUT1_DIVIDE(1),
      .CLKOUT2_DIVIDE(1),
      .CLKOUT3_DIVIDE(1),
      .CLKOUT4_DIVIDE(1),
      .CLKOUT5_DIVIDE(1),
      .CLKOUT6_DIVIDE(1),
      .REF_JITTER1(0.010),
      .STARTUP_WAIT("FALSE")
  ) clk_50_mmcm_i (
      .CLKIN1(CLK),
      .CLKFBIN(clkfb_buf),
      .RST(1'b0),
      .PWRDWN(1'b0),
      .CLKFBOUT(clkfb),
      .CLKFBOUTB(),
      .CLKOUT0(clk_50_mmcm),
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
      .LOCKED(mmcm_locked)
  );

  BUFG clkfb_bufg (
      .I(clkfb),
      .O(clkfb_buf)
  );

  BUFG clk_50_bufg (
      .I(clk_50_mmcm),
      .O(clk_50)
  );

  // Connect Signals ///////////////////////////////////////////////////////
  // Keep reset asserted until the MMCM is locked, then release it only on the
  // CPU clock so the whole core leaves reset coherently on hardware.
  assign reset_req = BTNC | ~mmcm_locked;

  always_ff @(posedge clk_50 or posedge reset_req)
  begin
    if(reset_req)
      reset_sync <= 2'b11;
    else
      reset_sync <= {1'b0, reset_sync[1]};
  end

  assign s_reset = reset_sync[0];


  // Connect Board input peripherals (Memory Mapped IO devices) to IOBUS
  always_comb
  begin
    case(IOBUS_addr)
      SWITCHES_AD:
        IOBUS_in = {16'b0,SWITCHES};
      default:
        IOBUS_in = 32'b0;    // default bus input to 0
    endcase
  end


  // Connect Board output peripherals (Memory Mapped IO devices) to IOBUS
  always_ff @ (posedge clk_50)
  begin
    if(s_reset) begin
      LEDS   <= 16'h0000;
      r_SSEG <= 16'h0000;
    end
    else if(IOBUS_wr)
      case(IOBUS_addr)
        LEDS_AD:
          LEDS   <= IOBUS_out[15:0];
        SSEG_AD:
          r_SSEG <= IOBUS_out[15:0];
      endcase
  end

endmodule
//i love cpe333
