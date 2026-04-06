

//initial retry skeleton


`timescale 1ns/1ps

module UCIe_retry_handler #(
    parameter integer SEQ_WIDTH = 16
)(
    input  logic                   clk,
    input  logic                   rst_n,

    input  logic                   valid_i,
    input  logic                   rx_error_i,
    input  logic [SEQ_WIDTH-1:0]   seq_num_i,

    output logic                   retry_req_o,
    output logic [SEQ_WIDTH-1:0]   retry_seq_o,
    output logic                   drop_o
);

    typedef enum logic [1:0] {
        IDLE,
        ISSUE_RETRY,
        COMPLETE
    } retry_state_t;

    retry_state_t state_q, state_d;
    logic [SEQ_WIDTH-1:0] retry_seq_q, retry_seq_d;

    always_comb begin
        state_d      = state_q;
        retry_seq_d  = retry_seq_q;

        retry_req_o  = 1'b0;
        retry_seq_o  = retry_seq_q;
        drop_o       = 1'b0;

        case (state_q)
            IDLE: begin
                if (valid_i && rx_error_i) begin
                    retry_seq_d = seq_num_i;
                    drop_o      = 1'b1;
                    state_d     = ISSUE_RETRY;
                end
            end

            ISSUE_RETRY: begin
                retry_req_o = 1'b1;
                retry_seq_o = retry_seq_q;
                state_d     = COMPLETE;
            end

            COMPLETE: begin
                state_d = IDLE;
            end

            default: begin
                state_d = IDLE;
            end
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q     <= IDLE;
            retry_seq_q <= '0;
        end
        else begin
            state_q     <= state_d;
            retry_seq_q <= retry_seq_d;
        end
    end

endmodule