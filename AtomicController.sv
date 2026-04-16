`timescale 1ns/1ps

module AtomicController(
    input logic CLK,
    input logic RESET,
    input logic ordering_busy_i,
    input logic dc_stall_i,
    input logic storebuf_enqueue_event_i,
    input logic id_ex_valid_i,
    input logic id_ex_atomic_valid_i,
    input logic ex1_ex2_valid_i,
    input logic ex1_ex2_atomic_valid_i,
    input logic [31:0] atomic_preview_word_i,
    input logic ex_mem_valid_i,
    input logic ex_mem_atomic_valid_i,
    input logic [3:0] ex_mem_atomic_op_i,
    input logic [31:0] ex_mem_addr_i,
    input logic atomic_commit_valid_i,
    input logic [3:0] atomic_commit_op_i,
    input logic [31:0] atomic_commit_addr_i,
    output logic atomic_wait_ex1_o,
    output logic atomic_sc_ok_o,
    output logic atomic_write_intent_o,
    output logic [31:0] atomic_forward_preview_o,
    output logic reservation_valid_o,
    output logic reservation_set_event_o,
    output logic reservation_clear_event_o
);

    import otter_defs_pkg::*;

    logic reservation_valid_q;
    logic [29:0] reservation_word_addr_q;
    logic reservation_set_event;
    logic reservation_clear_event;

    // Atomics wait in EX1 until older stores, fences, or misses stop owning the
    // memory ordering point; this keeps LR/SC/AMO retirement strictly in order.
    assign atomic_wait_ex1_o = id_ex_valid_i && id_ex_atomic_valid_i && ordering_busy_i;
    // SC only succeeds when the stored reservation still matches the target word.
    assign atomic_sc_ok_o = reservation_valid_q && ex_mem_valid_i && ex_mem_atomic_valid_i &&
                            (ex_mem_atomic_op_i == ATOMIC_SC) &&
                            (reservation_word_addr_q == ex_mem_addr_i[31:2]);
    // LR reads without writing; every other successful atomic intends to update memory.
    assign atomic_write_intent_o = ex_mem_valid_i && ex_mem_atomic_valid_i &&
                                   ((ex_mem_atomic_op_i == ATOMIC_SC) ? atomic_sc_ok_o :
                                    (ex_mem_atomic_op_i != ATOMIC_LR));
    // A committed LR establishes the reservation, while any later atomic commit
    // or same-word older store enqueue clears it.
    assign reservation_set_event = atomic_commit_valid_i && (atomic_commit_op_i == ATOMIC_LR);
    assign reservation_clear_event = (atomic_commit_valid_i && (atomic_commit_op_i != ATOMIC_LR)) ||
                                     (storebuf_enqueue_event_i && reservation_valid_q &&
                                      (reservation_word_addr_q == ex_mem_addr_i[31:2]));
    assign reservation_valid_o = reservation_valid_q;
    assign reservation_set_event_o = reservation_set_event;
    assign reservation_clear_event_o = reservation_clear_event;

    always_ff @(posedge CLK) begin
        if (RESET) begin
            reservation_valid_q <= 1'b0;
            reservation_word_addr_q <= 30'b0;
        end else if (reservation_set_event) begin
            // Record the reserved word address on LR commit, not decode, so the
            // reservation only becomes visible once the instruction really retires.
            reservation_valid_q <= 1'b1;
            reservation_word_addr_q <= atomic_commit_addr_i[31:2];
        end else if (reservation_clear_event) begin
            reservation_valid_q <= 1'b0;
        end
    end

    always_ff @(posedge CLK) begin
        if (RESET)
            atomic_forward_preview_o <= 32'b0;
        // Snapshot the target word just before the atomic reaches memory so the
        // writeback stage can return the pre-update value for AMOs and LR.
        else if (~dc_stall_i && ex1_ex2_valid_i && ex1_ex2_atomic_valid_i)
            atomic_forward_preview_o <= atomic_preview_word_i;
    end

endmodule
