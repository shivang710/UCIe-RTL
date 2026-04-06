`timescale 1ns/1ps

module UCIe_rx_error_detect (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       valid_i,
    input  logic       crc_err_i,
    input  logic       format_err_i,
    input  logic       boundary_err_i,

    output logic       valid_o,
    output logic       rx_error_o,
    output logic [2:0] error_code_o
);

    // error_code_o[0] = crc error
    // error_code_o[1] = format error
    // error_code_o[2] = boundary/control error

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_o      <= 1'b0;
            rx_error_o   <= 1'b0;
            error_code_o <= 3'b000;
        end
        else begin
            valid_o <= valid_i;

            if (valid_i) begin
                error_code_o <= {boundary_err_i, format_err_i, crc_err_i};
                rx_error_o   <= crc_err_i | format_err_i | boundary_err_i;
            end
        end
    end

endmodule