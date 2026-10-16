`timescale 1ns / 1ps
// Unit test for cache_tags: random lookups, fills, invalidates, touches, and
// flushes, checked every cycle against an independent behavioral model for
// each replacement policy (exact victim choice included).
//
//   iverilog -g2012 -o out/tb_cache_tags.vvp cache_tags.sv tb_cache_tags.sv
//   vvp -n out/tb_cache_tags.vvp
module tb_cache_tags;
    localparam int LINES = 16;
    localparam int LINE_BITS = 4;
    localparam int TAG_BITS = 27;
    localparam int OPS = 20000;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic [1:0][TAG_BITS-1:0] lookup_tag;
    logic [1:0][1:0] hit;             // [policy][port]
    logic [1:0][1:0][3:0] line;       // [policy][port]
    logic [1:0][3:0] victim;          // [policy]
    logic [1:0] flush, fill_en, inval_en, touch_en;
    logic [1:0][TAG_BITS-1:0] fill_tag;
    logic [1:0][3:0] inval_line, touch_line;

    // Policy 0 = tree pseudo-LRU, policy 1 = true LRU.
    for (genvar p = 0; p < 2; p++) begin : g_dut
        cache_tags #(.LINES(LINES), .TAG_BITS(TAG_BITS), .LOOKUPS(2), .TRUE_LRU(p)) dut (
            .clk, .rst, .lookup_tag, .lookup_hit(hit[p]), .lookup_line(line[p]),
            .victim_line(victim[p]), .flush(flush[p]), .fill_en(fill_en[p]),
            .fill_tag(fill_tag[p]), .inval_en(inval_en[p]), .inval_line(inval_line[p]),
            .touch_en(touch_en[p]), .touch_line(touch_line[p]));
    end

    // ---- Reference models -------------------------------------------------
    logic [TAG_BITS-1:0] m_tag [2][LINES];
    bit m_valid [2][LINES];
    int recency [$];                  // true LRU: front = most recent
    bit plru_bit [1:LINES-1];         // pseudo-LRU: 1-based heap, 1 = go right
    int errors = 0;

    function automatic int model_policy_victim(int p);
        if (p == 1) return recency[$];
        begin
            int node;
            node = 1;
            for (int level = 0; level < LINE_BITS; level++)
                node = 2 * node + plru_bit[node];
            return node - LINES;
        end
    endfunction

    function automatic int model_victim(int p);
        for (int l = 0; l < LINES; l++)
            if (!m_valid[p][l]) return l;
        return model_policy_victim(p);
    endfunction

    function automatic void model_touch(int p, int ln);
        if (p == 1) begin
            foreach (recency[i])
                if (recency[i] == ln) begin
                    recency.delete(i);
                    break;
                end
            recency.push_front(ln);
        end else begin
            // Walk the line number MSB first; at each node point the other way.
            int node;
            int dir;
            node = 1;
            for (int level = LINE_BITS - 1; level >= 0; level--) begin
                dir = (ln >> level) & 1;
                plru_bit[node] = !dir;
                node = 2 * node + dir;
            end
        end
    endfunction

    function automatic void model_reset(int p);
        for (int l = 0; l < LINES; l++) m_valid[p][l] = 0;
        if (p == 1) begin
            recency.delete();
            for (int l = 0; l < LINES; l++) recency.push_back(l);
        end else begin
            for (int n = 1; n < LINES; n++) plru_bit[n] = 0;
        end
    endfunction

    function automatic int model_lookup(int p, logic [TAG_BITS-1:0] tag);
        for (int l = 0; l < LINES; l++)
            if (m_valid[p][l] && m_tag[p][l] == tag) return l;
        return -1;
    endfunction

    task automatic check(string what, int p, bit cond);
        if (!cond) begin
            errors++;
            if (errors <= 10)
                $display("TB_CACHE_TAGS FAIL %s policy=%s", what, p ? "LRU" : "PLRU");
        end
    endtask

    // Compare one policy's outputs with its model (constant policy index at
    // the call site keeps every array access simple for Icarus).
    task automatic check_outputs(int p, logic [1:0] h, logic [1:0][3:0] ln, logic [3:0] v);
        int expect_line;
        for (int port = 0; port < 2; port++) begin
            expect_line = model_lookup(p, lookup_tag[port]);
            check("lookup hit", p, h[port] == (expect_line >= 0));
            if (expect_line >= 0)
                check("lookup line", p, ln[port] == expect_line);
        end
        check("victim", p, v == model_victim(p));
    endtask

    function automatic logic [TAG_BITS-1:0] pick_tag();
        return TAG_BITS'($urandom_range(0, 2 * LINES));
    endfunction

    // ---- Stimulus ---------------------------------------------------------
    initial begin
        flush = '0; fill_en = '0; inval_en = '0; touch_en = '0;
        fill_tag = '0; inval_line = '0; touch_line = '0; lookup_tag = '0;
        for (int p = 0; p < 2; p++) model_reset(p);
        repeat (2) @(posedge clk);
        rst = 0;

        for (int op = 0; op < OPS; op++) begin
            @(posedge clk);
            lookup_tag[0] = pick_tag();
            lookup_tag[1] = pick_tag();
            flush = '0; fill_en = '0; inval_en = '0; touch_en = '0;

            for (int p = 0; p < 2; p++) begin
                int kind;
                kind = $urandom_range(0, 99);
                if (kind < 1) begin
                    flush[p] = 1;
                end else if (kind < 25) begin
                    // Caches only fill tags that missed, so never duplicate.
                    do fill_tag[p] = pick_tag(); while (model_lookup(p, fill_tag[p]) >= 0);
                    fill_en[p] = 1;
                end else if (kind < 35) begin
                    inval_en[p] = 1;
                    inval_line[p] = 4'($urandom_range(0, LINES - 1));
                end else if (kind < 90) begin
                    touch_en[p] = 1;
                    touch_line[p] = 4'($urandom_range(0, LINES - 1));
                end
            end
            #1;

            check_outputs(0, hit[0], line[0], victim[0]);
            check_outputs(1, hit[1], line[1], victim[1]);

            @(negedge clk); #1;
            for (int p = 0; p < 2; p++) begin
                if (flush[p]) begin
                    model_reset(p);
                end else if (fill_en[p]) begin
                    int v;
                    v = model_victim(p);
                    m_valid[p][v] = 1;
                    m_tag[p][v] = fill_tag[p];
                    model_touch(p, v);
                end else if (inval_en[p]) begin
                    m_valid[p][inval_line[p]] = 0;
                end else if (touch_en[p]) begin
                    model_touch(p, touch_line[p]);
                end
            end
        end

        if (errors == 0)
            $display("TB_CACHE_TAGS PASS ops=%0d (pseudo-LRU and true LRU)", OPS);
        else
            $display("TB_CACHE_TAGS FAIL errors=%0d", errors);
        $finish(0);
    end
endmodule
