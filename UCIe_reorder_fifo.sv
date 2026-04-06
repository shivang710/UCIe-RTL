

//reorder-buffer placeholder. Right now it behaves as a sequence-tagged FIFO


`timescale 1ns/1ps
module UCIe_reorder_fifo #(
    parameter integer FLIT_WIDTH = 256,
    parameter integer SEQ_WIDTH  = 16,
    parameter integer DEPTH      = 8
)(
    input  logic                      clk,
    input  logic                      rst_n,

    input  logic                      push_valid_i,
    input  logic [FLIT_WIDTH-1:0]     push_flit_i,
    input  logic [SEQ_WIDTH-1:0]      push_seq_i,
    output logic                      push_ready_o,

    output logic                      pop_valid_o,
    output logic [FLIT_WIDTH-1:0]     pop_flit_o,
    output logic [SEQ_WIDTH-1:0]      pop_seq_o,
    input  logic                      pop_ready_i,

    output logic                      full_o,
    output logic                      empty_o
);

    localparam int PTR_W = (DEPTH <= 2) ? 1 : $clog2(DEPTH);

    logic [FLIT_WIDTH-1:0] mem_flit [0:DEPTH-1];
    logic [SEQ_WIDTH-1:0]  mem_seq  [0:DEPTH-1];

    logic [PTR_W-1:0] wr_ptr_q, rd_ptr_q;
    logic [PTR_W:0]   count_q;

    logic push_fire, pop_fire;

    assign full_o       = (count_q == DEPTH);
    assign empty_o      = (count_q == 0);
    assign push_ready_o = ~full_o;
    assign pop_valid_o  = ~empty_o;

    assign push_fire = push_valid_i & push_ready_o;
    assign pop_fire  = pop_valid_o & pop_ready_i;

    assign pop_flit_o = mem_flit[rd_ptr_q];
    assign pop_seq_o  = mem_seq[rd_ptr_q];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr_q <= '0;
            rd_ptr_q <= '0;
            count_q  <= '0;
        end
        else begin
            if (push_fire) begin
                mem_flit[wr_ptr_q] <= push_flit_i;
                mem_seq[wr_ptr_q]  <= push_seq_i;

                if (wr_ptr_q == DEPTH-1)
                    wr_ptr_q <= '0;
                else
                    wr_ptr_q <= wr_ptr_q + 1'b1;
            end

            if (pop_fire) begin
                if (rd_ptr_q == DEPTH-1)
                    rd_ptr_q <= '0;
                else
                    rd_ptr_q <= rd_ptr_q + 1'b1;
            end

            case ({push_fire, pop_fire})
                2'b10: count_q <= count_q + 1'b1;
                2'b01: count_q <= count_q - 1'b1;
                default: count_q <= count_q;
            endcase
        end
    end

endmodule
endmodule