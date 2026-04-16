package otter_defs_pkg;

    // This packet is the front-end handoff between fetch-side prediction logic
    // and the downstream decode / hazard machinery.
    typedef struct packed {
        logic valid;
        logic predicted_taken;
        logic [31:0] predicted_target;

        logic [31:0] pc;
        // Historical name kept to minimize churn. This is now the architectural
        // fall-through PC: pc+2 for compressed instructions, pc+4 otherwise.
        logic [31:0] pc_4;
        logic [31:0] ir;

        logic is_branch;
        logic is_jal;
        logic is_jalr;
        logic is_return;
        logic rd_is_link;
        logic rs1_is_link;
        logic [31:0] jal_offset;
    } frontend_t;

    // Keep all atomic op encodings centralized so decode, controller, memory,
    // and writeback logic share one consistent internal enumeration.
    localparam logic [3:0] ATOMIC_NONE  = 4'd0;
    localparam logic [3:0] ATOMIC_LR    = 4'd1;
    localparam logic [3:0] ATOMIC_SC    = 4'd2;
    localparam logic [3:0] ATOMIC_SWAP  = 4'd3;
    localparam logic [3:0] ATOMIC_ADD   = 4'd4;
    localparam logic [3:0] ATOMIC_XOR   = 4'd5;
    localparam logic [3:0] ATOMIC_AND   = 4'd6;
    localparam logic [3:0] ATOMIC_OR    = 4'd7;
    localparam logic [3:0] ATOMIC_MIN   = 4'd8;
    localparam logic [3:0] ATOMIC_MAX   = 4'd9;
    localparam logic [3:0] ATOMIC_MINU  = 4'd10;
    localparam logic [3:0] ATOMIC_MAXU  = 4'd11;

    function automatic logic atomic_op_writes(
        input logic [3:0] atomic_op,
        input logic atomic_sc_ok
    );
        begin
            // LR is read-only, SC writes only on a live reservation match, and
            // every AMO variant always writes the computed replacement word.
            unique case (atomic_op)
                ATOMIC_LR: atomic_op_writes = 1'b0;
                ATOMIC_SC: atomic_op_writes = atomic_sc_ok;
                ATOMIC_SWAP,
                ATOMIC_ADD,
                ATOMIC_XOR,
                ATOMIC_AND,
                ATOMIC_OR,
                ATOMIC_MIN,
                ATOMIC_MAX,
                ATOMIC_MINU,
                ATOMIC_MAXU: atomic_op_writes = 1'b1;
                default: atomic_op_writes = 1'b0;
            endcase
        end
    endfunction

    function automatic logic [31:0] atomic_new_word(
        input logic [3:0] atomic_op,
        input logic [31:0] old_word,
        input logic [31:0] atomic_operand
    );
        begin
            // Compute the post-atomic memory value; callers separately decide
            // whether that value is actually committed, which matters for SC.
            unique case (atomic_op)
                ATOMIC_SC,
                ATOMIC_SWAP: atomic_new_word = atomic_operand;
                ATOMIC_ADD:  atomic_new_word = old_word + atomic_operand;
                ATOMIC_XOR:  atomic_new_word = old_word ^ atomic_operand;
                ATOMIC_AND:  atomic_new_word = old_word & atomic_operand;
                ATOMIC_OR:   atomic_new_word = old_word | atomic_operand;
                ATOMIC_MIN:  atomic_new_word = ($signed(old_word) < $signed(atomic_operand)) ? old_word : atomic_operand;
                ATOMIC_MAX:  atomic_new_word = ($signed(old_word) > $signed(atomic_operand)) ? old_word : atomic_operand;
                ATOMIC_MINU: atomic_new_word = (old_word < atomic_operand) ? old_word : atomic_operand;
                ATOMIC_MAXU: atomic_new_word = (old_word > atomic_operand) ? old_word : atomic_operand;
                default:     atomic_new_word = old_word;
            endcase
        end
    endfunction

    function automatic logic [31:0] atomic_result_word(
        input logic [3:0] atomic_op,
        input logic [31:0] old_word,
        input logic atomic_sc_ok
    );
        begin
            // AMOs and LR return the pre-update memory word, while SC returns
            // the architectural success code expected by RISC-V software.
            unique case (atomic_op)
                ATOMIC_LR,
                ATOMIC_SWAP,
                ATOMIC_ADD,
                ATOMIC_XOR,
                ATOMIC_AND,
                ATOMIC_OR,
                ATOMIC_MIN,
                ATOMIC_MAX,
                ATOMIC_MINU,
                ATOMIC_MAXU: atomic_result_word = old_word;
                ATOMIC_SC:   atomic_result_word = atomic_sc_ok ? 32'b0 : 32'b1;
                default:     atomic_result_word = 32'b0;
            endcase
        end
    endfunction

endpackage
