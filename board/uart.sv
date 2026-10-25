`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: uart
// Description:
//   8N1 serial port (one start bit, eight data bits LSB first, one stop
//   bit) at BAUD with a CLK_HZ clock.
//
//   Transmit: pulse tx_start with tx_data while tx_busy is low.
//   Receive:  finished bytes enter a RX_FIFO-byte queue. rx_valid says it is
//             not empty and rx_data is its oldest byte; rx_ack removes that
//             byte. A byte that arrives to a full queue is dropped and sets
//             rx_overrun, which rx_ack also clears.
//   The receiver samples each bit in its middle, after a start bit that is
//   still low half a bit after the falling edge.
//////////////////////////////////////////////////////////////////////////////////
module uart #(
    parameter int CLK_HZ = 35_714_286,
    parameter int BAUD = 115_200,
    parameter int RX_FIFO = 16              // power of two
) (
    input  logic       clk,
    input  logic       rst,

    input  logic       tx_start,
    input  logic [7:0] tx_data,
    output logic       tx_busy,
    output logic       tx,

    input  logic       rx,
    output logic [7:0] rx_data,
    output logic       rx_valid,
    output logic       rx_overrun,
    input  logic       rx_ack
);
    localparam int DIV = (CLK_HZ + BAUD / 2) / BAUD;    // clocks per bit
    localparam int CW = $clog2(DIV + 1);

    // ---- transmit -----------------------------------------------------------
    logic [9:0] tx_shift;           // {stop, data, start}, sent LSB first
    logic [3:0] tx_bits;            // bits left to send
    logic [CW-1:0] tx_count;

    assign tx_busy = (tx_bits != 4'd0);

    always_ff @(posedge clk) begin
        if (rst) begin
            tx <= 1'b1;
            tx_bits <= 4'd0;
            tx_count <= '0;
            tx_shift <= '1;
        end else if (!tx_busy) begin
            tx <= 1'b1;
            if (tx_start) begin
                tx_shift <= {1'b1, tx_data, 1'b0};
                tx_bits <= 4'd10;
                tx_count <= '0;
            end
        end else begin
            tx <= tx_shift[0];
            if (tx_count == CW'(DIV - 1)) begin
                tx_count <= '0;
                tx_shift <= {1'b1, tx_shift[9:1]};
                tx_bits <= tx_bits - 4'd1;
            end else begin
                tx_count <= tx_count + 1'b1;
            end
        end
    end

    // ---- receive ------------------------------------------------------------
    logic [2:0] rx_sync;            // synchronizer; rx_sync[2] is the stable bit
    logic rx_active;
    logic [3:0] rx_bit;             // 0 start, 1..8 data, 9 stop
    logic [CW-1:0] rx_count;
    logic [7:0] rx_shift;
    localparam int FW = $clog2(RX_FIFO);
    logic [7:0] fifo [RX_FIFO];
    logic [FW-1:0] fifo_head, fifo_tail;
    logic [FW:0] fifo_count;
    logic rx_done;                  // a byte finished this cycle

    assign rx_valid = (fifo_count != '0);
    assign rx_data = fifo[fifo_head];

    always_ff @(posedge clk) begin
        if (rst) begin
            rx_sync <= 3'b111;
            rx_active <= 1'b0;
            rx_bit <= 4'd0;
            rx_count <= '0;
            rx_shift <= 8'b0;
            rx_overrun <= 1'b0;
            rx_done <= 1'b0;
            fifo_head <= '0;
            fifo_tail <= '0;
            fifo_count <= '0;
        end else begin
            logic push, pop;
            rx_sync <= {rx_sync[1:0], rx};
            rx_done <= 1'b0;

            // Queue: a finished byte goes in, an acknowledged one comes out.
            pop = rx_ack && rx_valid;
            push = rx_done && (fifo_count != (FW+1)'(RX_FIFO) || pop);
            if (push) begin
                fifo[fifo_tail] <= rx_shift;
                fifo_tail <= fifo_tail + 1'b1;
            end
            if (pop)
                fifo_head <= fifo_head + 1'b1;
            fifo_count <= fifo_count + (FW+1)'(push) - (FW+1)'(pop);
            if (rx_ack)
                rx_overrun <= 1'b0;
            else if (rx_done && !push)
                rx_overrun <= 1'b1;

            if (!rx_active) begin
                if (rx_sync[2] == 1'b0) begin           // start bit begins
                    rx_active <= 1'b1;
                    rx_bit <= 4'd0;
                    rx_count <= CW'(DIV / 2);           // first sample mid-bit
                end
            end else if (rx_count != '0) begin
                rx_count <= rx_count - 1'b1;
            end else begin
                rx_count <= CW'(DIV - 1);
                if (rx_bit == 4'd0) begin
                    if (rx_sync[2] != 1'b0)
                        rx_active <= 1'b0;              // glitch, not a start bit
                    rx_bit <= 4'd1;
                end else if (rx_bit <= 4'd8) begin
                    rx_shift <= {rx_sync[2], rx_shift[7:1]};
                    rx_bit <= rx_bit + 4'd1;
                end else begin                          // stop bit
                    rx_active <= 1'b0;
                    rx_done <= rx_sync[2];              // drop a byte with a bad stop bit
                end
            end
        end
    end
endmodule
