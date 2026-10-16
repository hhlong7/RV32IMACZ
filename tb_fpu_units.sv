`timescale 1ns / 1ps
// Unit test for fp_adder, fp_multiplier, and fp_divider against vectors from
// the exact-arithmetic reference (tools/fp_ref.py). The pipelined units get a
// back-to-back stream with random stall cycles and bubbles; the divider runs
// one operation at a time.
//
//   python3 tools/fp_ref.py vectors out/fp_vectors.txt
//   iverilog -g2012 -o out/tb_fpu.vvp fpu_pkg.sv fp_adder.sv fp_multiplier.sv fp_divider.sv tb_fpu_units.sv
//   vvp -n out/tb_fpu.vvp +VECTORS=out/fp_vectors.txt
module tb_fpu_units;
    localparam int MAX_VECTORS = 200000;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    int n_vec = 0;
    int vop [MAX_VECTORS];
    logic [2:0] vrm [MAX_VECTORS];
    logic [31:0] va [MAX_VECTORS], vb [MAX_VECTORS], vres [MAX_VECTORS];
    logic [4:0] vflags [MAX_VECTORS];

    int errors = 0;
    int checked [4];

    // Pipelined units share the stimulus bus; `use_mul` selects which one
    // receives in_valid.
    logic advance, in_valid, use_mul, in_sub;
    logic [31:0] in_a, in_b;
    logic [2:0] in_rm;
    logic add_valid, mul_valid;
    logic [31:0] add_result, mul_result;
    logic [4:0] add_flags, mul_flags;

    fp_adder ADD (.clk, .rst, .advance, .in_valid(in_valid && !use_mul), .in_sub,
                  .in_a, .in_b, .in_rm, .out_valid(add_valid), .out_result(add_result),
                  .out_flags(add_flags));
    fp_multiplier MUL (.clk, .rst, .advance, .in_valid(in_valid && use_mul),
                       .in_a, .in_b, .in_rm, .out_valid(mul_valid), .out_result(mul_result),
                       .out_flags(mul_flags));

    logic div_start, div_busy, div_valid, div_ack;
    logic [31:0] div_result;
    logic [4:0] div_flags;

    fp_divider DIV (.clk, .rst, .in_valid(div_start), .in_a, .in_b, .in_rm, .busy(div_busy),
                    .out_valid(div_valid), .out_result(div_result), .out_flags(div_flags),
                    .ack(div_ack));

    task automatic check(int idx, logic [31:0] result, logic [4:0] flags);
        checked[vop[idx]]++;
        if (result !== vres[idx] || flags !== vflags[idx]) begin
            errors++;
            if (errors <= 15)
                $display("TB_FPU FAIL op=%0d rm=%0d a=%08x b=%08x got=%08x/%05b want=%08x/%05b",
                         vop[idx], vrm[idx], va[idx], vb[idx], result, flags, vres[idx], vflags[idx]);
        end
    endtask

    // In-flight vector indices for the pipelined unit under test (module
    // scope: Icarus mishandles queues local to automatic tasks).
    int queue [$];
    int next;

    // Stream every vector of one pipelined op class through its unit.
    task run_pipelined(input bit mul);
        next = 0;
        queue.delete();
        use_mul = mul;
        while (next < n_vec || queue.size() > 0) begin
            @(negedge clk);
            advance = ($urandom_range(0, 9) != 0);       // ~10% stall cycles
            in_valid = 1'b0;
            // Find the next vector for this unit.
            while (next < n_vec && ((vop[next] == 2) != mul || vop[next] == 3)) next++;
            if (next < n_vec && $urandom_range(0, 7) != 0) begin  // occasional bubble
                in_valid = 1'b1;
                in_sub = (vop[next] == 1);
                in_a = va[next];
                in_b = vb[next];
                in_rm = vrm[next];
            end
            #1;
            if (advance) begin
                // Retire the result leaving S3 this cycle.
                if (mul ? mul_valid : add_valid) begin
                    if (queue.size() == 0)
                        $fatal(1, "TB_FPU FAIL %s produced a result with nothing in flight", mul ? "fp_multiplier" : "fp_adder");
                    check(queue.pop_front(), mul ? mul_result : add_result, mul ? mul_flags : add_flags);
                end
                if (in_valid) begin
                    queue.push_back(next);
                    next++;
                end
            end
        end
        @(negedge clk);
        in_valid = 1'b0;
    endtask

    // Watchdog: a unit that drops or invents results must not hang the test.
    initial begin
        #2_000_000_000;
        $fatal(1, "TB_FPU FAIL watchdog timeout");
    end

    initial begin
        string path;
        int fd, code, op, rm;
        logic [31:0] a, b, res, flags;

        if (!$value$plusargs("VECTORS=%s", path))
            path = "out/fp_vectors.txt";
        fd = $fopen(path, "r");
        if (fd == 0) $fatal(1, "cannot open %s", path);
        while (n_vec < MAX_VECTORS) begin
            code = $fscanf(fd, "%d %d %h %h %h %h\n", op, rm, a, b, res, flags);
            if (code != 6) break;
            vop[n_vec] = op;
            vrm[n_vec] = rm[2:0];
            va[n_vec] = a;
            vb[n_vec] = b;
            vres[n_vec] = res;
            vflags[n_vec] = flags[4:0];
            n_vec++;
        end
        $fclose(fd);

        for (int k = 0; k < 4; k++) checked[k] = 0;
        advance = 1'b0;
        in_valid = 1'b0;
        use_mul = 1'b0;
        in_sub = 1'b0;
        div_start = 1'b0;
        div_ack = 1'b0;
        repeat (3) @(posedge clk);
        rst = 1'b0;

        run_pipelined(1'b0);   // fadd / fsub
        run_pipelined(1'b1);   // fmul

        // fdiv: one at a time; random delay before acknowledging.
        for (int i = 0; i < n_vec; i++) begin
            if (vop[i] != 3) continue;
            @(negedge clk);
            div_start = 1'b1;
            in_a = va[i];
            in_b = vb[i];
            in_rm = vrm[i];
            @(negedge clk);
            div_start = 1'b0;
            while (!div_valid) @(negedge clk);
            repeat ($urandom_range(0, 2)) @(negedge clk);
            check(i, div_result, div_flags);
            div_ack = 1'b1;
            @(negedge clk);
            div_ack = 1'b0;
        end

        if (errors == 0)
            $display("TB_FPU PASS add/sub=%0d mul=%0d div=%0d vectors", checked[0] + checked[1], checked[2], checked[3]);
        else
            $display("TB_FPU FAIL errors=%0d", errors);
        $finish(0);
    end
endmodule
