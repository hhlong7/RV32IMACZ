`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Board-level test of zybo_top running the board build of FreeRTOS + CoreMark
// (software/freertos_coremark, make zybo), loaded from Test_All.mem. The test
// image is built with ZYBO_CLOCK_HZ=20000, so CoreMark's 10-second run is
// about 200,000 cycles. Checks:
//   - LD6 is blue while CoreMark runs,
//   - the UART report says "Correct operation validated" and "CoreMark PASSED",
//   - afterwards every LED blinks together, with the RGB LEDs green.
// Prints "TB_ZYBO_COREMARK PASS" or "TB_ZYBO_COREMARK FAIL ...".
//
//   tools/run_board_test.sh coremark
//////////////////////////////////////////////////////////////////////////////////
module tb_zybo_coremark;
    localparam int CLK_HZ = 1_600_000;      // UART timing only (16 clocks per bit)
    localparam int BAUD = 100_000;
    localparam int BIT_CLKS = CLK_HZ / BAUD;
    localparam realtime PERIOD = 10ns;

    logic sysclk = 1'b0;
    always #(PERIOD / 2) sysclk = ~sysclk;

    logic [3:0] btn = 4'b0001;
    logic [3:0] sw = 4'b0000;
    logic [3:0] led;
    logic led5_r, led5_g, led5_b, led6_r, led6_g, led6_b;
    logic uart_tx, uart_rx = 1'b1;

    zybo_top #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) DUT (.*);

    string text = "";
    always begin
        logic [7:0] b;
        @(negedge uart_tx);
        repeat (BIT_CLKS + BIT_CLKS / 2) @(posedge sysclk);
        for (int i = 0; i < 8; i++) begin
            b[i] = uart_tx;
            repeat (BIT_CLKS) @(posedge sysclk);
        end
        text = {text, string'(b)};
    end

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
            $display("TB_ZYBO_COREMARK FAIL timed out waiting for \"%s\"; received:\n%s", needle, text);
            $finish(1);
        end
    endtask

    logic [9:0] all_leds;
    assign all_leds = {led6_b, led6_g, led6_r, led5_b, led5_g, led5_r, led};

    initial begin
        int on_samples, off_samples, cycles;
        repeat (20) @(posedge sysclk);
        btn[0] = 1'b0;

        wait_for("running CoreMark", 200_000);
        if (!(led6_b === 1'b1 && led === 4'b0000)) begin
            $display("TB_ZYBO_COREMARK FAIL LEDs while running: %b (expected only LD6 blue)", all_leds);
            $finish(1);
        end

        wait_for("CoreMark PASSED on the OTTER core.", 4_000_000);
        // The LEDs switch to blinking once the last line has been sent.
        cycles = 0;
        while (all_leds === 10'b1000000000 && cycles < 20_000) begin
            @(posedge sysclk);
            cycles++;
        end
        if (!contains(text, "Correct operation validated")) begin
            $display("TB_ZYBO_COREMARK FAIL no validation line; received:\n%s", text);
            $finish(1);
        end

        // Blinking: over a few blink periods (5,000 cycles each), every LED is
        // either all on (LD0-3 and green on both RGB LEDs) or all off.
        on_samples = 0;
        off_samples = 0;
        for (cycles = 0; cycles < 40_000; cycles++) begin
            @(posedge sysclk);
            if (all_leds === 10'b0100101111) on_samples++;
            else if (all_leds === 10'b0000000000) off_samples++;
            else begin
                $display("TB_ZYBO_COREMARK FAIL LEDs %b after CoreMark (expected all green or all off)", all_leds);
                $finish(1);
            end
        end
        if (on_samples < 5000 || off_samples < 5000) begin
            $display("TB_ZYBO_COREMARK FAIL LEDs not blinking (on %0d, off %0d cycles)", on_samples, off_samples);
            $finish(1);
        end

        $display("TB_ZYBO_COREMARK PASS; terminal output:\n%s", text);
        $finish(0);
    end
endmodule
