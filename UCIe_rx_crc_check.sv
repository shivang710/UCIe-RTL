`timescale 1ns/1ps

module UCIe_rx_crc_check #(
    parameter integer FLIT_WIDTH = 256,
    parameter integer CRC_WIDTH  = 16
)(
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic                    valid_i,
    input  logic [FLIT_WIDTH-1:0]   flit_i,
    input  logic [CRC_WIDTH-1:0]    crc_field_i,

    output logic                    valid_o,
    output logic                    crc_err_o
);

    logic [CRC_WIDTH-1:0] crc_calc;

    // reusing the existing CRC generator
    ucie_crc_gen u_crc_gen (
        .data_i (flit_i[FLIT_WIDTH-1:CRC_WIDTH]),
        .crc_o  (crc_calc)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_o   <= 1'b0;
            crc_err_o <= 1'b0;
        end
        else begin
            valid_o <= valid_i;

            if (valid_i) begin
                crc_err_o <= (crc_calc != crc_field_i);
            end
        end
    end

endmodule