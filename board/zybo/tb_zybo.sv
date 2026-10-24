`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Board-level test of zybo_top running software/zybo_hello (loaded from
// Test_All.mem in the working directory). The UART runs at 16 clocks per bit
// so the banner takes thousands of cycles, not millions. Checks:
//   - the banner arrives over the UART,
//   - typed characters are echoed, and 'i' prints the counters,
//   - the switches appear on LD3..LD0 and LD5 is green.
// Prints "TB_ZYBO PASS" or "TB_ZYBO FAIL ...".
//
//   tools/run_board_test.sh
//////////////////////////////////////////////////////////////////////////////////
module tb_zybo;
    localparam int CLK_HZ = 1_600_000;
    localparam int BAUD = 100_000;
    localparam int BIT_CLKS = CLK_HZ / BAUD;
    localparam realtime PERIOD = 10ns;

    logic sysclk = 1'b0;
    always #(PERIOD / 2) sysclk = ~sysclk;

    logic [3:0] btn = 4'b0001;      // BTN0 held: reset
    logic [3:0] sw = 4'b0101;
    logic [3:0] led;
    logic led5_r, led5_g, led5_b, led6_r, led6_g, led6_b;
    logic uart_tx, uart_rx = 1'b1;

    zybo_top #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) DUT (.*);

    // ---- UART receiver (the terminal) ----------------------------------------
    string text = "";
    always begin
        logic [7:0] b;
        @(negedge uart_tx);
        repeat (BIT_CLKS + BIT_CLKS / 2) @(posedge sysclk);
        for (int i = 0; i < 8; i++) begin
            b[i] = uart_tx;
            repeat (BIT_CLKS) @(posedge sysclk);
        end
        if (uart_tx !== 1'b1) begin
            $display("TB_ZYBO FAIL framing error after %s", text);
            $finish(1);
        end
        text = {text, string'(b)};
    end

    // ---- UART transmitter (typing) ---------------------------------------------
    task automatic type_char(input byte c);
        uart_rx = 1'b0;
        repeat (BIT_CLKS) @(posedge sysclk);
        for (int i = 0; i < 8; i++) begin
            uart_rx = c[i];
            repeat (BIT_CLKS) @(posedge sysclk);
        end
        uart_rx = 1'b1;
        repeat (BIT_CLKS) @(posedge sysclk);
    endtask

    function automatic bit contains(input string hay, input string needle);
        for (int i = 0; i + needle.len() <= hay.len(); i++)
            if (hay.substr(i, i + needle.len() - 1) == needle)
                return 1'b1;
        return 1'b0;
    endfunction

    // (No return from the task: Icarus 12 does not support it.)
    task automatic wait_for(input string needle, input int max_cycles);
        int n;
        n = 0;
        while (!contains(text, needle) && n < max_cycles) begin
            @(posedge sysclk);
            n++;
        end
        if (!contains(text, needle)) begin
            $display("TB_ZYBO FAIL timed out waiting for \"%s\"; received:\n%s", needle, text);
            $finish(1);
        end
    endtask

    initial begin
        repeat (20) @(posedge sysclk);
        btn[0] = 1'b0;

        wait_for("Zybo Z7-20", 200_000);
        wait_for("[switches 5, buttons 0]", 200_000);
        wait_for("> ", 200_000);
        if (led !== 4'b0101 || led5_g !== 1'b1) begin
            $display("TB_ZYBO FAIL LEDs %b, LD5 green %b", led, led5_g);
            $finish(1);
        end

        type_char("O");
        type_char("K");
        wait_for("OK", 50_000);

        type_char("i");
        wait_for("instructions ", 200_000);
        wait_for("> ", 200_000);

        sw = 4'b1010;
        wait_for("[switches a, buttons 0]", 200_000);
        repeat (200) @(posedge sysclk);
        if (led !== 4'b1010) begin
            $display("TB_ZYBO FAIL LEDs %b after switching to 1010", led);
            $finish(1);
        end

        $display("TB_ZYBO PASS; terminal output:\n%s", text);
        $finish(0);
    end
endmodule
