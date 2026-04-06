`timescale 1ns/1ps

module UCIe_status_regs
    import UCIe_csr_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    input  logic        wr_en,
    input  logic        rd_en,
    input  logic [11:0] addr,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,
    output logic        rdata_valid,

    // capability log captures from sideband param exchange
    input  logic [31:0] hw_adv_adp_cap_lo,
    input  logic [31:0] hw_adv_adp_cap_hi,
    input  logic [31:0] hw_fin_adp_cap_lo,
    input  logic [31:0] hw_fin_adp_cap_hi,
    input  logic        hw_cap_log_valid
);

    // Block Header (RO)
    localparam [31:0] BLK_HDR_LO = {16'h0000, 16'h1E98};
    localparam [31:0] BLK_HDR_HI = 32'h0000_2000;

    // Capability Logs (RW1C)
    logic [31:0] adv_adp_cap_lo_q, adv_adp_cap_hi_q;
    logic [31:0] fin_adp_cap_lo_q, fin_adp_cap_hi_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            adv_adp_cap_lo_q <= 32'b0;
            adv_adp_cap_hi_q <= 32'b0;
            fin_adp_cap_lo_q <= 32'b0;
            fin_adp_cap_hi_q <= 32'b0;
        end
        else begin
            if (hw_cap_log_valid) begin
                adv_adp_cap_lo_q <= hw_adv_adp_cap_lo;
                adv_adp_cap_hi_q <= hw_adv_adp_cap_hi;
                fin_adp_cap_lo_q <= hw_fin_adp_cap_lo;
                fin_adp_cap_hi_q <= hw_fin_adp_cap_hi;
            end

            if (wr_en) begin
                case (addr)
                    REG_ADV_ADP_CAP_LO: adv_adp_cap_lo_q <= adv_adp_cap_lo_q & ~wdata;
                    REG_ADV_ADP_CAP_HI: adv_adp_cap_hi_q <= adv_adp_cap_hi_q & ~wdata;
                    REG_FIN_ADP_CAP_LO: fin_adp_cap_lo_q <= fin_adp_cap_lo_q & ~wdata;
                    REG_FIN_ADP_CAP_HI: fin_adp_cap_hi_q <= fin_adp_cap_hi_q & ~wdata;
                    default: ;
                endcase
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rdata       <= 32'b0;
            rdata_valid <= 1'b0;
        end
        else begin
            rdata_valid <= rd_en;
            if (rd_en) begin
                case (addr)
                    REG_BLK_HDR_LO:     rdata <= BLK_HDR_LO;
                    REG_BLK_HDR_HI:     rdata <= BLK_HDR_HI;
                    REG_ADV_ADP_CAP_LO: rdata <= adv_adp_cap_lo_q;
                    REG_ADV_ADP_CAP_HI: rdata <= adv_adp_cap_hi_q;
                    REG_FIN_ADP_CAP_LO: rdata <= fin_adp_cap_lo_q;
                    REG_FIN_ADP_CAP_HI: rdata <= fin_adp_cap_hi_q;
                    default:            rdata <= 32'b0;
                endcase
            end
        end
    end

endmodule
