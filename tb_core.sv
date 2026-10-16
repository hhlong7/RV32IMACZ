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

    int hazard_load_use_count = 0;
    int hazard_pair_issue_count = 0;
    int branch_mispredict_count = 0;
    int trap_commit_count = 0;
    int mret_commit_count = 0;
    int fence_complete_count = 0;
    int atomic_wait_count = 0;
    int lsu_busy_count = 0;

    bit prev_ic_hit = 1'b0;
    bit prev_ic_miss = 1'b0;
    bit prev_dc_hit = 1'b0;
    bit prev_dc_miss = 1'b0;
    bit verbose_lsu = 1'b0;
    bit verbose_pipe = 1'b0;
    bit verbose_mmio = 1'b0;
    bit print_stats = 1'b0;  // +STATS: machine-readable lines for the scripts
    string run_status = "STOPPED";

    // Counters for the end-of-run report (the core's own CSR counters supply
    // cycles, retired instructions, and the HPM events).
    int fetch_count = 0;
    int pair_retire_count = 0;
    int control_count = 0;
    int load_count = 0;
    int l2_hit_count = 0;
    int l2_miss_count = 0;
    int lsu_stall_cycles = 0;

    logic [31:0] last_sseg = 32'b0;
    logic [31:0] last_leds = 32'b0;

    // Optional retirement trace for lockstep comparison against Spike
    // (tools/lockstep.py). One "R pc rd value" line per retired instruction in
    // program order, and one "S addr data size" line per architectural memory
    // write (store-buffer enqueue or atomic commit), in LSU order.
    int commit_fd = 0;
    string commit_log_path;

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
        void'($value$plusargs("MAX_CYCLES=%d", max_cycles));
        pass_sseg_valid = $value$plusargs("PASS_SSEG=%d", pass_sseg);
        fail_sseg_valid = $value$plusargs("FAIL_SSEG=%d", fail_sseg);
        verbose_icache = $test$plusargs("VERBOSE_ICACHE");
        verbose_lsu = $test$plusargs("VERBOSE_LSU");
        verbose_pipe = $test$plusargs("VERBOSE_PIPE");
        verbose_mmio = $test$plusargs("VERBOSE_MMIO");
        print_stats = $test$plusargs("STATS");

        if ($value$plusargs("COMMIT_LOG=%s", commit_log_path)) begin
            commit_fd = $fopen(commit_log_path, "w");
            if (commit_fd == 0)
                $fatal(1, "TB could not open COMMIT_LOG=%s", commit_log_path);
        end

        repeat (8) @(posedge clk);
        reset = 1'b0;
    end

    // Sample at the posedge before the pipeline registers update: a WB slot
    // retires on this edge exactly when it is valid and the LSU is not
    // stalling, the same condition minstret uses. The register file writes on
    // the preceding negedge, so reading it back also proves the write landed.
    function automatic logic [4:0] retired_rd(input logic reg_write, input logic [31:0] ir);
        return reg_write ? ir[11:7] : 5'd0;
    endfunction

    // FP register writes are reported as registers 32-63 (f0-f31).
    task automatic log_retire(input logic [31:0] pc, input logic reg_write, input logic fp_write,
                              input logic [31:0] ir);
        if (fp_write)
            $fdisplay(commit_fd, "R %08x %0d %08x", pc, 32 + ir[11:7], dut.OTTER_FP_REG_FILE.ram[ir[11:7]]);
        else
            $fdisplay(commit_fd, "R %08x %0d %08x", pc, retired_rd(reg_write, ir),
                      dut.OTTER_REG_FILE.ram[retired_rd(reg_write, ir)]);
    endtask

    always @(posedge clk) begin
        if (!reset) begin
            if (dut.hit)
                fetch_count <= fetch_count + 1;
            if (dut.dc_stall)
                lsu_stall_cycles <= lsu_stall_cycles + 1;
            if (!dut.dc_stall) begin
                if (dut.mem_wb_pair.valid)
                    pair_retire_count <= pair_retire_count + 1;
                if (dut.is_branch_ex1 || dut.is_jal_ex1 || dut.is_jalr_ex1)
                    control_count <= control_count + 1;
                if (dut.ex_mem.valid && dut.ex_mem.memRead && !dut.ex_mem.atomic_valid && dut.dcache_cacheable)
                    load_count <= load_count + 1;
            end
            // A refill starts in a stall cycle, so count it outside the gate.
            if (dut.dcache_miss_start) begin
                if (dut.l2_query_hit)
                    l2_hit_count <= l2_hit_count + 1;
                else
                    l2_miss_count <= l2_miss_count + 1;
            end
        end
    end

    always @(posedge clk) begin
        if (commit_fd != 0 && !reset) begin
            if (!dut.dc_stall) begin
                if (dut.mem_wb.valid)
                    log_retire(dut.mem_wb.pc, dut.mem_wb.regWrite, dut.mem_wb.fp_write, dut.mem_wb.ir);
                if (dut.mem_wb_pair.valid)
                    log_retire(dut.mem_wb_pair.pc, dut.mem_wb_pair.regWrite, dut.mem_wb_pair.fp_write, dut.mem_wb_pair.ir);
            end

            if (dut.atomic_commit_valid && dut.atomic_commit_write)
                $fdisplay(commit_fd, "S %08x %08x 2", dut.atomic_commit_addr, dut.atomic_commit_new_word);
            if (dut.storebuf_enqueue_event)
                $fdisplay(commit_fd, "S %08x %08x %0d", dut.ex_mem.alu_result, dut.ex_mem.rs2, dut.mem_size);
        end
    end

    always @(posedge clk) begin
        cycle_count <= cycle_count + 1;
        #1;

        if (!reset) begin
            // Pipeline-hazard correctness checks.
            if (dut.loadUseStall_hz) begin
                if (!dut.stallIF_hz || !dut.stallID_hz || !dut.flushEX_hz) begin
                    $display("ASSERT_FAIL load-use hazard control mismatch cycle=%0d stallIF_hz=%0b stallID_hz=%0b flushEX_hz=%0b",
                             cycle_count, dut.stallIF_hz, dut.stallID_hz, dut.flushEX_hz);
                    $fatal(1);
                end
                hazard_load_use_count <= hazard_load_use_count + 1;
            end

            if (dut.issuePair)
                hazard_pair_issue_count <= hazard_pair_issue_count + 1;

            // FP unit results must line up with the instruction in MEM.
            if (dut.ex_mem.valid && dut.ex_mem.fp_unit == 2'd1 && !dut.fadd_valid) begin
                $display("ASSERT_FAIL fadd in MEM without an adder result cycle=%0d pc=0x%08x", cycle_count, dut.ex_mem.pc);
                $fatal(1);
            end
            if (dut.ex_mem.valid && dut.ex_mem.fp_unit == 2'd2 && !dut.fmul_valid) begin
                $display("ASSERT_FAIL fmul in MEM without a multiplier result cycle=%0d pc=0x%08x", cycle_count, dut.ex_mem.pc);
                $fatal(1);
            end

            // Branch recovery: mispredicts must raise a redirect.
            if (dut.branch_mispredict_ex1 && !dut.redirect_valid_ex1) begin
                $display("ASSERT_FAIL branch mispredict without redirect cycle=%0d pc=0x%08x",
                         cycle_count, dut.id_ex.pc);
                $fatal(1);
            end

            if (dut.branch_mispredict_ex1)
                branch_mispredict_count <= branch_mispredict_count + 1;

            // Cache/front-end handshake consistency checks.
            if (dut.miss && !dut.ic_stall) begin
                $display("ASSERT_FAIL icache miss without ic_stall cycle=%0d pc=0x%08x",
                         cycle_count, dut.pc_out);
                $fatal(1);
            end

            if (dut.hit && dut.miss) begin
                $display("ASSERT_FAIL icache hit/miss both high cycle=%0d pc=0x%08x",
                         cycle_count, dut.pc_out);
                $fatal(1);
            end

            if (dut.dcache_hit && dut.dcache_miss) begin
                $display("ASSERT_FAIL dcache hit/miss both high cycle=%0d addr=0x%08x",
                         cycle_count, dut.ex_mem.alu_result);
                $fatal(1);
            end

            // Trap/CSR correctness checks.
            if (dut.trap_commit_ex1 && dut.mret_commit_ex1) begin
                $display("ASSERT_FAIL trap and mret commit together cycle=%0d pc=0x%08x",
                         cycle_count, dut.id_ex.pc);
                $fatal(1);
            end

            if (dut.interrupt_accept_id && !dut.trap_taken_id) begin
                $display("ASSERT_FAIL interrupt accepted without trap_taken_id cycle=%0d pc=0x%08x",
                         cycle_count, dut.if_id.pc);
                $fatal(1);
            end

            if (dut.trap_commit_ex1)
                trap_commit_count <= trap_commit_count + 1;
            if (dut.mret_commit_ex1)
                mret_commit_count <= mret_commit_count + 1;

            // Memory ordering checks for fence/atomic behavior.
            if (dut.fence_wait_ex1 && !dut.lsu_ordering_busy_ex1) begin
                $display("ASSERT_FAIL fence_wait without lsu_ordering_busy cycle=%0d", cycle_count);
                $fatal(1);
            end

            if (dut.fence_i_wait_ex1 && !dut.lsu_ordering_busy_ex1) begin
                $display("ASSERT_FAIL fence_i_wait without lsu_ordering_busy cycle=%0d", cycle_count);
                $fatal(1);
            end

            if (dut.atomic_commit_valid && (dut.atomic_commit_op == ATOMIC_SC) &&
                (dut.atomic_commit_write != dut.atomic_commit_sc_success)) begin
                $display("ASSERT_FAIL SC write/success mismatch cycle=%0d addr=0x%08x write=%0b sc_success=%0b",
                         cycle_count, dut.atomic_commit_addr,
                         dut.atomic_commit_write, dut.atomic_commit_sc_success);
                $fatal(1);
            end

            if (dut.fence_complete_ex1 || dut.fence_i_complete_ex1)
                fence_complete_count <= fence_complete_count + 1;
            if (dut.atomic_wait_ex1)
                atomic_wait_count <= atomic_wait_count + 1;
            if (dut.lsu_ordering_busy_ex1)
                lsu_busy_count <= lsu_busy_count + 1;

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
            $display("ICACHE cycle=%0d pc=0x%08x hit=%0b miss=%0b line=%0d victim=%0d pref_valid=%0b pref_line=0x%07x pref_hit=%0b pref_only=%0b update=%0b rd=0x%08x",
                     cycle_count, dut.pc_out, dut.hit, dut.miss,
                     dut.OTTER_CACHE.tag_line[0], dut.OTTER_CACHE.victim_line,
                     dut.OTTER_CACHE.prefetch_valid, dut.OTTER_CACHE.prefetch_tag,
                     dut.OTTER_CACHE.prefetch_hit, dut.prefetch_hit_event,
                     dut.cache_update, dut.rd);
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
                if (verbose_mmio)
                    $display("MMIO LEDS cycle=%0d data=0x%08x", cycle_count, dut.mem_din2_dc);
            end else if (dut.mem_addr2_dc == SSEG_ADDR) begin
                last_sseg <= dut.mem_din2_dc;
                if (verbose_mmio)
                    $display("MMIO SSEG cycle=%0d data=0x%08x signed=%0d", cycle_count, dut.mem_din2_dc, $signed(dut.mem_din2_dc));

                if (fail_sseg_valid && ($signed(dut.mem_din2_dc) == fail_sseg)) begin
                    $display("TB FAIL matched fail_sseg=%0d at cycle=%0d", fail_sseg, cycle_count);
                    run_status = "FAIL";
                    $fatal(1);
                end

                if (pass_sseg_valid && ($signed(dut.mem_din2_dc) == pass_sseg)) begin
                    $display("TB PASS matched pass_sseg=%0d at cycle=%0d", pass_sseg, cycle_count);
                    run_status = "PASS";
                    $finish(0);
                end
            end else if (verbose_mmio) begin
                $display("MMIO WRITE cycle=%0d addr=0x%08x data=0x%08x", cycle_count, dut.mem_addr2_dc, dut.mem_din2_dc);
            end
        end

        if (cycle_count >= max_cycles) begin
            $display("TB TIMEOUT cycle=%0d last_sseg=0x%08x last_leds=0x%08x pc=0x%08x if2_ir=0x%08x id_ir=0x%08x ex1_ir=0x%08x ex2_ir=0x%08x mem_ir=0x%08x wb_ir=0x%08x dc_stall=%0b ic_stall=%0b",
                     cycle_count, last_sseg, last_leds, dut.pc_out, dut.if1_if2.ir, dut.if_id.ir, dut.id_ex.ir, dut.ex1_ex2.ir, dut.ex_mem.ir, dut.mem_wb.ir, dut.dc_stall, dut.ic_stall);
            run_status = "TIMEOUT";
            $finish(0);
        end
    end

    function automatic real percent(input longint part, input longint whole);
        return (whole == 0) ? 0.0 : (100.0 * part) / whole;
    endfunction


    // Human-readable end-of-run report (machine-readable lines with +STATS).
    // Cycle, retire, and event counts come from the core's own CSR performance
    // counters (mcycle, minstret, mhpmcounter3..17), so they match what
    // software would read.
    final begin
        if (commit_fd != 0)
            $fclose(commit_fd);

        if (print_stats) begin
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
            $display("TB COV hazard_load_use=%0d pair_issue=%0d branch_mispredict=%0d trap_commit=%0d mret_commit=%0d fence_complete=%0d atomic_wait=%0d lsu_busy=%0d",
                     hazard_load_use_count, hazard_pair_issue_count, branch_mispredict_count,
                     trap_commit_count, mret_commit_count, fence_complete_count,
                     atomic_wait_count, lsu_busy_count);
        end else begin : report
            longint cycles, retired, branch_flushes, load_use, ic_fills, dc_misses;
            longint prefetch_hits, traps, sb_enq, sb_full, sb_fwd, sb_conflict, fence_wait;

            cycles = dut.OTTER_CSR_FILE.counters[0];
            retired = dut.OTTER_CSR_FILE.counters[2];
            branch_flushes = dut.OTTER_CSR_FILE.counters[3];
            load_use = dut.OTTER_CSR_FILE.counters[4];
            ic_fills = dut.OTTER_CSR_FILE.counters[5];
            dc_misses = dut.OTTER_CSR_FILE.counters[6];
            prefetch_hits = dut.OTTER_CSR_FILE.counters[7];
            traps = dut.OTTER_CSR_FILE.counters[9];
            sb_enq = dut.OTTER_CSR_FILE.counters[12];
            sb_full = dut.OTTER_CSR_FILE.counters[13];
            sb_fwd = dut.OTTER_CSR_FILE.counters[14];
            sb_conflict = dut.OTTER_CSR_FILE.counters[15];
            fence_wait = dut.OTTER_CSR_FILE.counters[17];

            $display("");
            $display("==================== OTTER RV32IMAC run report ====================");
            if (run_status == "PASS")
                $display("Result        PASS (pass code %0d at cycle %0d)", pass_sseg, cycle_count);
            else
                $display("Result        %s (last SSEG value %0d at cycle %0d)", run_status, $signed(last_sseg), cycle_count);
            $display("Core          %0d cycles, %0d instructions retired, IPC %0.3f (CPI %0.3f)",
                     cycles, retired, (cycles == 0) ? 0.0 : real'(retired) / cycles,
                     (retired == 0) ? 0.0 : real'(cycles) / retired);
            $display("Dual issue    %0d instructions retired from slot 1 (%0.1f%% of retired)",
                     pair_retire_count, percent(pair_retire_count, retired));
            $display("Branches      %0d control-flow instructions, %0d mispredicted (%0.1f%% predicted correctly)",
                     control_count, branch_flushes, 100.0 - percent(branch_flushes, control_count));
            $display("Stalls        %0d load-use, %0d LSU/cache (%0.1f%% of cycles), %0d store-buffer full, %0d fence wait",
                     load_use, lsu_stall_cycles, percent(lsu_stall_cycles, cycles), sb_full, fence_wait);
            $display("I-cache       %0d fetches, %0d line fills (%0.1f%% hit), %0d next-line prefetch hits",
                     fetch_count, ic_fills, 100.0 - percent(ic_fills, fetch_count), prefetch_hits);
            $display("D-cache       %0d loads, %0d misses (%0.1f%% hit); misses served by L2: %0d, by memory: %0d",
                     load_count, dc_misses, 100.0 - percent(dc_misses, load_count), l2_hit_count, l2_miss_count);
            $display("Store buffer  %0d stores, %0d forwarded to loads, %0d overlap stalls",
                     sb_enq, sb_fwd, sb_conflict);
            $display("Atomics       %0d executed, SC %0d succeeded / %0d failed",
                     atomic_commit_count, atomic_sc_success_count, atomic_sc_fail_count);
            $display("Traps         %0d taken, %0d mret", traps, mret_commit_count);
            $display("===================================================================");
        end
    end
endmodule
