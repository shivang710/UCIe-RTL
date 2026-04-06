`timescale 1ns/1ps

module UCIe_rx_flitparser #(
    parameter integer FLIT_WIDTH = 256,
    parameter integer TYPE_WIDTH = 8,
    parameter integer SEQ_WIDTH  = 16,
    parameter integer HDR_WIDTH  = 32,
    parameter integer CRC_WIDTH  = 16
)(
    input  logic                        clk,
    input  logic                        rst_n,

    input  logic                        flit_valid_i,
    input  logic [FLIT_WIDTH-1:0]       flit_i,
    output logic                        flit_ready_o,

    output logic                        parsed_valid_o,
    output logic [TYPE_WIDTH-1:0]       flit_type_o,
    output logic [SEQ_WIDTH-1:0]        seq_num_o,
    output logic [HDR_WIDTH-1:0]        hdr_o,
    output logic [FLIT_WIDTH-1:0]       payload_o,
    output logic [CRC_WIDTH-1:0]        crc_field_o,

    output logic                        format_err_o,
    output logic                        boundary_err_o
);

    // Initial assumed field mapping for bring-up. we will update this once exact flit format is finalized
    localparam int TYPE_MSB = FLIT_WIDTH-1;
    localparam int TYPE_LSB = FLIT_WIDTH-TYPE_WIDTH;

    localparam int SEQ_MSB  = TYPE_LSB-1;
    localparam int SEQ_LSB  = SEQ_MSB-SEQ_WIDTH+1;

    localparam int HDR_MSB  = SEQ_LSB-1;
    localparam int HDR_LSB  = HDR_MSB-HDR_WIDTH+1;

    assign flit_ready_o = 1'b1;// For now, parser is always ready
    

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            parsed_valid_o <= 1'b0;
            flit_type_o    <= '0;
            seq_num_o      <= '0;
            hdr_o          <= '0;
            payload_o      <= '0;
            crc_field_o    <= '0;
            format_err_o   <= 1'b0;
            boundary_err_o <= 1'b0;
        end
        else begin
            parsed_valid_o <= flit_valid_i;

            if (flit_valid_i) begin
                flit_type_o <= flit_i[TYPE_MSB:TYPE_LSB];
                seq_num_o   <= flit_i[SEQ_MSB:SEQ_LSB];
                hdr_o       <= flit_i[HDR_MSB:HDR_LSB];

                // For initial bring-up, I have kept full flit as payload container. we can later split this into hdr/payload
                payload_o   <= flit_i;
                crc_field_o <= flit_i[CRC_WIDTH-1:0];

                // Simple placeholder checks
                format_err_o   <= (flit_i[TYPE_MSB:TYPE_LSB] == '0);
                boundary_err_o <= ((flit_i[TYPE_MSB:TYPE_LSB] == 8'h02) &&
                                   (flit_i[HDR_MSB:HDR_LSB] == '0));
            end
        end
    end

endmodule