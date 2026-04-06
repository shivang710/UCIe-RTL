`timescale 1ns/1ps

module UCIe_error_regs
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

    // uncorrectable error pulses
    input  logic        hw_adapter_timeout,
    input  logic        hw_receiver_overflow,
    input  logic        hw_internal_error,
    input  logic        hw_sb_fatal_err_msg,
    input  logic        hw_sb_nonfatal_err_msg,
    input  logic        hw_invalid_param_exchange,

    // correctable error pulses
    input  logic        hw_crc_error,
    input  logic        hw_adp_lsm_retrain,
    input  logic        hw_corr_internal_error,
    input  logic        hw_sb_corr_err_msg,

    // header log 2 captures
    input  logic [3:0]  hw_timeout_encoding,
    input  logic [2:0]  hw_overflow_encoding,
    input  logic [2:0]  hw_lsm_response_type,
    input  logic        hw_lsm_id,
    input  logic        hw_param_exchange_ok,
    input  logic [3:0]  hw_flit_format,

    // header log 1
    input  logic [31:0] hw_hdr_log1_lo,
    input  logic [31:0] hw_hdr_log1_hi,

    // parity log captures
    input  logic [31:0] hw_parity_log0_lo,
    input  logic [31:0] hw_parity_log0_hi,
    input  logic [31:0] hw_parity_log1_lo,
    input  logic [31:0] hw_parity_log1_hi,

    output logic [5:0]  ucerr_masked,
    output logic [5:0]  ucerr_severity,
    output logic [3:0]  cerr_masked
);

    logic [5:0] ucerr_sts_q;
    logic [5:0] ucerr_mask_q;
    logic [5:0] ucerr_sev_q;
    logic [3:0] cerr_sts_q;
    logic [4:0] cerr_mask_q;

    logic [31:0] hdr_log1_lo_q, hdr_log1_hi_q;
    logic [31:0] hdr_log2_q;
    logic [4:0]  first_fatal_q;
    logic        first_fatal_locked;

    logic [31:0] parity_log0_lo_q, parity_log0_hi_q;
    logic [31:0] parity_log1_lo_q, parity_log1_hi_q;

    assign ucerr_masked  = ucerr_sts_q & ~ucerr_mask_q;
    assign ucerr_severity = ucerr_sev_q;
    assign cerr_masked   = cerr_sts_q & ~cerr_mask_q[3:0];

    // Uncorrectable Error Status (RW1CS)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            ucerr_sts_q <= 6'b0;
        else begin
            if (hw_adapter_timeout)        ucerr_sts_q[0] <= 1'b1;
            if (hw_receiver_overflow)      ucerr_sts_q[1] <= 1'b1;
            if (hw_internal_error)         ucerr_sts_q[2] <= 1'b1;
            if (hw_sb_fatal_err_msg)       ucerr_sts_q[3] <= 1'b1;
            if (hw_sb_nonfatal_err_msg)    ucerr_sts_q[4] <= 1'b1;
            if (hw_invalid_param_exchange) ucerr_sts_q[5] <= 1'b1;

            if (wr_en && addr == REG_UCERR_STS)
                ucerr_sts_q <= ucerr_sts_q & ~wdata[5:0];
        end
    end

    // Uncorrectable Error Mask (RWS, default all-masked)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            ucerr_mask_q <= 6'b111111;
        else if (wr_en && addr == REG_UCERR_MASK)
            ucerr_mask_q <= wdata[5:0];
    end

    // Uncorrectable Error Severity (RWS)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            ucerr_sev_q <= 6'b110111;  // bit4=0 (non-fatal SB NF), rest=1
        else if (wr_en && addr == REG_UCERR_SEV)
            ucerr_sev_q <= wdata[5:0];
    end

    // Correctable Error Status (RW1CS)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cerr_sts_q <= 4'b0;
        else begin
            if (hw_crc_error)           cerr_sts_q[0] <= 1'b1;
            if (hw_adp_lsm_retrain)     cerr_sts_q[1] <= 1'b1;
            if (hw_corr_internal_error) cerr_sts_q[2] <= 1'b1;
            if (hw_sb_corr_err_msg)     cerr_sts_q[3] <= 1'b1;

            if (wr_en && addr == REG_CERR_STS)
                cerr_sts_q <= cerr_sts_q & ~wdata[3:0];
        end
    end

    // Correctable Error Mask (RWS, default all-masked)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cerr_mask_q <= 5'b11111;
        else if (wr_en && addr == REG_CERR_MASK)
            cerr_mask_q <= wdata[4:0];
    end

    // Header Log 1 - capture on first uncorrectable error
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hdr_log1_lo_q <= 32'b0;
            hdr_log1_hi_q <= 32'b0;
        end
        else begin
            if ((|ucerr_sts_q) == 1'b0 &&
                (hw_adapter_timeout | hw_receiver_overflow | hw_internal_error |
                 hw_sb_fatal_err_msg | hw_sb_nonfatal_err_msg | hw_invalid_param_exchange)) begin
                hdr_log1_lo_q <= hw_hdr_log1_lo;
                hdr_log1_hi_q <= hw_hdr_log1_hi;
            end
        end
    end

    // Header Log 2 + first fatal indicator
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hdr_log2_q         <= 32'b0;
            first_fatal_q      <= 5'b0;
            first_fatal_locked <= 1'b0;
        end
        else begin
            hdr_log2_q[3:0]   <= hw_timeout_encoding;
            hdr_log2_q[6:4]   <= hw_overflow_encoding;
            hdr_log2_q[9:7]   <= hw_lsm_response_type;
            hdr_log2_q[10]    <= hw_lsm_id;
            hdr_log2_q[12:11] <= 2'b0;
            hdr_log2_q[13]    <= hw_param_exchange_ok;
            hdr_log2_q[17:14] <= hw_flit_format;

            if (!first_fatal_locked) begin
                if (hw_adapter_timeout)            begin first_fatal_q <= 5'd0; first_fatal_locked <= 1'b1; end
                else if (hw_receiver_overflow)     begin first_fatal_q <= 5'd1; first_fatal_locked <= 1'b1; end
                else if (hw_internal_error)        begin first_fatal_q <= 5'd2; first_fatal_locked <= 1'b1; end
                else if (hw_sb_fatal_err_msg)      begin first_fatal_q <= 5'd3; first_fatal_locked <= 1'b1; end
                else if (hw_sb_nonfatal_err_msg)   begin first_fatal_q <= 5'd4; first_fatal_locked <= 1'b1; end
                else if (hw_invalid_param_exchange) begin first_fatal_q <= 5'd5; first_fatal_locked <= 1'b1; end
            end
            hdr_log2_q[22:18] <= first_fatal_q;
            hdr_log2_q[31:23] <= 9'b0;

            if (ucerr_sts_q == 6'b0)
                first_fatal_locked <= 1'b0;
        end
    end

    // Parity Logs (RW1C, HW ORs in error bits)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            parity_log0_lo_q <= 32'b0;
            parity_log0_hi_q <= 32'b0;
            parity_log1_lo_q <= 32'b0;
            parity_log1_hi_q <= 32'b0;
        end
        else begin
            parity_log0_lo_q <= parity_log0_lo_q | hw_parity_log0_lo;
            parity_log0_hi_q <= parity_log0_hi_q | hw_parity_log0_hi;
            parity_log1_lo_q <= parity_log1_lo_q | hw_parity_log1_lo;
            parity_log1_hi_q <= parity_log1_hi_q | hw_parity_log1_hi;

            if (wr_en) begin
                case (addr)
                    REG_PARITY_LOG0_LO: parity_log0_lo_q <= parity_log0_lo_q & ~wdata;
                    REG_PARITY_LOG0_HI: parity_log0_hi_q <= parity_log0_hi_q & ~wdata;
                    REG_PARITY_LOG1_LO: parity_log1_lo_q <= parity_log1_lo_q & ~wdata;
                    REG_PARITY_LOG1_HI: parity_log1_hi_q <= parity_log1_hi_q & ~wdata;
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
                    REG_UCERR_STS:      rdata <= {26'b0, ucerr_sts_q};
                    REG_UCERR_MASK:     rdata <= {26'b0, ucerr_mask_q};
                    REG_UCERR_SEV:      rdata <= {26'b0, ucerr_sev_q};
                    REG_CERR_STS:       rdata <= {28'b0, cerr_sts_q};
                    REG_CERR_MASK:      rdata <= {27'b0, cerr_mask_q};
                    REG_HDR_LOG1_LO:    rdata <= hdr_log1_lo_q;
                    REG_HDR_LOG1_HI:    rdata <= hdr_log1_hi_q;
                    REG_HDR_LOG2:       rdata <= hdr_log2_q;
                    REG_PARITY_LOG0_LO: rdata <= parity_log0_lo_q;
                    REG_PARITY_LOG0_HI: rdata <= parity_log0_hi_q;
                    REG_PARITY_LOG1_LO: rdata <= parity_log1_lo_q;
                    REG_PARITY_LOG1_HI: rdata <= parity_log1_hi_q;
                    default:            rdata <= 32'b0;
                endcase
            end
        end
    end

endmodule
