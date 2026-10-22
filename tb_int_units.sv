`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Unit test for IntDivider and IntMultiplier against reference arithmetic:
// random and edge operands, random acknowledge delays, mid-operation kills
// (divider), and random pipeline stalls (multiplier).
// Prints "TB_INT PASS ..." or "TB_INT FAIL ...".
//////////////////////////////////////////////////////////////////////////////////
module tb_int_units;
    logic clk = 1'b0;
    always #5 clk = ~clk;

    // ---- references ----------------------------------------------------------
    function automatic logic [31:0] ref_div(input logic [1:0] op, input logic [31:0] a, input logic [31:0] b);
        logic signed [31:0] sa, sb;
        sa = a;
        sb = b;
        unique case (op)
            2'b00: ref_div = (b == 0) ? 32'hFFFF_FFFF :
                             (a == 32'h8000_0000 && b == 32'hFFFF_FFFF) ? 32'h8000_0000 : 32'(sa / sb);
            2'b01: ref_div = (b == 0) ? 32'hFFFF_FFFF : a / b;
            2'b10: ref_div = (b == 0) ? a :
                             (a == 32'h8000_0000 && b == 32'hFFFF_FFFF) ? 32'h0 : 32'(sa % sb);
            default: ref_div = (b == 0) ? a : a % b;
        endcase
    endfunction

    function automatic logic [31:0] ref_mul(input logic [1:0] op, input logic [31:0] a, input logic [31:0] b);
        logic signed [65:0] p;
        unique case (op)
            2'b00: begin p = $signed({1'b0, a}) * $signed({1'b0, b}); ref_mul = p[31:0]; end
            2'b01: begin p = $signed({a[31], a}) * $signed({b[31], b}); ref_mul = p[63:32]; end
            2'b10: begin p = $signed({a[31], a}) * $signed({1'b0, b}); ref_mul = p[63:32]; end
            default: begin p = $signed({1'b0, a}) * $signed({1'b0, b}); ref_mul = p[63:32]; end
        endcase
    endfunction

    function automatic logic [31:0] edge_value(input int i);
        unique case (i)
            0: edge_value = 32'h0;          1: edge_value = 32'h1;
            2: edge_value = 32'hFFFF_FFFF;  3: edge_value = 32'h8000_0000;
            4: edge_value = 32'h7FFF_FFFF;  5: edge_value = 32'h2;
            6: edge_value = 32'hFFFF_FFFE;  7: edge_value = 32'h8000_0001;
            8: edge_value = 32'h0001_0000;  default: edge_value = 32'hFFFF_0000;
        endcase
    endfunction
    function automatic logic [31:0] operand();
        unique case ($urandom_range(0, 3))
            0: operand = edge_value($urandom_range(0, 9));
            1: operand = $urandom_range(0, 15);
            default: operand = $urandom;
        endcase
    endfunction

    int errors = 0;

    // ---- divider ---------------------------------------------------------------
    logic div_rst = 1'b1, div_start = 1'b0, div_ack = 1'b0;
    logic [1:0] div_op;
    logic [31:0] div_a, div_b, div_result;
    logic div_busy, div_valid;

    IntDivider DIV (.clk, .rst(div_rst), .in_valid(div_start), .in_op(div_op), .in_a(div_a), .in_b(div_b),
                    .busy(div_busy), .out_valid(div_valid), .out_result(div_result), .ack(div_ack));

    // ---- multiplier --------------------------------------------------------------
    logic mul_rst = 1'b1, mul_adv = 1'b1, mul_in_valid = 1'b0;
    logic [1:0] mul_op;
    logic [31:0] mul_a, mul_b, mul_result;
    logic mul_out_valid;

    IntMultiplier MUL (.clk, .rst(mul_rst), .advance(mul_adv), .in_valid(mul_in_valid), .in_op(mul_op),
                       .in_a(mul_a), .in_b(mul_b), .out_valid(mul_out_valid), .out_result(mul_result));

    // Expected multiplier results, in issue order.
    logic [31:0] mul_expect [$];
    int mul_checked = 0;

    always @(posedge clk) begin
        if (!mul_rst && mul_adv && mul_out_valid) begin
            if (mul_expect.size() == 0) begin
                $display("TB_INT FAIL multiplier produced an unexpected result");
                errors++;
            end else begin
                logic [31:0] e;
                e = mul_expect.pop_front();
                if (mul_result !== e) begin
                    if (errors < 10) $display("TB_INT FAIL mul got %h expected %h", mul_result, e);
                    errors++;
                end
                mul_checked++;
            end
        end
    end

    int div_checked = 0, div_killed = 0;

    initial begin
        repeat (3) @(negedge clk);
        div_rst = 1'b0;
        mul_rst = 1'b0;

        // Divider: 200,000 operations; one in 50 is killed mid-run.
        for (int n = 0; n < 200000; n++) begin
            logic [31:0] expect_v;
            @(negedge clk);
            div_op = 2'($urandom);
            div_a = operand();
            div_b = operand();
            expect_v = ref_div(div_op, div_a, div_b);
            div_start = 1'b1;
            @(negedge clk);
            div_start = 1'b0;
            if ($urandom_range(0, 49) == 0) begin
                repeat ($urandom_range(0, 40)) @(negedge clk);
                div_rst = 1'b1;
                @(negedge clk);
                div_rst = 1'b0;
                if (div_busy) begin $display("TB_INT FAIL divider busy after kill"); errors++; end
                div_killed++;
            end else begin
                while (!div_valid) @(negedge clk);
                repeat ($urandom_range(0, 2)) @(negedge clk);
                if (div_result !== expect_v) begin
                    if (errors < 10) $display("TB_INT FAIL div op=%0d a=%h b=%h got %h expected %h",
                                              div_op, div_a, div_b, div_result, expect_v);
                    errors++;
                end
                div_ack = 1'b1;
                @(negedge clk);
                div_ack = 1'b0;
                div_checked++;
            end
        end

        // Multiplier: 400,000 operations with random stalls and bubbles.
        for (int n = 0; n < 400000; n++) begin
            @(negedge clk);
            mul_adv = ($urandom_range(0, 9) != 0);
            mul_in_valid = mul_adv && ($urandom_range(0, 4) != 0);
            if (mul_in_valid) begin
                mul_op = 2'($urandom);
                mul_a = operand();
                mul_b = operand();
                mul_expect.push_back(ref_mul(mul_op, mul_a, mul_b));
            end
        end
        @(negedge clk);
        mul_in_valid = 1'b0;
        mul_adv = 1'b1;
        repeat (6) @(negedge clk);
        if (mul_expect.size() != 0) begin
            $display("TB_INT FAIL %0d multiplier results never came out", mul_expect.size());
            errors++;
        end

        if (errors == 0)
            $display("TB_INT PASS div=%0d (killed %0d) mul=%0d", div_checked, div_killed, mul_checked);
        else
            $display("TB_INT FAIL errors=%0d", errors);
        $finish(0);
    end
endmodule
