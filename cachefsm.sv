module CacheFSM(
    input hit, 
    input miss, 
    input CLK, 
    input RST, 
    output logic update, 
    output logic pc_stall
);

    typedef enum{
        ST_READ_CACHE,
        ST_READ_MEM
    } state_type;
    state_type PS, NS;

    // The I$ miss path is deliberately tiny: one cycle to notice the miss,
    // one stalled cycle to let imem data get written into the cache, then fetch resumes.
    always_ff @(posedge CLK) begin
        if(RST == 1)
            PS <= ST_READ_CACHE;
        else
            PS <= NS;
        end
    
    always_comb begin
        update = 1'b1;
        pc_stall = 0;
        case (PS)
            ST_READ_CACHE: begin
                update = 1'b0;
                if(hit) begin
                    NS = ST_READ_CACHE;
                end
                else if(miss) begin
                    pc_stall = 1'b1;
                    NS = ST_READ_MEM;
                end
                else
                    NS = ST_READ_CACHE;
            end
            ST_READ_MEM: begin
                // Assert update while fetch is stalled so the just-fetched line can commit.
                pc_stall = 1'b1;
                NS = ST_READ_CACHE;
            end
            default: NS = ST_READ_CACHE;
        endcase
    end
endmodule
//i love cpe333