`timescale 1ns / 1ps

// Testbench for the out-of-order OTTER core.
//
//   +PASS_SSEG=N / +FAIL_SSEG=N   stop when the program writes N to the
//                                 seven-segment register
//   +MAX_CYCLES=N                 time out after N cycles
//   +COMMIT_LOG=file              retirement trace for tools/lockstep.py
//   +VERBOSE_COMMIT               print every committed instruction
//   +VERBOSE_LSU                  print store-buffer and atomic events
//   +VERBOSE_MMIO                 print every MMIO write
//   +STATS                        machine-readable TB lines instead of the report
module tb_core;
    import ooo_pkg::*;

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
    bit pass_sseg_valid, fail_sseg_valid;
    bit verbose_commit, verbose_lsu, verbose_mmio, print_stats;
    string run_status = "STOPPED";

    logic [31:0] last_sseg = 32'b0;
    logic [31:0] last_leds = 32'b0;

    // Event counters (the core's CSR counters supply cycles, retired
    // instructions, and the HPM events).
    int fetch_count, load_count, l2_hit_count, l2_miss_count, dcache_hit_count;
    int dual_dispatch_count, dual_commit_count, rob_full_cycles, lsu_busy_cycles;
    int branch_unit_count, cdb_conflict_cycles, mispredict_count, flush_count;
    int trap_count, interrupt_count, mret_count, fence_wait_cycles;
    int storebuf_enqueue_count, storebuf_forward_count, storebuf_drain_count;
    int storebuf_full_cycles, storebuf_conflict_cycles, sq_forward_count;
    int atomic_commit_count, atomic_write_count, atomic_sc_success_count, atomic_sc_fail_count;
    int reservation_set_count, reservation_clear_count;
    // Branch-recovery coverage: what each squash actually removed.
    int rec_store_squash, rec_load_squash, rec_memq_squash, rec_fp_squash, rec_fdiv_kill;
    int rec_nested, rec_rs_squash;
    // Dispatch-stall attribution (first matching cause per cycle).
    int st_recover, st_serial, st_intr, st_rob, st_rs_alu, st_rs_br, st_rs_mem, st_rs_fp, st_other;
    int fe_empty_cycles, slot1_empty_cycles, slot1_blocked_cycles;
    // Mispredict types: conditional branch predicted not-taken / taken
    // wrongly, jal, return (jalr via the RAS), other jalr.
    int mp_br_nt, mp_br_t, mp_jal, mp_ret, mp_jalr;

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
        verbose_commit = $test$plusargs("VERBOSE_COMMIT");
        verbose_lsu = $test$plusargs("VERBOSE_LSU");
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

    // ---- Retirement trace ---------------------------------------------------
    // Sampled at the posedge before state updates: a ROB entry retires on this
    // edge when commit0/commit1 is high, and the register file was written on
    // the preceding negedge. The logged value is the write-port data; reading
    // the array back also proves the write landed, except for a slot-0 write
    // that slot 1 overwrote in the same cycle. FP registers are reported as 32-63.
    task automatic log_retire(input rob_entry_t e, input logic [31:0] written, input bit shadowed);
        int rd_id;
        logic [31:0] value, stored;
        rd_id = 0;
        value = 32'b0;
        stored = 32'b0;
        if (e.wr_fp) begin
            rd_id = 32 + e.rd;
            value = written;
            stored = dut.OTTER_FP_REG_FILE.ram[e.rd];
        end else if (e.wr_int) begin
            rd_id = e.rd;
            value = written;
            stored = dut.OTTER_REG_FILE.ram[e.rd];
        end
        if ((e.wr_fp || e.wr_int) && !shadowed && stored !== value)
            $display("ASSERT_FAIL register write did not land pc=0x%08x rd=%0d port=0x%08x array=0x%08x",
                     e.pc, rd_id, value, stored);
        if (commit_fd != 0)
            $fdisplay(commit_fd, "R %08x %0d %08x", e.pc, rd_id, value);
        if (verbose_commit)
            $display("COMMIT cycle=%0d pc=0x%08x ir=0x%08x rd=%0d value=0x%08x", cycle_count, e.pc, e.ir, rd_id, value);
    endtask

    always @(posedge clk) begin
        if (!reset) begin
            if (dut.commit0)
                log_retire(dut.h0, dut.h0.wr_fp ? dut.h0.value : dut.commit0_value,
                           dut.commit1 && dut.h0.rd == dut.h1.rd &&
                           ((dut.h0.wr_int && dut.h1.wr_int) || (dut.h0.wr_fp && dut.h1.wr_fp)));
            if (dut.commit1) log_retire(dut.h1, dut.h1.value, 1'b0);
            if (commit_fd != 0) begin
                if (dut.atomic_commit_valid && dut.atomic_commit_write)
                    $fdisplay(commit_fd, "S %08x %08x 2", dut.atomic_commit_addr, dut.atomic_commit_new_word);
                if (dut.lsu_commit_store)
                    $fdisplay(commit_fd, "S %08x %08x %0d", dut.OTTER_LSU.sq_oldest.addr,
                              dut.OTTER_LSU.sq_oldest.data, dut.OTTER_LSU.sq_oldest.size);
            end
        end
    end

    // ---- Event counting and checks -------------------------------------------
    always @(posedge clk) begin
        cycle_count <= cycle_count + 1;
        if (!reset) begin
            if (dut.commit1 && !dut.commit0) begin
                $display("ASSERT_FAIL second commit without the first cycle=%0d", cycle_count);
                $fatal(1);
            end
            if (dut.trap_take && dut.mret_commit) begin
                $display("ASSERT_FAIL trap and mret together cycle=%0d", cycle_count);
                $fatal(1);
            end
            if (dut.atomic_commit_valid && (dut.atomic_commit_op == ATOMIC_SC) &&
                (dut.atomic_commit_write != dut.atomic_commit_sc_success)) begin
                $display("ASSERT_FAIL SC write/success mismatch cycle=%0d", cycle_count);
                $fatal(1);
            end
            if (dut.atomic_commit_valid) begin
                logic [31:0] expected;
                expected = dut.atomic_commit_write ? dut.atomic_commit_new_word : dut.atomic_commit_old_word;
                if (dut.OTTER_MEMORY.memory[dut.atomic_commit_addr[15:2]] !== expected) begin
                    $display("ATOMIC_VERIFY_FAIL addr=0x%08x expected=0x%08x", dut.atomic_commit_addr, expected);
                    $fatal(1);
                end
            end

            if (dut.hit) fetch_count <= fetch_count + 1;
            if (dut.load_complete_event) load_count <= load_count + 1;
            if (dut.dcache_hit_event) dcache_hit_count <= dcache_hit_count + 1;
            if (dut.dcache_miss_start) begin
                if (dut.l2_hit_event) l2_hit_count <= l2_hit_count + 1;
                else l2_miss_count <= l2_miss_count + 1;
            end
            if (dut.dispatch1) dual_dispatch_count <= dual_dispatch_count + 1;
            if (dut.commit1) dual_commit_count <= dual_commit_count + 1;
            if (dut.if_id.valid && dut.rob_free == 0) rob_full_cycles <= rob_full_cycles + 1;
            if (dut.lsu_busy) lsu_busy_cycles <= lsu_busy_cycles + 1;
            if (dut.cdb_grant[1]) branch_unit_count <= branch_unit_count + 1;
            if ($countones(dut.cdb_req_valid) > 3) cdb_conflict_cycles <= cdb_conflict_cycles + 1;
            if (dut.branch_recover) mispredict_count <= mispredict_count + 1;
            if (dut.branch_recover) begin
                if (dut.br_e.ir[6:0] == 7'b1100011) begin
                    if (dut.br_e.predicted_taken) mp_br_t <= mp_br_t + 1;
                    else mp_br_nt <= mp_br_nt + 1;
                end else if (dut.br_e.ir[6:0] == 7'b1101111) mp_jal <= mp_jal + 1;
                else if (dut.br_e.ir[11:7] == 5'd0 && (dut.br_e.ir[19:15] == 5'd1 || dut.br_e.ir[19:15] == 5'd5)) mp_ret <= mp_ret + 1;
                else mp_jalr <= mp_jalr + 1;
            end
            if (!dut.if_id.valid) begin
                fe_empty_cycles <= fe_empty_cycles + 1;
            end else if (!dut.dispatch0) begin
                if (dut.flush || dut.branch_recover) st_recover <= st_recover + 1;
                else if (dut.serial_in_flight || (dut.sys[0] != 3'd0 && dut.rob_count != 0)) st_serial <= st_serial + 1;
                else if (dut.csr_interrupt_pending) st_intr <= st_intr + 1;
                else if (dut.rob_free == 0) st_rob <= st_rob + 1;
                else if (dut.cls[0] == ooo_pkg::CLS_ALU && dut.free_alu == 0) st_rs_alu <= st_rs_alu + 1;
                else if (dut.cls[0] == ooo_pkg::CLS_BRANCH && (dut.free_br == 0 || !dut.ckpt_avail)) st_rs_br <= st_rs_br + 1;
                else if (dut.cls[0] == ooo_pkg::CLS_MEM && dut.free_mem == 0) st_rs_mem <= st_rs_mem + 1;
                else if ((dut.cls[0] == ooo_pkg::CLS_FPADD && dut.free_fadd == 0) ||
                         (dut.cls[0] == ooo_pkg::CLS_FPMUL && dut.free_fmul == 0) ||
                         (dut.cls[0] == ooo_pkg::CLS_FPDIV && dut.free_fdiv == 0)) st_rs_fp <= st_rs_fp + 1;
                else st_other <= st_other + 1;
            end else if (!dut.dispatch1) begin
                if (!dut.if1_if2.valid) slot1_empty_cycles <= slot1_empty_cycles + 1;
                else slot1_blocked_cycles <= slot1_blocked_cycles + 1;
            end
            if (dut.branch_recover) begin : recovery_cov
                ooo_pkg::tag_t rt, hd;
                bit memq, rs, nested;
                rt = dut.recover_tag;
                hd = dut.rob_head;
                if (dut.OTTER_LSU.sq_keep < dut.OTTER_LSU.sq_count) rec_store_squash <= rec_store_squash + 1;
                if (dut.OTTER_LSU.ld.valid && tag_younger(dut.OTTER_LSU.ld.tag, rt, hd)) rec_load_squash <= rec_load_squash + 1;
                if ((dut.fadd_live1 && tag_younger(dut.fadd_tag1, rt, hd)) || (dut.fadd_valid && dut.fadd_live2 && tag_younger(dut.fadd_tag2, rt, hd)) ||
                    (dut.fmul_live1 && tag_younger(dut.fmul_tag1, rt, hd)) || (dut.fmul_valid && dut.fmul_live2 && tag_younger(dut.fmul_tag2, rt, hd)))
                    rec_fp_squash <= rec_fp_squash + 1;
                if (dut.fdiv_kill) rec_fdiv_kill <= rec_fdiv_kill + 1;
                memq = 1'b0;
                for (int i = 0; i < $size(dut.OTTER_LSU.MEMQ.slots); i++)
                    if (dut.OTTER_LSU.MEMQ.slots[i].valid && tag_younger(dut.OTTER_LSU.MEMQ.slots[i].tag, rt, hd)) memq = 1'b1;
                if (memq) rec_memq_squash <= rec_memq_squash + 1;
                rs = 1'b0;
                for (int i = 0; i < $size(dut.RS_ALU.slots); i++)
                    if (dut.RS_ALU.slots[i].valid && tag_younger(dut.RS_ALU.slots[i].tag, rt, hd)) rs = 1'b1;
                if (rs) rec_rs_squash <= rec_rs_squash + 1;
                nested = 1'b0;
                for (int k = 0; k < ooo_pkg::CKPTS; k++)
                    if (dut.ckpt_used[k] && tag_younger(dut.ckpt_owner[k], rt, hd)) nested = 1'b1;
                if (nested) rec_nested <= rec_nested + 1;
            end
            if (dut.flush || dut.branch_recover) flush_count <= flush_count + 1;
            if (dut.trap_take) trap_count <= trap_count + 1;
            if (dut.interrupt_take) interrupt_count <= interrupt_count + 1;
            if (dut.mret_commit) mret_count <= mret_count + 1;
            // Same as the hardware counter: a fence waiting at dispatch for older
            // instructions, or at commit for the store buffer to drain.
            if (dut.fence_wait || dut.fence_dispatch_wait) fence_wait_cycles <= fence_wait_cycles + 1;
            if (dut.storebuf_enqueue_event) storebuf_enqueue_count <= storebuf_enqueue_count + 1;
            if (dut.storebuf_forward_event) storebuf_forward_count <= storebuf_forward_count + 1;
            if (dut.OTTER_LSU.sq_forward_take) sq_forward_count <= sq_forward_count + 1;
            if (dut.storebuf_drain_event) storebuf_drain_count <= storebuf_drain_count + 1;
            if (dut.h0_ready_store_blocked) storebuf_full_cycles <= storebuf_full_cycles + 1;
            if (dut.storebuf_conflict_event) storebuf_conflict_cycles <= storebuf_conflict_cycles + 1;
            if (dut.atomic_commit_valid) begin
                atomic_commit_count <= atomic_commit_count + 1;
                if (dut.atomic_commit_write) atomic_write_count <= atomic_write_count + 1;
                if (dut.atomic_commit_op == ATOMIC_SC) begin
                    if (dut.atomic_commit_sc_success) atomic_sc_success_count <= atomic_sc_success_count + 1;
                    else atomic_sc_fail_count <= atomic_sc_fail_count + 1;
                end
            end
            if (dut.reservation_set_event) reservation_set_count <= reservation_set_count + 1;
            if (dut.reservation_clear_event) reservation_clear_count <= reservation_clear_count + 1;

            if (verbose_lsu) begin
                if (dut.storebuf_enqueue_event)
                    $display("SB_ENQ cycle=%0d addr=0x%08x data=0x%08x", cycle_count,
                             dut.OTTER_LSU.sq_oldest.addr, dut.OTTER_LSU.sq_oldest.data);
                if (dut.atomic_commit_valid)
                    $display("ATOMIC cycle=%0d op=%0d addr=0x%08x old=0x%08x new=0x%08x write=%0b",
                             cycle_count, dut.atomic_commit_op, dut.atomic_commit_addr,
                             dut.atomic_commit_old_word, dut.atomic_commit_new_word, dut.atomic_commit_write);
            end
        end
    end

    // ---- MMIO monitor (pass/fail via the seven-segment register) -------------
    always @(posedge clk) begin
        #1;
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
            $display("TB TIMEOUT cycle=%0d last_sseg=0x%08x pc=0x%08x rob_count=%0d head_pc=0x%08x head_done=%0b",
                     cycle_count, last_sseg, dut.pc_out, dut.rob_count, dut.h0.pc, dut.h0.done);
            run_status = "TIMEOUT";
            $finish(0);
        end
    end

    function automatic real percent(input longint part, input longint whole);
        return (whole == 0) ? 0.0 : (100.0 * part) / whole;
    endfunction

    // ---- End of run ------------------------------------------------------------
    // Cycle, retire, and HPM event counts come from the core's own CSR counters
    // (mcycle, minstret, mhpmcounter3..17), so they match what software reads.
    // ---- Microarchitectural invariants (every cycle) -----------------------
    // Spike only sees architectural results; these catch bookkeeping bugs that
    // lucky timing would hide: a stale rename, a lost wake-up, a leaked
    // checkpoint or store-queue entry. Failures print ASSERT_FAIL (the
    // regression and lockstep flows fail on it); the first 20 are reported.
    int inv_fail_count = 0;

    function automatic bit rob_live(ooo_pkg::tag_t t);
        // t names an allocated ROB entry (inside [head, head + used)).
        rob_live = (ooo_pkg::tag_t'(t - dut.OTTER_ROB.head) < dut.OTTER_ROB.used) &&
                   dut.OTTER_ROB.entries[t].valid;
    endfunction

    task automatic inv_fail(input string what);
        if (inv_fail_count < 20)
            $display("ASSERT_FAIL invariant %s cycle=%0d", what, cycle_count);
        inv_fail_count++;
    endtask

    // A reservation-station entry must belong to a live, unfinished ROB entry;
    // a source still waiting must name a live, unfinished, older producer.
    `define CHECK_RS(rs, name) \
        for (int i = 0; i < $size(rs.slots); i++) begin \
            if (rs.slots[i].valid) begin \
                if (!rob_live(rs.slots[i].tag) || dut.OTTER_ROB.entries[rs.slots[i].tag].done) \
                    inv_fail($sformatf("%s[%0d] tag %0d not a live unfinished ROB entry", name, i, rs.slots[i].tag)); \
                if (!rs.slots[i].src1_ready && (!rob_live(rs.slots[i].src1_tag) || \
                    dut.OTTER_ROB.entries[rs.slots[i].src1_tag].done || \
                    ooo_pkg::tag_age(rs.slots[i].src1_tag, dut.rob_head) >= ooo_pkg::tag_age(rs.slots[i].tag, dut.rob_head))) \
                    inv_fail($sformatf("%s[%0d] waits on src1 tag %0d that will never broadcast", name, i, rs.slots[i].src1_tag)); \
                if (!rs.slots[i].src2_ready && (!rob_live(rs.slots[i].src2_tag) || \
                    dut.OTTER_ROB.entries[rs.slots[i].src2_tag].done || \
                    ooo_pkg::tag_age(rs.slots[i].src2_tag, dut.rob_head) >= ooo_pkg::tag_age(rs.slots[i].tag, dut.rob_head))) \
                    inv_fail($sformatf("%s[%0d] waits on src2 tag %0d that will never broadcast", name, i, rs.slots[i].src2_tag)); \
            end \
        end

    always @(posedge clk) begin
        if (!reset) begin : invariants
            int live;
            ooo_pkg::tag_t t;
            // ROB: occupancy matches the valid entries, all inside the window.
            live = 0;
            for (int i = 0; i < ooo_pkg::ROB_SIZE; i++) begin
                bit in_window;
                in_window = ooo_pkg::tag_t'(ooo_pkg::tag_t'(i) - dut.OTTER_ROB.head) < dut.OTTER_ROB.used;
                if (dut.OTTER_ROB.entries[i].valid) live++;
                if (dut.OTTER_ROB.entries[i].valid != in_window)
                    inv_fail($sformatf("ROB entry %0d valid=%0d but in-window=%0d", i, dut.OTTER_ROB.entries[i].valid, in_window));
            end
            if (live != dut.OTTER_ROB.used)
                inv_fail($sformatf("ROB used=%0d but %0d valid entries", dut.OTTER_ROB.used, live));

            // Rename table: a busy register names a live entry that writes it.
            for (int r = 1; r < 64; r++) begin
                if (dut.OTTER_RAT.busy[r]) begin
                    t = dut.OTTER_RAT.tags[r];
                    if (!rob_live(t) || dut.OTTER_ROB.entries[t].rd != r[4:0] ||
                        (r >= 32 ? !dut.OTTER_ROB.entries[t].wr_fp : !dut.OTTER_ROB.entries[t].wr_int))
                        inv_fail($sformatf("RAT reg %0d busy on tag %0d which does not write it", r, t));
                end
            end
            if (dut.OTTER_RAT.busy[0])
                inv_fail("RAT x0 busy");

            `CHECK_RS(dut.RS_ALU, "RS_ALU")
            `CHECK_RS(dut.RS_BR, "RS_BR")
            `CHECK_RS(dut.RS_FADD, "RS_FADD")
            `CHECK_RS(dut.RS_FMUL, "RS_FMUL")
            `CHECK_RS(dut.RS_FDIV, "RS_FDIV")
            `CHECK_RS(dut.OTTER_LSU.MEMQ, "MEMQ")

            // Store queue: live stores, oldest first.
            for (int i = 0; i < dut.OTTER_LSU.sq_count; i++) begin
                ooo_pkg::tag_t st;
                st = dut.OTTER_LSU.sq[(int'(dut.OTTER_LSU.sq_head) + i) % $size(dut.OTTER_LSU.sq)].tag;
                if (!rob_live(st) || !dut.OTTER_ROB.entries[st].is_store)
                    inv_fail($sformatf("store queue entry %0d tag %0d is not a live store", i, st));
                if (i > 0 && ooo_pkg::tag_age(st, dut.rob_head) <=
                    ooo_pkg::tag_age(dut.OTTER_LSU.sq[(int'(dut.OTTER_LSU.sq_head) + i - 1) % $size(dut.OTTER_LSU.sq)].tag, dut.rob_head))
                    inv_fail($sformatf("store queue out of program order at entry %0d", i));
            end

            // Load in flight (unless squashed) belongs to a live, unfinished load.
            if (dut.OTTER_LSU.ld.valid && !dut.OTTER_LSU.ld.squashed &&
                (!rob_live(dut.OTTER_LSU.ld.tag) || dut.OTTER_ROB.entries[dut.OTTER_LSU.ld.tag].done))
                inv_fail($sformatf("load stage tag %0d not a live unfinished load", dut.OTTER_LSU.ld.tag));

            // Checkpoints: held only by live, unresolved control instructions.
            for (int k = 0; k < ooo_pkg::CKPTS; k++) begin
                if (dut.ckpt_used[k] && (!rob_live(dut.ckpt_owner[k]) ||
                    !dut.OTTER_ROB.entries[dut.ckpt_owner[k]].is_control ||
                    dut.OTTER_ROB.entries[dut.ckpt_owner[k]].done))
                    inv_fail($sformatf("checkpoint %0d held by tag %0d, not a live unresolved branch", k, dut.ckpt_owner[k]));
            end

            // CDBs: distinct tags, each a live unfinished entry.
            if (dut.cdb0.valid && (!rob_live(dut.cdb0.tag) || dut.OTTER_ROB.entries[dut.cdb0.tag].done))
                inv_fail($sformatf("CDB0 broadcasts tag %0d, not live and unfinished", dut.cdb0.tag));
            if (dut.cdb1.valid && (!rob_live(dut.cdb1.tag) || dut.OTTER_ROB.entries[dut.cdb1.tag].done))
                inv_fail($sformatf("CDB1 broadcasts tag %0d, not live and unfinished", dut.cdb1.tag));
            if (dut.cdb2.valid && (!rob_live(dut.cdb2.tag) || dut.OTTER_ROB.entries[dut.cdb2.tag].done))
                inv_fail($sformatf("CDB2 broadcasts tag %0d, not live and unfinished", dut.cdb2.tag));
            if ((dut.cdb0.valid && dut.cdb1.valid && dut.cdb0.tag == dut.cdb1.tag) ||
                (dut.cdb0.valid && dut.cdb2.valid && dut.cdb0.tag == dut.cdb2.tag) ||
                (dut.cdb1.valid && dut.cdb2.valid && dut.cdb1.tag == dut.cdb2.tag))
                inv_fail("two CDBs broadcast the same tag");
        end
    end

    final begin
        if (commit_fd != 0)
            $fclose(commit_fd);

        if (print_stats) begin
            $display("TB FINAL cycle=%0d last_sseg=0x%08x signed=%0d last_leds=0x%08x retired=%0d",
                     cycle_count, last_sseg, $signed(last_sseg), last_leds, dut.OTTER_CSR_FILE.counters[2]);
            $display("TB STATS flushes=%0d mispredicts=%0d ic_fetch=%0d ic_fill=%0d ic_prefetch=%0d dc_hit=%0d dc_miss=%0d l2_hit=%0d",
                     flush_count, mispredict_count, fetch_count, dut.OTTER_CSR_FILE.counters[5],
                     dut.OTTER_CSR_FILE.counters[7], dcache_hit_count, l2_hit_count + l2_miss_count, l2_hit_count);
            $display("TB LSU sb_enq=%0d sb_fwd=%0d sb_drain=%0d sb_full_stall=%0d sb_conflict_stall=%0d fence_wait=%0d sq_fwd=%0d",
                     storebuf_enqueue_count, storebuf_forward_count, storebuf_drain_count,
                     storebuf_full_cycles, storebuf_conflict_cycles, fence_wait_cycles, sq_forward_count);
            $display("TB ATOM commits=%0d writes=%0d sc_success=%0d sc_fail=%0d res_set=%0d res_clear=%0d",
                     atomic_commit_count, atomic_write_count, atomic_sc_success_count,
                     atomic_sc_fail_count, reservation_set_count, reservation_clear_count);
            $display("TB REC recoveries=%0d store_squash=%0d load_squash=%0d memq_squash=%0d rs_squash=%0d fp_squash=%0d fdiv_kill=%0d nested=%0d",
                     mispredict_count, rec_store_squash, rec_load_squash, rec_memq_squash, rec_rs_squash,
                     rec_fp_squash, rec_fdiv_kill, rec_nested);
            $display("TB STALL recover=%0d serial=%0d intr=%0d rob=%0d rs_alu=%0d rs_br=%0d rs_mem=%0d rs_fp=%0d other=%0d fe_empty=%0d slot1_empty=%0d slot1_blocked=%0d",
                     st_recover, st_serial, st_intr, st_rob, st_rs_alu, st_rs_br, st_rs_mem, st_rs_fp, st_other,
                     fe_empty_cycles, slot1_empty_cycles, slot1_blocked_cycles);
            $display("TB OOO dual_dispatch=%0d dual_commit=%0d dispatch_stall=%0d rob_full=%0d lsu_busy=%0d cdb_conflict=%0d traps=%0d mrets=%0d",
                     dual_dispatch_count, dual_commit_count, dut.OTTER_CSR_FILE.counters[4], rob_full_cycles,
                     lsu_busy_cycles, cdb_conflict_cycles, trap_count, mret_count);
        end else begin : report
            longint cycles, retired;
            cycles = dut.OTTER_CSR_FILE.counters[0];
            retired = dut.OTTER_CSR_FILE.counters[2];

            $display("");
            $display("================ OTTER RV32IMAC out-of-order run report ================");
            if (run_status == "PASS")
                $display("Result        PASS (pass code %0d at cycle %0d)", pass_sseg, cycle_count);
            else
                $display("Result        %s (last SSEG value %0d at cycle %0d)", run_status, $signed(last_sseg), cycle_count);
            $display("Core          %0d cycles, %0d instructions retired, IPC %0.3f (CPI %0.3f)",
                     cycles, retired, (cycles == 0) ? 0.0 : real'(retired) / cycles,
                     (retired == 0) ? 0.0 : real'(cycles) / retired);
            $display("Dispatch      %0d two-wide dispatches, %0d stall cycles (ROB full %0d)",
                     dual_dispatch_count, dut.OTTER_CSR_FILE.counters[4], rob_full_cycles);
            $display("Stall causes  slot 0: recover %0d, serialize %0d, interrupt %0d, ROB %0d, ALU RS %0d, branch RS %0d, mem queue %0d, FP RS %0d, other %0d",
                     st_recover, st_serial, st_intr, st_rob, st_rs_alu, st_rs_br, st_rs_mem, st_rs_fp, st_other);
            $display("Front end     %0d cycles with no instruction to dispatch; slot 1 lost: %0d empty, %0d blocked",
                     fe_empty_cycles, slot1_empty_cycles, slot1_blocked_cycles);
            $display("Commit        %0d two-wide commits (%0.1f%% of retired instructions)",
                     dual_commit_count, percent(2 * dual_commit_count, retired));
            $display("Branches      %0d control-flow instructions, %0d mispredicted (%0.1f%% predicted correctly)",
                     branch_unit_count, mispredict_count, 100.0 - percent(mispredict_count, branch_unit_count));
            $display("Mispredicts   branch predicted not-taken %0d, predicted taken %0d; jal %0d; return %0d; other jalr %0d",
                     mp_br_nt, mp_br_t, mp_jal, mp_ret, mp_jalr);
            $display("CDB           %0d cycles with more finished results than CDBs (3)", cdb_conflict_cycles);
            $display("I-cache       %0d fetches, %0d line fills (%0.1f%% hit), %0d next-line prefetch hits",
                     fetch_count, dut.OTTER_CSR_FILE.counters[5],
                     100.0 - percent(dut.OTTER_CSR_FILE.counters[5], fetch_count), dut.OTTER_CSR_FILE.counters[7]);
            $display("D-cache       %0d loads, %0d misses (%0.1f%% hit); misses served by L2: %0d, by memory: %0d",
                     load_count, l2_hit_count + l2_miss_count, 100.0 - percent(l2_hit_count + l2_miss_count, load_count),
                     l2_hit_count, l2_miss_count);
            $display("Store buffer  %0d stores, %0d forwarded to loads, %0d overlap stalls, %0d full stalls",
                     storebuf_enqueue_count, storebuf_forward_count, storebuf_conflict_cycles, storebuf_full_cycles);
            $display("Atomics       %0d executed, SC %0d succeeded / %0d failed",
                     atomic_commit_count, atomic_sc_success_count, atomic_sc_fail_count);
            $display("Traps         %0d exceptions, %0d interrupts, %0d mret", trap_count, interrupt_count, mret_count);
            $display("=========================================================================");
        end
    end
endmodule
