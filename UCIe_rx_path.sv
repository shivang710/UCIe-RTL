

//standalone RX skeleton tying together parser, CRC, error detect, retry, and reorder FIFO


`timescale 1ns/1ps
module UCIe_rx_path #(
    parameter integer FLIT_WIDTH = 256,
    parameter integer TYPE_WIDTH = 8,
    parameter integer SEQ_WIDTH  = 16,
    parameter integer HDR_WIDTH  = 32,
    parameter integer CRC_WIDTH  = 16,
    parameter integer FIFO_DEPTH = 8
)(
    input  logic                      clk,
    input  logic                      rst_n,

    input  logic                      flit_valid_i,
    input  logic [FLIT_WIDTH-1:0]     flit_i,
    output logic                      flit_ready_o,

    output logic                      rx_valid_o,
    output logic [FLIT_WIDTH-1:0]     rx_flit_o,
    output logic                      rx_error_o,

    output logic                      retry_req_o,
    output logic [SEQ_WIDTH-1:0]      retry_seq_o
);

    logic                      parsed_valid;
    logic [TYPE_WIDTH-1:0]     flit_type;
    logic [SEQ_WIDTH-1:0]      seq_num;
    logic [HDR_WIDTH-1:0]      hdr;
    logic [FLIT_WIDTH-1:0]     payload;
    logic [CRC_WIDTH-1:0]      crc_field;
    logic                      format_err;
    logic                      boundary_err;

    logic                      crc_valid;
    logic                      crc_err;

    logic                      err_valid;
    logic [2:0]                error_code;

    logic                      reorder_push_ready;
    logic                      reorder_pop_valid;
    logic [FLIT_WIDTH-1:0]     reorder_pop_flit;
    logic [SEQ_WIDTH-1:0]      reorder_pop_seq;

    logic                      drop_flit;

    UCIe_rx_flitparser #(
        .FLIT_WIDTH(FLIT_WIDTH),
        .TYPE_WIDTH(TYPE_WIDTH),
        .SEQ_WIDTH (SEQ_WIDTH),
        .HDR_WIDTH (HDR_WIDTH),
        .CRC_WIDTH (CRC_WIDTH)
    ) u_rx_flitparser (
        .clk            (clk),
        .rst_n          (rst_n),
        .flit_valid_i   (flit_valid_i),
        .flit_i         (flit_i),
        .flit_ready_o   (flit_ready_o),
        .parsed_valid_o (parsed_valid),
        .flit_type_o    (flit_type),
        .seq_num_o      (seq_num),
        .hdr_o          (hdr),
        .payload_o      (payload),
        .crc_field_o    (crc_field),
        .format_err_o   (format_err),
        .boundary_err_o (boundary_err)
    );

    UCIe_rx_crc_check #(
        .FLIT_WIDTH(FLIT_WIDTH),
        .CRC_WIDTH (CRC_WIDTH)
    ) u_rx_crc_check (
        .clk        (clk),
        .rst_n      (rst_n),
        .valid_i    (parsed_valid),
        .flit_i     (payload),
        .crc_field_i(crc_field),
        .valid_o    (crc_valid),
        .crc_err_o  (crc_err)
    );

    UCIe_rx_error_detect u_rx_error_detect (
        .clk           (clk),
        .rst_n         (rst_n),
        .valid_i       (crc_valid),
        .crc_err_i     (crc_err),
        .format_err_i  (format_err),
        .boundary_err_i(boundary_err),
        .valid_o       (err_valid),
        .rx_error_o    (rx_error_o),
        .error_code_o  (error_code)
    );

    UCIe_retry_handler #(
        .SEQ_WIDTH(SEQ_WIDTH)
    ) u_retry_handler (
        .clk         (clk),
        .rst_n       (rst_n),
        .valid_i     (err_valid),
        .rx_error_i  (rx_error_o),
        .seq_num_i   (seq_num),
        .retry_req_o (retry_req_o),
        .retry_seq_o (retry_seq_o),
        .drop_o      (drop_flit)
    );

    UCIe_reorder_fifo #(
        .FLIT_WIDTH(FLIT_WIDTH),
        .SEQ_WIDTH (SEQ_WIDTH),
        .DEPTH     (FIFO_DEPTH)
    ) u_reorder_fifo (
        .clk         (clk),
        .rst_n       (rst_n),
        .push_valid_i(err_valid && !rx_error_o && !drop_flit),
        .push_flit_i (payload),
        .push_seq_i  (seq_num),
        .push_ready_o(reorder_push_ready),
        .pop_valid_o (reorder_pop_valid),
        .pop_flit_o  (reorder_pop_flit),
        .pop_seq_o   (reorder_pop_seq),
        .pop_ready_i (1'b1),
        .full_o      (),
        .empty_o     ()
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_valid_o <= 1'b0;
            rx_flit_o  <= '0;
        end
        else begin
            rx_valid_o <= reorder_pop_valid;
            if (reorder_pop_valid)
                rx_flit_o <= reorder_pop_flit;
        end
    end

endmodule