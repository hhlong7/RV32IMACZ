`timescale 1ns / 1ps

module tb_core;
    localparam logic [31:0] LEDS_ADDR = 32'h1100_0020;
    localparam logic [31:0] SSEG_ADDR = 32'h1100_0040;
    localparam logic [3:0] ATOMIC_SC = 4'd2;

    logic clk = 1'b0;
    logic reset = 1'b1;
    logic [31:0] iobus_in = 32'b0;

    logic iobus_wr;
    logic [31:0] iobus_out;
    logic [31:0] iobus_addr;

    int cycle_count = 0;
    int max_cycles = 200000;
    int signed pass_sseg;
    int signed fail_sseg;
    bit pass_sseg_valid = 1'b0;
    bit fail_sseg_valid = 1'b0;
    bit verbose_icache = 1'b0;

    int flush_id_count = 0;
    int flush_ex_count = 0;
    int branch_redirect_count = 0;
    int icache_hit_count = 0;
    int icache_miss_count = 0;
    int icache_prefetch_only_hit_count = 0;
    int dcache_hit_count = 0;
    int dcache_miss_count = 0;
    // These mirror the new store-buffer perf hooks so regressions can surface
    // LSU behavior directly in the textual trace.
    int storebuf_enqueue_count = 0;
    int storebuf_forward_count = 0;
    int storebuf_drain_count = 0;
    int storebuf_full_stall_cycles = 0;
    int storebuf_conflict_stall_cycles = 0;
    int fence_wait_cycles = 0;
    int atomic_commit_count = 0;
    int atomic_write_count = 0;
    int atomic_sc_success_count = 0;
    int atomic_sc_fail_count = 0;
    int reservation_set_count = 0;
    int reservation_clear_count = 0;

    bit prev_ic_hit = 1'b0;
    bit prev_ic_miss = 1'b0;
    bit prev_dc_hit = 1'b0;
    bit prev_dc_miss = 1'b0;
    bit verbose_lsu = 1'b0;
    bit verbose_pipe = 1'b0;

    logic [31:0] last_sseg = 32'b0;
    logic [31:0] last_leds = 32'b0;

    OTTER_MCU dut (
        .CLK(clk),
        .INTR(1'b0),
        .RESET(reset),
        .IOBUS_IN(iobus_in),
        .IOBUS_WR(iobus_wr),
        .IOBUS_OUT(iobus_out),
        .IOBUS_ADDR(iobus_addr)
    );

    always #5 clk = ~clk;

    initial begin
        if ($value$plusargs("MAX_CYCLES=%d", max_cycles))
            $display("TB max_cycles=%0d", max_cycles);

        if ($value$plusargs("PASS_SSEG=%d", pass_sseg)) begin
            pass_sseg_valid = 1'b1;
            $display("TB pass_sseg=%0d", pass_sseg);
        end

        if ($value$plusargs("FAIL_SSEG=%d", fail_sseg)) begin
            fail_sseg_valid = 1'b1;
            $display("TB fail_sseg=%0d", fail_sseg);
        end

        if ($test$plusargs("VERBOSE_ICACHE")) begin
            verbose_icache = 1'b1;
            $display("TB verbose_icache enabled");
        end

        if ($test$plusargs("VERBOSE_LSU")) begin
            verbose_lsu = 1'b1;
            $display("TB verbose_lsu enabled");
        end

        if ($test$plusargs("VERBOSE_PIPE")) begin
            verbose_pipe = 1'b1;
            $display("TB verbose_pipe enabled");
        end

        repeat (8) @(posedge clk);
        reset = 1'b0;
    end

    always @(posedge clk) begin
        cycle_count <= cycle_count + 1;
        #1;

        if (!reset) begin
            if (dut.flushID)
                flush_id_count <= flush_id_count + 1;
            if (dut.flushEX)
                flush_ex_count <= flush_ex_count + 1;
            if (dut.pc_source_id != 3'b000)
                branch_redirect_count <= branch_redirect_count + 1;

            if (dut.hit && !prev_ic_hit)
                icache_hit_count <= icache_hit_count + 1;
            if (dut.miss && !prev_ic_miss)
                icache_miss_count <= icache_miss_count + 1;
            // Count only architecturally consumed prefetch hits; the widened
            // front end may probe ahead speculatively while the queue is full.
            if (dut.prefetch_hit_event)
                icache_prefetch_only_hit_count <= icache_prefetch_only_hit_count + 1;

            if (dut.dcache_hit && !prev_dc_hit)
                dcache_hit_count <= dcache_hit_count + 1;
            if (dut.dcache_miss && !prev_dc_miss)
                dcache_miss_count <= dcache_miss_count + 1;
            if (dut.storebuf_enqueue_event)
                storebuf_enqueue_count <= storebuf_enqueue_count + 1;
            if (dut.storebuf_forward_event)
                storebuf_forward_count <= storebuf_forward_count + 1;
            if (dut.storebuf_drain_event)
                storebuf_drain_count <= storebuf_drain_count + 1;
            if (dut.storebuf_full_stall_event)
                storebuf_full_stall_cycles <= storebuf_full_stall_cycles + 1;
            if (dut.storebuf_conflict_stall_event)
                storebuf_conflict_stall_cycles <= storebuf_conflict_stall_cycles + 1;
            if (dut.fence_wait_event)
                fence_wait_cycles <= fence_wait_cycles + 1;
            if (dut.atomic_commit_valid)
                atomic_commit_count <= atomic_commit_count + 1;
            if (dut.atomic_commit_write)
                atomic_write_count <= atomic_write_count + 1;
            if (dut.atomic_commit_valid && (dut.atomic_commit_op == ATOMIC_SC)) begin
                if (dut.atomic_commit_sc_success)
                    atomic_sc_success_count <= atomic_sc_success_count + 1;
                else
                    atomic_sc_fail_count <= atomic_sc_fail_count + 1;
            end
            if (dut.reservation_set_event)
                reservation_set_count <= reservation_set_count + 1;
            if (dut.reservation_clear_event)
                reservation_clear_count <= reservation_clear_count + 1;

            prev_ic_hit <= dut.hit;
            prev_ic_miss <= dut.miss;
            prev_dc_hit <= dut.dcache_hit;
            prev_dc_miss <= dut.dcache_miss;

            if (dut.atomic_commit_valid) begin
                int atomic_word_idx;
                logic [31:0] expected_word;

                atomic_word_idx = dut.atomic_commit_addr[15:2];
                expected_word = dut.atomic_commit_write ? dut.atomic_commit_new_word :
                                                          dut.atomic_commit_old_word;

                if (dut.OTTER_MEMORY.memory[atomic_word_idx] !== expected_word) begin
                    $display("ATOMIC_VERIFY_FAIL memory addr=0x%08x expected=0x%08x actual=0x%08x op=%0d write=%0b",
                             dut.atomic_commit_addr, expected_word,
                             dut.OTTER_MEMORY.memory[atomic_word_idx],
                             dut.atomic_commit_op, dut.atomic_commit_write);
                    $fatal(1);
                end

                if (dut.atomic_commit_addr < 32'h0001_0000) begin
                    if (dut.OTTER_IMEM.ram[atomic_word_idx] !== expected_word) begin
                        $display("ATOMIC_VERIFY_FAIL imem addr=0x%08x expected=0x%08x actual=0x%08x",
                                 dut.atomic_commit_addr, expected_word,
                                 dut.OTTER_IMEM.ram[atomic_word_idx]);
                        $fatal(1);
                    end

                    if (dut.OTTER_IMEM_PREFETCH.ram[atomic_word_idx] !== expected_word) begin
                        $display("ATOMIC_VERIFY_FAIL prefetch_imem addr=0x%08x expected=0x%08x actual=0x%08x",
                                 dut.atomic_commit_addr, expected_word,
                                 dut.OTTER_IMEM_PREFETCH.ram[atomic_word_idx]);
                        $fatal(1);
                    end
                end
            end
        end

        if (verbose_icache && !reset) begin
            $display("ICACHE cycle=%0d pc=0x%08x idx=%0d off=%0d hit=%0b miss=%0b pref_valid=%0b pref_idx=%0d pref_hit=%0b pref_only=%0b update=%0b way_hit=%b v00=%0b v01=%0b v02=%0b rd=0x%08x",
                     cycle_count, dut.pc_out, dut.OTTER_CACHE.index, dut.OTTER_CACHE.pc_offset,
                     dut.hit, dut.miss, dut.OTTER_CACHE.prefetch_valid, dut.OTTER_CACHE.prefetch_index,
                     dut.OTTER_CACHE.prefetch_hit, dut.prefetch_hit_event,
                     dut.cache_update, dut.OTTER_CACHE.way_hit,
                     dut.OTTER_CACHE.valid_bits[0][0],
                     dut.OTTER_CACHE.valid_bits[0][1],
                     dut.OTTER_CACHE.valid_bits[0][2],
                     dut.rd);
        end

        if (verbose_lsu && !reset) begin
            if (dut.storebuf_enqueue_event)
                $display("SB_ENQ cycle=%0d addr=0x%08x data=0x%08x mask=%b occ=%0d",
                         cycle_count, dut.ex_mem.alu_result, dut.ex_mem.rs2, dut.storebuf_enqueue_mask, dut.storebuf_occupancy);
            if (dut.storebuf_forward_event)
                $display("SB_FWD cycle=%0d addr=0x%08x data=0x%08x occ=%0d",
                         cycle_count, dut.ex_mem.alu_result, dut.storebuf_forward_data, dut.storebuf_occupancy);
            if (dut.storebuf_drain_event)
                $display("SB_DRN cycle=%0d addr=0x%08x data=0x%08x mask=%b occ=%0d",
                         cycle_count, dut.storebuf_drain_addr, dut.storebuf_drain_data, dut.storebuf_drain_mask, dut.storebuf_occupancy);
            if (dut.fence_wait_event)
                $display("FENCE_WAIT cycle=%0d occ=%0d dc_busy=%0b", cycle_count, dut.storebuf_occupancy, dut.dcache_busy);
            if (dut.atomic_commit_valid)
                $display("ATOMIC cycle=%0d op=%0d addr=0x%08x old=0x%08x new=0x%08x write=%0b sc_ok=%0b res_valid=%0b",
                         cycle_count, dut.atomic_commit_op, dut.atomic_commit_addr,
                         dut.atomic_commit_old_word, dut.atomic_commit_new_word,
                         dut.atomic_commit_write, dut.atomic_commit_sc_success,
                         dut.reservation_valid_q);
            if (dut.reservation_set_event)
                $display("RES_SET cycle=%0d addr=0x%08x", cycle_count, dut.atomic_commit_addr);
            if (dut.reservation_clear_event && !dut.reservation_set_event)
                $display("RES_CLR cycle=%0d", cycle_count);
        end

        if (verbose_pipe && !reset) begin
            // Show both issue slots so dual-issue bring-up can confirm that the
            // younger slot only appears when the pairing rules expect it.
            $display("PIPE cycle=%0d pc=0x%08x if2_pc=0x%08x if2=0x%08x id_pc=0x%08x id=0x%08x ex1_pc=0x%08x ex1=0x%08x ex1_2=0x%08x ex2=0x%08x ex2_2=0x%08x mem=0x%08x wb=0x%08x x5=0x%08x x25=0x%08x x28=0x%08x x29=0x%08x x31=0x%08x rs1f=0x%08x rs2f=0x%08x beq=%0b pcsrcb=%0b redirect=%0b target=0x%08x fence_wait=%0b drain=%0b",
                     cycle_count, dut.pc_out, dut.if1_if2.pc, dut.if1_if2.ir, dut.if_id.pc, dut.if_id.ir, dut.id_ex.pc, dut.id_ex.ir, dut.id_ex_pair.ir, dut.ex1_ex2.ir, dut.ex1_ex2_pair.ir, dut.ex_mem.ir, dut.mem_wb.ir,
                     dut.OTTER_REG_FILE.ram[5], dut.OTTER_REG_FILE.ram[25], dut.OTTER_REG_FILE.ram[28], dut.OTTER_REG_FILE.ram[29], dut.OTTER_REG_FILE.ram[31],
                     dut.rs1f, dut.rs2f, dut.OTTER_BRANCH_GEN_EX1.beq, dut.pc_source_branch_ex1, dut.redirect_valid_ex1, dut.redirect_target_ex1, dut.fence_wait_event, dut.storebuf_drain_event);
        end

        if (dut.OTTER_MEMORY.IO_WR) begin
            if (dut.mem_addr2_dc == LEDS_ADDR) begin
                last_leds <= dut.mem_din2_dc;
                $display("MMIO LEDS cycle=%0d data=0x%08x", cycle_count, dut.mem_din2_dc);
            end else if (dut.mem_addr2_dc == SSEG_ADDR) begin
                last_sseg <= dut.mem_din2_dc;
                $display("MMIO SSEG cycle=%0d data=0x%08x signed=%0d", cycle_count, dut.mem_din2_dc, $signed(dut.mem_din2_dc));

                if (fail_sseg_valid && ($signed(dut.mem_din2_dc) == fail_sseg)) begin
                    $display("TB FAIL matched fail_sseg=%0d at cycle=%0d", fail_sseg, cycle_count);
                    $fatal(1);
                end

                if (pass_sseg_valid && ($signed(dut.mem_din2_dc) == pass_sseg)) begin
                    $display("TB PASS matched pass_sseg=%0d at cycle=%0d", pass_sseg, cycle_count);
                    $finish;
                end
            end else begin
                $display("MMIO WRITE cycle=%0d addr=0x%08x data=0x%08x", cycle_count, dut.mem_addr2_dc, dut.mem_din2_dc);
            end
        end

        if (cycle_count >= max_cycles) begin
            $display("TB TIMEOUT cycle=%0d last_sseg=0x%08x last_leds=0x%08x pc=0x%08x if2_ir=0x%08x id_ir=0x%08x ex1_ir=0x%08x ex2_ir=0x%08x mem_ir=0x%08x wb_ir=0x%08x dc_stall=%0b ic_stall=%0b",
                     cycle_count, last_sseg, last_leds, dut.pc_out, dut.if1_if2.ir, dut.if_id.ir, dut.id_ex.ir, dut.ex1_ex2.ir, dut.ex_mem.ir, dut.mem_wb.ir, dut.dc_stall, dut.ic_stall);
            $finish;
        end
    end

    final begin
        $display("TB FINAL cycle=%0d last_sseg=0x%08x signed=%0d last_leds=0x%08x",
                 cycle_count, last_sseg, $signed(last_sseg), last_leds);
        $display("TB STATS branch_redirects=%0d flush_id=%0d flush_ex=%0d ic_hit=%0d ic_miss=%0d ic_prefetch_only=%0d dc_hit=%0d dc_miss=%0d",
                 branch_redirect_count, flush_id_count, flush_ex_count, icache_hit_count,
                 icache_miss_count, icache_prefetch_only_hit_count, dcache_hit_count, dcache_miss_count);
        $display("TB LSU sb_enq=%0d sb_fwd=%0d sb_drain=%0d sb_full_stall=%0d sb_conflict_stall=%0d fence_wait=%0d",
                 storebuf_enqueue_count, storebuf_forward_count, storebuf_drain_count,
                 storebuf_full_stall_cycles, storebuf_conflict_stall_cycles, fence_wait_cycles);
        $display("TB ATOM commits=%0d writes=%0d sc_success=%0d sc_fail=%0d res_set=%0d res_clear=%0d",
                 atomic_commit_count, atomic_write_count, atomic_sc_success_count,
                 atomic_sc_fail_count, reservation_set_count, reservation_clear_count);
    end
endmodule
