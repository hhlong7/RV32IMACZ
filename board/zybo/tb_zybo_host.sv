`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Board-level test of the JTAG host bridge: the testbench plays the laptop,
// calling the AXI master model's write/read tasks the way tools/vivado/host.tcl
// issues JTAG-to-AXI transactions.
//
//   - the bitstream's built-in program (Test_All.mem, CoreMark for the board)
//     runs at power-up, and its output reaches the host console;
//   - the host holds the core, loads another program (hello.mem, the echo
//     demo) through LOAD_DATA, and reads it back through LOAD_DATA;
//   - after release the new program's banner arrives on the console, typed
//     characters (CONSOLE_IN) are echoed, 'i' prints the counters;
//   - CYCLES counts while running, BTN0 restarts the loaded program, and
//     holding the core again stops it.
// Prints "TB_ZYBO_HOST PASS" or "TB_ZYBO_HOST FAIL ...".
//
//   tools/run_board_test.sh host
//////////////////////////////////////////////////////////////////////////////////
module tb_zybo_host;
    localparam int CLK_HZ = 1_600_000;      // UART timing only (16 clocks per bit)
    localparam int BAUD = 100_000;
    localparam realtime PERIOD = 10ns;

    localparam logic [11:0] CONTROL = 12'h000, STATUS = 12'h004, LOAD_ADDR = 12'h008,
                            LOAD_DATA = 12'h00C, CONSOLE_OUT = 12'h010, CONSOLE_IN = 12'h014,
                            CYCLES_LO = 12'h018, CYCLES_HI = 12'h01C, SSEG = 12'h020, ID = 12'h024;

    logic sysclk = 1'b0;
    always #(PERIOD / 2) sysclk = ~sysclk;

    logic [3:0] btn = 4'b0001;
    logic [3:0] sw = 4'b0101;
    logic [3:0] led;
    logic led5_r, led5_g, led5_b, led6_r, led6_g, led6_b;
    logic uart_tx, uart_rx = 1'b1;

    zybo_top #(.HOST(1'b1), .CLK_HZ(CLK_HZ), .BAUD(BAUD)) DUT (.*);

    task automatic fail(input string why);
        $display("TB_ZYBO_HOST FAIL %s", why);
        $finish(1);
    endtask

    task automatic wr(input logic [11:0] addr, input logic [31:0] data);
        DUT.g_host.JTAG.write(addr, data);
    endtask

    task automatic rd(input logic [11:0] addr, output logic [31:0] data);
        DUT.g_host.JTAG.read(addr, data);
    endtask

    // ---- console ----------------------------------------------------------------
    string console = "";

    // Read CONSOLE_OUT until it is empty; returns how many bytes arrived.
    task automatic drain(output int got);
        logic [31:0] w;
        int n;
        got = 0;
        n = 1;
        while (n != 0) begin
            rd(CONSOLE_OUT, w);
            n = int'(w[31:24]);
            for (int i = 0; i < n; i++) begin
                logic [7:0] b;
                b = w[8*i +: 8];
                console = {console, string'(b)};
            end
            got += n;
        end
    endtask

    function automatic bit contains(input string hay, input string needle);
        for (int i = 0; i + needle.len() <= hay.len(); i++)
            if (hay.substr(i, i + needle.len() - 1) == needle)
                return 1'b1;
        return 1'b0;
    endfunction

    // (No return from the task: Icarus 12 does not support it.)
    task automatic wait_console(input string needle, input int max_polls);
        int polls, got;
        polls = 0;
        while (!contains(console, needle) && polls < max_polls) begin
            drain(got);
            repeat (200) @(posedge sysclk);
            polls++;
        end
        if (!contains(console, needle))
            fail($sformatf("console never showed \"%s\"; it has:\n%s", needle, console));
    endtask

    // ---- the program the host loads -----------------------------------------------
    logic [31:0] image [0:16383];
    int last_word;

    initial begin
        logic [31:0] w, hi, lo, lo2;
        int got;

        for (int i = 0; i < 16384; i++) image[i] = 32'b0;
        $readmemh("hello.mem", image);
        last_word = 0;
        for (int i = 0; i < 16384; i++)
            if (image[i] != 32'b0) last_word = i;

        repeat (20) @(posedge sysclk);
        btn[0] = 1'b0;

        // Connection check.
        rd(ID, w);
        if (w !== 32'h4F54_5452) fail($sformatf("ID read %h", w));
        rd(STATUS, w);
        if (w[0] !== 1'b1) fail("core not running after power-up");

        // The built-in program runs and its output reaches the console, even
        // with no host attached.
        wait_console("running CoreMark", 400);

        // Hold the core, attach the console, and load the echo demo.
        wr(CONTROL, 32'd3);
        rd(STATUS, w);
        if (w[0] !== 1'b0) fail("core still running while held");
        wr(LOAD_ADDR, 32'h0);
        for (int i = 0; i <= last_word; i++)
            wr(LOAD_DATA, image[i]);
        rd(LOAD_ADDR, w);
        if (w !== 32'(4 * (last_word + 1))) fail($sformatf("LOAD_ADDR ended at %h", w));

        // Read the image back.
        wr(LOAD_ADDR, 32'h0);
        for (int i = 0; i <= last_word; i++) begin
            rd(LOAD_DATA, w);
            if (w !== image[i]) fail($sformatf("read back word %0d: %h, loaded %h", i, w, image[i]));
        end

        // Drop the old program's output, then run the new one.
        drain(got);
        console = "";
        wr(CONTROL, 32'd2);
        wait_console("Zybo Z7-20", 400);
        wait_console("[switches 5, buttons 0]", 400);
        wait_console("> ", 400);

        // Type through the console.
        wr(CONSOLE_IN, "O");
        wr(CONSOLE_IN, "K");
        wait_console("OK", 400);
        wr(CONSOLE_IN, "i");
        wait_console("instructions ", 400);

        // Cycle counter.
        rd(CYCLES_LO, lo);
        rd(CYCLES_HI, hi);
        repeat (100) @(posedge sysclk);
        rd(CYCLES_LO, lo2);
        if (lo == 32'b0 || lo2 <= lo || hi !== 32'b0)
            fail($sformatf("cycle counter %h:%h then %h", hi, lo, lo2));

        // BTN0 restarts the loaded program (not the built-in one).
        console = "";
        btn[0] = 1'b1;
        repeat (20) @(posedge sysclk);
        btn[0] = 1'b0;
        wait_console("Zybo Z7-20", 400);
        if (contains(console, "CoreMark")) fail("BTN0 brought back the built-in program");

        // Holding stops it and clears the counter.
        wr(CONTROL, 32'd3);
        rd(STATUS, w);
        if (w[0] !== 1'b0) fail("core still running after hold");
        rd(CYCLES_LO, lo);
        if (lo !== 32'b0) fail($sformatf("cycle counter %h while held", lo));
        rd(SSEG, w);

        $display("TB_ZYBO_HOST PASS: loaded %0d words; console after BTN0:\n%s", last_word + 1, console);
        $finish(0);
    end
endmodule
