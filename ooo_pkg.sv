// Shared types for the out-of-order back end: Tomasulo-style reservation
// stations with a reorder buffer (ROB). The ROB index is the rename tag.
package ooo_pkg;

    localparam int ROB_SIZE = 16;
    localparam int TAG_BITS = 4;
    typedef logic [TAG_BITS-1:0] tag_t;

    // Rename-table checkpoints: one per unresolved branch/jump. A branch that
    // resolves as mispredicted restores its checkpoint at execute. A branch
    // holds its checkpoint exactly as long as its branch-RS entry, so one
    // checkpoint per branch-RS entry means dispatch never waits for one.
    localparam int BR_RS_ENTRIES = 4;
    localparam int CKPTS = BR_RS_ENTRIES;
    localparam int CKPT_BITS = 2;
    typedef logic [CKPT_BITS-1:0] ckpt_t;

    // Destination register file of an instruction.
    localparam logic [1:0] DST_NONE = 2'd0;
    localparam logic [1:0] DST_INT  = 2'd1;
    localparam logic [1:0] DST_FP   = 2'd2;

    // Execution unit (and reservation station) of an instruction.
    localparam logic [3:0] CLS_NONE   = 4'd0;   // completes at dispatch (system, exceptions)
    localparam logic [3:0] CLS_ALU    = 4'd1;
    localparam logic [3:0] CLS_BRANCH = 4'd2;
    localparam logic [3:0] CLS_MEM    = 4'd3;
    localparam logic [3:0] CLS_FPADD  = 4'd4;
    localparam logic [3:0] CLS_FPMUL  = 4'd5;
    localparam logic [3:0] CLS_FPDIV  = 4'd6;
    localparam logic [3:0] CLS_IMUL   = 4'd7;   // RV32M multiplies (pipelined unit)
    localparam logic [3:0] CLS_IDIV   = 4'd8;   // RV32M divides/remainders (iterative unit)

    // Instructions that execute at the ROB head with the ROB otherwise empty.
    localparam logic [2:0] SYS_NONE    = 3'd0;
    localparam logic [2:0] SYS_CSR     = 3'd1;
    localparam logic [2:0] SYS_MRET    = 3'd2;
    localparam logic [2:0] SYS_FENCE   = 3'd3;
    localparam logic [2:0] SYS_FENCE_I = 3'd4;
    localparam logic [2:0] SYS_WFI     = 3'd5;
    localparam logic [2:0] SYS_ATOMIC  = 3'd6;

    // A reservation-station (or memory-queue) entry: one renamed instruction
    // waiting for its operands. A source is ready when its value is present;
    // otherwise it waits for `tag` on a common data bus.
    typedef struct packed {
        logic valid;
        tag_t tag;                      // ROB entry
        logic [31:0] pc;
        logic [31:0] pc_next;           // fall-through PC
        logic [31:0] ir;                // expanded instruction
        logic predicted_taken;
        logic [31:0] predicted_target;
        logic alu_src_a;
        logic [1:0] alu_src_b;
        logic [4:0] alu_fun;
        logic writes_rd;                // branch unit: jal/jalr link register
        ckpt_t ckpt;                    // branch unit: its rename checkpoint
        logic [otter_defs_pkg::GHR_BITS-1:0] ghr;  // branch unit: history at prediction
        logic mem_load;
        logic mem_store;
        logic mem_atomic;
        logic [3:0] atomic_op;
        logic fp_sub;
        logic [2:0] fp_rm;
        logic src1_ready;
        logic src1_spec;                // ready by a tag-only wake-up: the value
                                        // is on a CDB this cycle (see the RS)
        tag_t src1_tag;
        logic [31:0] src1;
        logic src2_ready;
        logic src2_spec;
        tag_t src2_tag;
        logic [31:0] src2;
    } rs_entry_t;

    // A completion broadcast on a common data bus. Besides waking up waiting
    // instructions it marks the ROB entry done and records what commit needs.
    typedef struct packed {
        logic valid;
        tag_t tag;
        logic [31:0] value;
        logic exception;
        logic [31:0] cause;
        logic [31:0] tval;
        logic mispredict;               // control flow differs from the prediction
        logic taken;                    // branch/jump outcome (predictor training)
        logic [31:0] next_pc;           // actual next PC (redirect on mispredict)
        logic [4:0] fp_flags;
    } cdb_t;

    typedef struct packed {
        logic valid;
        logic done;
        logic [31:0] pc;
        logic [31:0] pc_next;
        logic [31:0] ir;
        logic [31:0] raw_ir;            // as fetched: mtval for illegal instructions
        // Single-bit flags only: Icarus 13 can mis-evaluate compares of fields
        // of large packed structs against constants.
        logic wr_int;                   // writes x register rd
        logic wr_fp;                    // writes f register rd
        logic [4:0] rd;
        logic [31:0] value;
        logic exception;
        logic [31:0] cause;
        logic [31:0] tval;
        logic mispredict;
        logic taken;
        logic [31:0] next_pc;
        logic fp_arith;                 // accrues fp_flags into fflags at commit
        logic [4:0] fp_flags;
        logic is_store;
        logic is_control;               // branch, jal, or jalr (predictor training)
        logic serial;                   // serializing: executes as it commits
        logic sys_csr;
        logic sys_mret;
        logic sys_fence;
        logic sys_fence_i;
        logic [31:0] csr_src;           // CSR operand (rs1 value or zimm)
        logic [otter_defs_pkg::GHR_BITS-1:0] ghr;  // predictor training index
    } rob_entry_t;

    // Age of a tag relative to the ROB head (0 = oldest in flight).
    function automatic tag_t tag_age(input tag_t tag, input tag_t head);
        tag_age = tag - head;
    endfunction

    // True when `tag` is younger than `branch` (both in flight).
    function automatic logic tag_younger(input tag_t tag, input tag_t branch, input tag_t head);
        tag_younger = tag_age(tag, head) > tag_age(branch, head);
    endfunction

endpackage
