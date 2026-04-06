`timescale 1ns/1ps

module UCIe_link_state_regs
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

    // HW status from PHY / adapter FSM
    input  logic        hw_raw_mode_enabled,
    input  logic        hw_multi_stack_enabled,
    input  logic [3:0]  hw_link_width_enabled,
    input  logic [3:0]  hw_link_speed_enabled,
    input  logic        hw_link_is_up,
    input  logic        hw_link_training,

    // sticky status set pulses
    input  logic        hw_link_status_changed,
    input  logic        hw_auto_bw_changed,
    input  logic        hw_correctable_err,
    input  logic        hw_uncorr_nonfatal_err,
    input  logic        hw_uncorr_fatal_err,

    output logic        irq_link_event,
    output logic        irq_link_error
);

    // Link Status sticky bits (RW1C)
    logic link_status_changed_q;
    logic auto_bw_changed_q;
    logic corr_err_detected_q;
    logic uncorr_nf_err_q;
    logic uncorr_f_err_q;

    // Link Event Notification Control
    logic link_status_chg_irq_en;
    logic auto_bw_chg_irq_en;
    logic [4:0] link_evt_irq_num;

    // Error Notification Control
    logic corr_err_proto_en, corr_err_irq_en;
    logic uncorr_nf_proto_en, uncorr_nf_irq_en;
    logic uncorr_f_proto_en, uncorr_f_irq_en;
    logic [4:0] err_irq_num;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            link_status_changed_q <= 1'b0;
            auto_bw_changed_q     <= 1'b0;
            corr_err_detected_q   <= 1'b0;
            uncorr_nf_err_q       <= 1'b0;
            uncorr_f_err_q        <= 1'b0;
        end
        else begin
            if (hw_link_status_changed) link_status_changed_q <= 1'b1;
            if (hw_auto_bw_changed)     auto_bw_changed_q     <= 1'b1;
            if (hw_correctable_err)     corr_err_detected_q   <= 1'b1;
            if (hw_uncorr_nonfatal_err) uncorr_nf_err_q       <= 1'b1;
            if (hw_uncorr_fatal_err)    uncorr_f_err_q        <= 1'b1;

            if (wr_en && addr == REG_LINK_STATUS) begin
                if (wdata[17]) link_status_changed_q <= 1'b0;
                if (wdata[18]) auto_bw_changed_q     <= 1'b0;
                if (wdata[19]) corr_err_detected_q   <= 1'b0;
                if (wdata[20]) uncorr_nf_err_q       <= 1'b0;
                if (wdata[21]) uncorr_f_err_q        <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            link_status_chg_irq_en <= 1'b0;
            auto_bw_chg_irq_en    <= 1'b0;
            link_evt_irq_num      <= 5'b0;
        end
        else if (wr_en && addr == REG_LINK_EVT_CTRL) begin
            link_status_chg_irq_en <= wdata[0];
            auto_bw_chg_irq_en    <= wdata[1];
            link_evt_irq_num      <= wdata[15:11];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            corr_err_proto_en   <= 1'b0;
            corr_err_irq_en    <= 1'b0;
            uncorr_nf_proto_en <= 1'b0;
            uncorr_nf_irq_en   <= 1'b0;
            uncorr_f_proto_en  <= 1'b0;
            uncorr_f_irq_en    <= 1'b0;
            err_irq_num        <= 5'b0;
        end
        else if (wr_en && addr == REG_ERR_NOTIF_CTRL) begin
            corr_err_proto_en   <= wdata[0];
            corr_err_irq_en    <= wdata[1];
            uncorr_nf_proto_en <= wdata[2];
            uncorr_nf_irq_en   <= wdata[3];
            uncorr_f_proto_en  <= wdata[4];
            uncorr_f_irq_en    <= wdata[5];
            err_irq_num        <= wdata[15:11];
        end
    end

    assign irq_link_event = (link_status_changed_q & link_status_chg_irq_en) |
                            (auto_bw_changed_q     & auto_bw_chg_irq_en);

    assign irq_link_error = (corr_err_detected_q & corr_err_irq_en) |
                            (uncorr_nf_err_q     & uncorr_nf_irq_en) |
                            (uncorr_f_err_q      & uncorr_f_irq_en);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rdata       <= 32'b0;
            rdata_valid <= 1'b0;
        end
        else begin
            rdata_valid <= rd_en;
            if (rd_en) begin
                case (addr)
                    REG_LINK_STATUS:
                        rdata <= {10'b0,
                                  uncorr_f_err_q,
                                  uncorr_nf_err_q,
                                  corr_err_detected_q,
                                  auto_bw_changed_q,
                                  link_status_changed_q,
                                  hw_link_training,
                                  hw_link_is_up,
                                  hw_link_speed_enabled,
                                  hw_link_width_enabled,
                                  5'b0,
                                  hw_multi_stack_enabled,
                                  hw_raw_mode_enabled};

                    REG_LINK_EVT_CTRL:
                        rdata <= {16'b0,
                                  link_evt_irq_num,
                                  9'b0,
                                  auto_bw_chg_irq_en,
                                  link_status_chg_irq_en};

                    REG_ERR_NOTIF_CTRL:
                        rdata <= {16'b0,
                                  err_irq_num,
                                  5'b0,
                                  uncorr_f_irq_en,
                                  uncorr_f_proto_en,
                                  uncorr_nf_irq_en,
                                  uncorr_nf_proto_en,
                                  corr_err_irq_en,
                                  corr_err_proto_en};

                    default:
                        rdata <= 32'b0;
                endcase
            end
        end
    end

endmodule
