`timescale 1ns / 1ps

module tb_store_buffer;
    localparam int DEPTH = 4;
    localparam int TEST_CYCLES = 200;

    logic clk = 1'b0;
    logic rst = 1'b1;

    logic enqueue_valid;
    logic [31:0] enqueue_addr;
    logic [31:0] enqueue_data;
    logic [3:0] enqueue_mask;
    logic drain_accept;
    logic query_valid;
    logic [31:0] query_addr;
    logic [3:0] query_mask;

    logic full;
    logic empty;
    logic [$clog2(DEPTH + 1) - 1:0] occupancy;
    logic drain_valid;
    logic [31:0] drain_addr;
    logic [31:0] drain_data;
    logic [3:0] drain_mask;
    logic forward_hit;
    logic forward_conflict;
    logic [31:0] forward_data_word;

    logic [31:0] model_addr [0:DEPTH-1];
    logic [31:0] model_data [0:DEPTH-1];
    logic [3:0] model_mask [0:DEPTH-1];
    int model_count = 0;
    int cycle_idx;
    int seed;

    logic model_expected_hit;
    logic model_expected_conflict;
    logic [31:0] model_expected_word;

    StoreBuffer #(
        .DEPTH(DEPTH)
    ) dut (
        .clk(clk),
        .rst(rst),
        .enqueue_valid(enqueue_valid),
        .enqueue_addr(enqueue_addr),
        .enqueue_data(enqueue_data),
        .enqueue_mask(enqueue_mask),
        .drain_accept(drain_accept),
        .query_valid(query_valid),
        .query_addr(query_addr),
        .query_mask(query_mask),
        .full(full),
        .empty(empty),
        .occupancy(occupancy),
        .drain_valid(drain_valid),
        .drain_addr(drain_addr),
        .drain_data(drain_data),
        .drain_mask(drain_mask),
        .forward_hit(forward_hit),
        .forward_conflict(forward_conflict),
        .forward_data_word(forward_data_word)
    );

    always #5 clk = ~clk;

    function automatic [31:0] align_store_word(
        input logic [31:0] raw_data,
        input logic [3:0] byte_mask
    );
        logic [31:0] aligned;
        integer lane;
        integer src_idx;
        begin
            aligned = 32'b0;
            src_idx = 0;

            for (lane = 0; lane < 4; lane = lane + 1) begin
                if (byte_mask[lane]) begin
                    aligned[(lane * 8) +: 8] = raw_data[(src_idx * 8) +: 8];
                    src_idx = src_idx + 1;
                end
            end

            align_store_word = aligned;
        end
    endfunction

    function automatic [3:0] random_supported_mask(input int unsigned choice);
        begin
            unique case (choice % 8)
                0: random_supported_mask = 4'b0001;
                1: random_supported_mask = 4'b0010;
                2: random_supported_mask = 4'b0100;
                3: random_supported_mask = 4'b1000;
                4: random_supported_mask = 4'b0011;
                5: random_supported_mask = 4'b0110;
                6: random_supported_mask = 4'b1100;
                default: random_supported_mask = 4'b1111;
            endcase
        end
    endfunction

    task automatic compute_expected_query;
        int idx;
        int scan;
        logic [3:0] overlap_mask;
        logic found;
        begin
            model_expected_hit = 1'b0;
            model_expected_conflict = 1'b0;
            model_expected_word = 32'b0;
            found = 1'b0;

            if (query_valid) begin
                for (scan = model_count - 1; scan >= 0; scan = scan - 1) begin
                    if (!found) begin
                        idx = scan;
                        overlap_mask = query_mask & model_mask[idx];

                        if ((model_addr[idx][31:2] == query_addr[31:2]) && (overlap_mask != 4'b0000)) begin
                            if ((query_mask & ~model_mask[idx]) == 4'b0000) begin
                                model_expected_hit = 1'b1;
                                model_expected_word = align_store_word(model_data[idx], model_mask[idx]);
                            end else begin
                                model_expected_conflict = 1'b1;
                            end
                            found = 1'b1;
                        end
                    end
                end
            end
        end
    endtask

    task automatic check_outputs(input string tag);
        begin
            compute_expected_query();
            #1;

            if (full !== (model_count == DEPTH))
                $fatal(1, "%s full mismatch: got=%0b exp=%0b count=%0d", tag, full, (model_count == DEPTH), model_count);
            if (empty !== (model_count == 0))
                $fatal(1, "%s empty mismatch: got=%0b exp=%0b count=%0d", tag, empty, (model_count == 0), model_count);
            if (occupancy !== model_count[$bits(occupancy)-1:0])
                $fatal(1, "%s occupancy mismatch: got=%0d exp=%0d", tag, occupancy, model_count);

            if (drain_valid !== (model_count != 0))
                $fatal(1, "%s drain_valid mismatch: got=%0b exp=%0b", tag, drain_valid, (model_count != 0));
            if (model_count != 0) begin
                if (drain_addr !== model_addr[0])
                    $fatal(1, "%s drain_addr mismatch: got=0x%08x exp=0x%08x", tag, drain_addr, model_addr[0]);
                if (drain_data !== model_data[0])
                    $fatal(1, "%s drain_data mismatch: got=0x%08x exp=0x%08x", tag, drain_data, model_data[0]);
                if (drain_mask !== model_mask[0])
                    $fatal(1, "%s drain_mask mismatch: got=%b exp=%b", tag, drain_mask, model_mask[0]);
            end

            if (forward_hit !== model_expected_hit)
                $fatal(1, "%s forward_hit mismatch: got=%0b exp=%0b", tag, forward_hit, model_expected_hit);
            if (forward_conflict !== model_expected_conflict)
                $fatal(1, "%s forward_conflict mismatch: got=%0b exp=%0b", tag, forward_conflict, model_expected_conflict);
            if (model_expected_hit && (forward_data_word !== model_expected_word))
                $fatal(1, "%s forward_data mismatch: got=0x%08x exp=0x%08x", tag, forward_data_word, model_expected_word);
        end
    endtask

    task automatic model_enqueue(
        input logic [31:0] addr,
        input logic [31:0] data,
        input logic [3:0] mask
    );
        begin
            model_addr[model_count] = addr;
            model_data[model_count] = data;
            model_mask[model_count] = mask;
            model_count = model_count + 1;
        end
    endtask

    task automatic model_dequeue;
        int idx;
        begin
            for (idx = 0; idx < DEPTH - 1; idx = idx + 1) begin
                model_addr[idx] = model_addr[idx + 1];
                model_data[idx] = model_data[idx + 1];
                model_mask[idx] = model_mask[idx + 1];
            end
            model_count = model_count - 1;
        end
    endtask

    task automatic step_cycle(
        input logic do_enqueue,
        input logic [31:0] enq_addr,
        input logic [31:0] enq_data,
        input logic [3:0] enq_mask,
        input logic do_dequeue,
        input logic do_query,
        input logic [31:0] qry_addr,
        input logic [3:0] qry_mask,
        input string tag
    );
        logic accepted_enqueue;
        logic accepted_dequeue;
        begin
            enqueue_valid = do_enqueue;
            enqueue_addr = enq_addr;
            enqueue_data = enq_data;
            enqueue_mask = enq_mask;
            drain_accept = do_dequeue;
            query_valid = do_query;
            query_addr = qry_addr;
            query_mask = qry_mask;

            check_outputs({tag, "_pre"});
            accepted_enqueue = do_enqueue && (model_count < DEPTH);
            accepted_dequeue = do_dequeue && (model_count != 0);
            @(posedge clk);

            if (accepted_dequeue)
                model_dequeue();
            if (accepted_enqueue)
                model_enqueue(enq_addr, enq_data, enq_mask);

            check_outputs({tag, "_post"});
        end
    endtask

    initial begin
        enqueue_valid = 1'b0;
        enqueue_addr = 32'b0;
        enqueue_data = 32'b0;
        enqueue_mask = 4'b0;
        drain_accept = 1'b0;
        query_valid = 1'b0;
        query_addr = 32'b0;
        query_mask = 4'b0;
        seed = 32'h51ab_c0de;

        repeat (3) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);
        check_outputs("after_reset");

        // Directed smoke: fill entries without stalls, then prove FIFO drain order.
        step_cycle(1'b1, 32'h0000_2000, 32'h1122_3344, 4'b1111, 1'b0, 1'b0, 32'b0, 4'b0, "dir_enq0");
        step_cycle(1'b1, 32'h0000_2004, 32'h5566_7788, 4'b1111, 1'b0, 1'b0, 32'b0, 4'b0, "dir_enq1");
        step_cycle(1'b0, 32'b0, 32'b0, 4'b0, 1'b1, 1'b0, 32'b0, 4'b0, "dir_drain0");
        step_cycle(1'b0, 32'b0, 32'b0, 4'b0, 1'b1, 1'b0, 32'b0, 4'b0, "dir_drain1");

        // Forwarding cases: full cover, miss, and unsafe partial overlap.
        step_cycle(1'b1, 32'h0000_2100, 32'hdead_beef, 4'b1111, 1'b0, 1'b1, 32'h0000_2100, 4'b1111, "dir_fwd_full");
        step_cycle(1'b0, 32'b0, 32'b0, 4'b0, 1'b0, 1'b1, 32'h0000_2110, 4'b1111, "dir_fwd_miss");
        step_cycle(1'b0, 32'b0, 32'b0, 4'b0, 1'b0, 1'b1, 32'h0000_2100, 4'b0110, "dir_fwd_partial");
        step_cycle(1'b0, 32'b0, 32'b0, 4'b0, 1'b1, 1'b0, 32'b0, 4'b0, "dir_cleanup");

        // Fill to capacity and verify that the buffer reports full.
        repeat (DEPTH) begin
            step_cycle(1'b1,
                       32'h0000_2200 + (model_count * 4),
                       $urandom(seed),
                       random_supported_mask($urandom(seed)),
                       1'b0,
                       1'b0,
                       32'b0,
                       4'b0,
                       "dir_fill_full");
        end
        if (!full)
            $fatal(1, "full should be asserted after %0d entries", DEPTH);
        step_cycle(1'b1, 32'h0000_2300, 32'h1234_5678, 4'b1111, 1'b0, 1'b0, 32'b0, 4'b0, "dir_block_full");
        if (occupancy != DEPTH[$bits(occupancy)-1:0])
            $fatal(1, "occupancy changed on blocked enqueue");

        // Randomized stress.
        for (cycle_idx = 0; cycle_idx < TEST_CYCLES; cycle_idx = cycle_idx + 1) begin
            logic do_enqueue;
            logic do_dequeue;
            logic do_query;
            logic [31:0] rand_addr;
            logic [31:0] rand_data;
            logic [3:0] rand_mask;
            logic [31:0] rand_query_addr;
            logic [3:0] rand_query_mask;

            do_enqueue = ($urandom(seed) & 32'h3) == 32'h0;
            do_dequeue = ($urandom(seed) & 32'h3) == 32'h1;
            do_query = 1'b1;

            rand_addr = 32'h0000_2400 + (($urandom(seed) % 16) * 4);
            rand_data = $urandom(seed);
            rand_mask = random_supported_mask($urandom(seed));
            rand_query_addr = 32'h0000_2400 + (($urandom(seed) % 16) * 4);
            rand_query_mask = random_supported_mask($urandom(seed));

            step_cycle(do_enqueue, rand_addr, rand_data, rand_mask,
                       do_dequeue, do_query, rand_query_addr, rand_query_mask,
                       "rand");
        end

        // Drain out the random tail so FIFO order continues to hold to empty.
        while (model_count != 0)
            step_cycle(1'b0, 32'b0, 32'b0, 4'b0, 1'b1, 1'b0, 32'b0, 4'b0, "final_drain");

        $display("TB_STORE_BUFFER PASS cycles=%0d", TEST_CYCLES);
        $finish;
    end
endmodule
