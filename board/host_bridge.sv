`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: host_bridge
// Description:
//   Registers a host (the laptop, through Vivado's JTAG-to-AXI master) uses
//   to load and run programs on the OTTER core and to talk to them. AXI4-Lite
//   slave, 32-bit word registers; one write and one read can be in progress.
//
//   Offset  Register     Access
//   0x00    CONTROL      rw  [0] hold the core in reset
//                            [1] console attached: the core waits for room in
//                                the console instead of dropping output
//   0x04    STATUS       r   [0] core running, [1] console output waiting,
//                            [2] console input has room, [3] console output
//                            was dropped (buffer full, not attached)
//   0x08    LOAD_ADDR    rw  byte address for LOAD_DATA
//   0x0C    LOAD_DATA    w   store the word at LOAD_ADDR, then LOAD_ADDR += 4
//                        r   read the word at LOAD_ADDR, then LOAD_ADDR += 4
//                            (both only while the core is held, and only RAM
//                            addresses below 0x10000)
//   0x10    CONSOLE_OUT  r   up to three bytes the core printed, oldest in
//                            [7:0]; [31:24] says how many (0-3); removes them
//   0x14    CONSOLE_IN   w   one byte for the core to read ([7:0])
//   0x18    CYCLES_LO    r   core cycles since its reset was released (reading
//   0x1C    CYCLES_HI    r   CYCLES_LO captures CYCLES_HI for the next read)
//   0x20    SSEG         r   the value programs write to the seven-segment
//                            register (test pass/fail codes)
//   0x24    ID           r   0x4F545452 ("OTTR")
//
//   The core is not held after reset, so a bitstream's built-in program runs
//   at power-up as before; the host holds it to load a different one.
//////////////////////////////////////////////////////////////////////////////////
module host_bridge #(
    parameter int OUT_BYTES = 4096,     // console from the core (power of two)
    parameter int IN_BYTES = 64         // console to the core (power of two)
) (
    input  logic        clk,
    input  logic        rst,            // board reset (not the core's)

    // AXI4-Lite slave
    input  logic [11:0] s_axi_awaddr,
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,
    input  logic [31:0] s_axi_wdata,
    input  logic [3:0]  s_axi_wstrb,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,
    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,
    input  logic [11:0] s_axi_araddr,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,
    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready,

    // Core control and program loading (OTTER_MCU LOAD_* ports)
    output logic        hold_core,
    input  logic        core_running,
    output logic        load_en,
    output logic        load_we,
    output logic        load_re,
    output logic [31:0] load_addr,
    output logic [31:0] load_data,
    input  logic [31:0] load_rdata,

    // Console: bytes the core sends, and room to send more
    input  logic        console_push,
    input  logic [7:0]  console_byte,
    output logic        console_room,
    // Console: bytes for the core
    output logic        console_in_valid,
    output logic [7:0]  console_in_byte,
    input  logic        console_in_ack,

    input  logic [15:0] sseg
);
    localparam logic [31:0] ID_VALUE = 32'h4F54_5452;
    localparam int OW = $clog2(OUT_BYTES);
    localparam int IW = $clog2(IN_BYTES);

    logic control_hold;                 // CONTROL[0]
    logic attached;                     // CONTROL[1]
    logic [31:0] next_load_addr;        // LOAD_ADDR register

    // ---- console from the core: OUT_BYTES block RAM ----------------------------
    logic [7:0] out_mem [OUT_BYTES];
    logic [OW-1:0] out_head, out_tail;
    logic [OW:0] out_count;
    logic [7:0] out_rd;                 // out_mem[out_head], one cycle late
    logic out_dropped;
    logic out_pop;

    assign console_room = !attached || (out_count != (OW+1)'(OUT_BYTES));

    always_ff @(posedge clk) begin
        if (console_push && out_count != (OW+1)'(OUT_BYTES))
            out_mem[out_tail] <= console_byte;
        out_rd <= out_mem[out_head];
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            out_head <= '0;
            out_tail <= '0;
            out_count <= '0;
            out_dropped <= 1'b0;
        end else begin
            logic push;
            push = console_push && out_count != (OW+1)'(OUT_BYTES);
            if (console_push && !push)
                out_dropped <= 1'b1;
            if (push)
                out_tail <= out_tail + 1'b1;
            if (out_pop)
                out_head <= out_head + 1'b1;
            out_count <= out_count + (OW+1)'(push) - (OW+1)'(out_pop);
        end
    end

    // ---- console to the core: IN_BYTES registers --------------------------------
    logic [7:0] in_mem [IN_BYTES];
    logic [IW-1:0] in_head, in_tail;
    logic [IW:0] in_count;
    logic in_push;
    logic [7:0] in_push_byte;

    assign console_in_valid = (in_count != '0);
    assign console_in_byte = in_mem[in_head];

    always_ff @(posedge clk) begin
        if (rst) begin
            in_head <= '0;
            in_tail <= '0;
            in_count <= '0;
        end else begin
            logic push, pop;
            push = in_push && in_count != (IW+1)'(IN_BYTES);
            pop = console_in_ack && console_in_valid;
            if (push) begin
                in_mem[in_tail] <= in_push_byte;
                in_tail <= in_tail + 1'b1;
            end
            if (pop)
                in_head <= in_head + 1'b1;
            in_count <= in_count + (IW+1)'(push) - (IW+1)'(pop);
        end
    end

    // ---- cycle counter ------------------------------------------------------------
    logic [63:0] cycles;
    logic [31:0] cycles_hi_latch;

    always_ff @(posedge clk) begin
        if (rst || !core_running)
            cycles <= '0;
        else
            cycles <= cycles + 64'd1;
    end

    // ---- writes ---------------------------------------------------------------------
    // One write at a time: address and data are taken together, then the
    // response is held until the host accepts it.
    logic write_now;
    assign write_now = s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid;
    assign s_axi_awready = write_now;
    assign s_axi_wready = write_now;
    assign s_axi_bresp = 2'b00;

    // ---- reads ----------------------------------------------------------------------
    typedef enum logic [2:0] { R_IDLE, R_MEM_ISSUE, R_MEM_WAIT, R_OUT_TAKE, R_OUT_WAIT, R_SEND } rstate_t;
    rstate_t rstate;
    logic [5:0] raddr;
    logic [1:0] out_n, out_i;           // CONSOLE_OUT: bytes to take, taken
    logic in_ram_range;

    assign s_axi_arready = (rstate == R_IDLE);
    assign s_axi_rresp = 2'b00;
    assign s_axi_rvalid = (rstate == R_SEND);
    assign out_pop = (rstate == R_OUT_TAKE);
    assign in_ram_range = (next_load_addr < 32'h0001_0000);

    assign hold_core = control_hold;
    assign load_en = control_hold;

    always_ff @(posedge clk) begin
        if (rst) begin
            control_hold <= 1'b0;
            attached <= 1'b0;
            next_load_addr <= '0;
            load_we <= 1'b0;
            load_re <= 1'b0;
            load_addr <= '0;
            load_data <= '0;
            s_axi_bvalid <= 1'b0;
            rstate <= R_IDLE;
            s_axi_rdata <= '0;
            in_push <= 1'b0;
            in_push_byte <= '0;
            cycles_hi_latch <= '0;
            out_n <= '0;
            out_i <= '0;
            raddr <= '0;
        end else begin
            load_we <= 1'b0;
            load_re <= 1'b0;
            in_push <= 1'b0;

            // Write response
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;

            if (write_now) begin
                s_axi_bvalid <= 1'b1;
                unique case (s_axi_awaddr[7:2])
                    6'h00: begin
                        control_hold <= s_axi_wdata[0];
                        attached <= s_axi_wdata[1];
                    end
                    6'h02: next_load_addr <= {s_axi_wdata[31:2], 2'b00};
                    6'h03: if (control_hold && in_ram_range) begin
                        load_we <= 1'b1;
                        load_addr <= next_load_addr;
                        load_data <= s_axi_wdata;
                        next_load_addr <= next_load_addr + 32'd4;
                    end
                    6'h05: begin
                        in_push <= 1'b1;
                        in_push_byte <= s_axi_wdata[7:0];
                    end
                    default: ;
                endcase
            end

            // Reads
            unique case (rstate)
                R_IDLE: if (s_axi_arvalid) begin
                    raddr <= s_axi_araddr[7:2];
                    s_axi_rdata <= '0;
                    unique case (s_axi_araddr[7:2])
                        6'h00: begin s_axi_rdata <= {30'b0, attached, control_hold}; rstate <= R_SEND; end
                        6'h01: begin
                            s_axi_rdata <= {28'b0, out_dropped, in_count != (IW+1)'(IN_BYTES),
                                            out_count != '0, core_running};
                            rstate <= R_SEND;
                        end
                        6'h02: begin s_axi_rdata <= next_load_addr; rstate <= R_SEND; end
                        6'h03: if (control_hold && in_ram_range) rstate <= R_MEM_ISSUE;
                               else rstate <= R_SEND;
                        6'h04: begin
                            out_n <= (out_count >= (OW+1)'(3)) ? 2'd3 : 2'(out_count);
                            out_i <= 2'd0;
                            if (out_count == '0) rstate <= R_SEND;
                            else rstate <= R_OUT_TAKE;
                        end
                        6'h06: begin
                            s_axi_rdata <= cycles[31:0];
                            cycles_hi_latch <= cycles[63:32];
                            rstate <= R_SEND;
                        end
                        6'h07: begin s_axi_rdata <= cycles_hi_latch; rstate <= R_SEND; end
                        6'h08: begin s_axi_rdata <= {16'b0, sseg}; rstate <= R_SEND; end
                        6'h09: begin s_axi_rdata <= ID_VALUE; rstate <= R_SEND; end
                        default: rstate <= R_SEND;
                    endcase
                end

                // LOAD_DATA read: the memory answers the cycle after the request.
                R_MEM_ISSUE: begin
                    load_re <= 1'b1;
                    load_addr <= next_load_addr;
                    rstate <= R_MEM_WAIT;
                end
                R_MEM_WAIT: if (!load_re) begin
                    s_axi_rdata <= load_rdata;
                    next_load_addr <= next_load_addr + 32'd4;
                    rstate <= R_SEND;
                end

                // CONSOLE_OUT: take out_n bytes; out_rd shows the head one cycle
                // after it moves, hence the wait state between bytes.
                R_OUT_TAKE: begin
                    s_axi_rdata[8*out_i +: 8] <= out_rd;
                    out_i <= out_i + 2'd1;
                    if (out_i + 2'd1 == out_n) rstate <= R_SEND;
                    else rstate <= R_OUT_WAIT;
                end
                R_OUT_WAIT: rstate <= R_OUT_TAKE;

                R_SEND: if (s_axi_rready) begin
                    rstate <= R_IDLE;
                end

                default: rstate <= R_IDLE;
            endcase

            if (rstate == R_OUT_TAKE && out_i + 2'd1 == out_n)
                s_axi_rdata[31:24] <= {6'b0, out_n};
        end
    end
endmodule
