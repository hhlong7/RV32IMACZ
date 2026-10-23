package otter_defs_pkg;

    // This packet is the front-end handoff between fetch-side prediction logic
    // and the downstream decode / hazard machinery.
    // Global branch history length for the gshare direction predictor.
    localparam int GHR_BITS = 8;

    typedef struct packed {
        logic valid;
        logic predicted_taken;
        logic [31:0] predicted_target;

        logic [31:0] pc;
        // Architectural fall-through PC: pc+2 for compressed instructions,
        // pc+4 otherwise.
        logic [31:0] pc_next;
        logic [31:0] ir;

        logic is_branch;
        logic is_jal;
        logic is_jalr;
        logic is_return;
        logic rd_is_link;
        logic rs1_is_link;
        logic [31:0] jal_offset;
        // The instruction as fetched (16 bits for compressed): reported in
        // mtval when the instruction is illegal.
        logic [31:0] raw_ir;
        // Global history the direction prediction used: carried to the branch
        // unit (history repair on a mispredict) and to commit (training).
        logic [GHR_BITS-1:0] ghr;
    } frontend_t;

    // Cache replacement policy for the fully associative L1 I/D caches and
    // L2: tree pseudo-LRU by default; build with -DOTTER_TRUE_LRU for true LRU.
`ifdef OTTER_TRUE_LRU
    localparam bit CACHE_TRUE_LRU = 1'b1;
`else
    localparam bit CACHE_TRUE_LRU = 1'b0;
`endif
    // Line address: everything above the 32-byte line offset.
    localparam int CACHE_TAG_BITS = 27;

    // L2 data cache: left out by default. On an FPGA the memory behind the
    // L1 caches is on-chip block RAM, which refills a line one word per
    // cycle just as the L2 does, so the L2 cost about 6,000 LUTs and 9,000
    // flip-flops for no speedup. Build with -DOTTER_L2 to include it.
`ifdef OTTER_L2
    localparam bit L2_ENABLE = 1'b1;
`else
    localparam bit L2_ENABLE = 1'b0;
`endif

    // RV32 major opcodes (instruction bits [6:0]).
    localparam logic [6:0] OPC_LOAD     = 7'b0000011;
    localparam logic [6:0] OPC_MISC_MEM = 7'b0001111;
    localparam logic [6:0] OPC_OP_IMM   = 7'b0010011;
    localparam logic [6:0] OPC_AUIPC    = 7'b0010111;
    localparam logic [6:0] OPC_STORE    = 7'b0100011;
    localparam logic [6:0] OPC_AMO      = 7'b0101111;
    localparam logic [6:0] OPC_OP       = 7'b0110011;
    localparam logic [6:0] OPC_LUI      = 7'b0110111;
    localparam logic [6:0] OPC_BRANCH   = 7'b1100011;
    localparam logic [6:0] OPC_JALR     = 7'b1100111;
    localparam logic [6:0] OPC_JAL      = 7'b1101111;
    localparam logic [6:0] OPC_SYSTEM   = 7'b1110011;
    localparam logic [6:0] OPC_LOAD_FP  = 7'b0000111;
    localparam logic [6:0] OPC_STORE_FP = 7'b0100111;
    localparam logic [6:0] OPC_OP_FP    = 7'b1010011;

    // Which FP execution unit an instruction uses.
    localparam logic [1:0] FP_UNIT_NONE = 2'd0;  // not FP arithmetic (incl. flw/fsw)
    localparam logic [1:0] FP_UNIT_ADD  = 2'd1;  // pipelined adder (fadd/fsub)
    localparam logic [1:0] FP_UNIT_MUL  = 2'd2;  // pipelined multiplier
    localparam logic [1:0] FP_UNIT_DIV  = 2'd3;  // iterative divider

    // Branch, JAL, or JALR.
    function automatic logic is_control_ir(input logic [31:0] ir);
        is_control_ir = (ir[6:0] == OPC_BRANCH) ||
                        (ir[6:0] == OPC_JAL) ||
                        ((ir[6:0] == OPC_JALR) && (ir[14:12] == 3'b000));
    endfunction

    // Control flow plus SYSTEM and MISC-MEM: the front end never buffers a
    // younger instruction behind one of these, and slot 1 never issues one.
    function automatic logic is_front_barrier_ir(input logic [31:0] ir);
        is_front_barrier_ir = is_control_ir(ir) ||
                              (ir[6:0] == OPC_SYSTEM) ||
                              (ir[6:0] == OPC_MISC_MEM);
    endfunction

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
