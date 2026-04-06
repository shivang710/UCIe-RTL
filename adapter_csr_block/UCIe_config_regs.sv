`timescale 1ns/1ps

module UCIe_config_regs
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

    // HW-init straps
    input  logic        strap_raw_mode_cap,
    input  logic [2:0]  strap_max_link_width,
    input  logic [3:0]  strap_max_link_speed,
    input  logic        strap_multi_stack_cap,
    input  logic        strap_adv_packaging,

    // config outputs
    output logic        cfg_raw_mode_en,
    output logic        cfg_multi_stack_en,
    output logic [3:0]  cfg_target_link_width,
    output logic [3:0]  cfg_target_link_speed,
    output logic        cfg_start_link_training,
    output logic        cfg_retrain_link,
    output logic        cfg_phy_clk_gate_en,
    output logic [3:0]  cfg_remote_reg_threshold,
    output logic        cfg_runtime_link_test_tx_en,
    output logic        cfg_runtime_link_test_rx_en,
    output logic [1:0]  cfg_crc_injection_en,
    output logic [1:0]  cfg_crc_injection_count,

    input  logic        link_training_done,
    input  logic        crc_injection_busy_i
);

    // Link Capability (RO)
    logic [31:0] link_capability;
    assign link_capability = {
        21'b0,
        strap_adv_packaging,
        strap_multi_stack_cap,
        1'b0,
        strap_max_link_speed,
        strap_max_link_width,
        strap_raw_mode_cap
    };

    // Link Control fields
    logic        raw_mode_en_q;
    logic        multi_stack_en_q;
    logic [3:0]  target_width_q;
    logic [3:0]  target_speed_q;
    logic        start_training_q;
    logic        retrain_q;
    logic        phy_clk_gate_en_q;

    // Error & Link Testing Control fields
    logic [3:0]  remote_reg_thresh_q;
    logic        rt_link_test_tx_q;
    logic        rt_link_test_rx_q;
    logic [2:0]  num_64b_inserts_q;
    logic        parity_nak_rcvd_q;
    logic [1:0]  crc_inj_en_q;
    logic [1:0]  crc_inj_count_q;

    assign cfg_raw_mode_en             = raw_mode_en_q;
    assign cfg_multi_stack_en          = multi_stack_en_q;
    assign cfg_target_link_width       = target_width_q;
    assign cfg_target_link_speed       = target_speed_q;
    assign cfg_start_link_training     = start_training_q;
    assign cfg_retrain_link            = retrain_q;
    assign cfg_phy_clk_gate_en         = phy_clk_gate_en_q;
    assign cfg_remote_reg_threshold    = remote_reg_thresh_q;
    assign cfg_runtime_link_test_tx_en = rt_link_test_tx_q;
    assign cfg_runtime_link_test_rx_en = rt_link_test_rx_q;
    assign cfg_crc_injection_en        = crc_inj_en_q;
    assign cfg_crc_injection_count     = crc_inj_count_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            raw_mode_en_q      <= 1'b0;
            multi_stack_en_q   <= strap_multi_stack_cap;
            target_width_q     <= {1'b0, strap_max_link_width};
            target_speed_q     <= strap_max_link_speed;
            start_training_q   <= 1'b0;
            retrain_q          <= 1'b0;
            phy_clk_gate_en_q  <= 1'b1;
            remote_reg_thresh_q <= 4'b0100;
            rt_link_test_tx_q   <= 1'b0;
            rt_link_test_rx_q   <= 1'b0;
            num_64b_inserts_q   <= 3'b0;
            parity_nak_rcvd_q   <= 1'b0;
            crc_inj_en_q        <= 2'b0;
            crc_inj_count_q     <= 2'b0;
        end
        else begin
            // auto-clear when training completes
            if (link_training_done) begin
                start_training_q <= 1'b0;
                retrain_q        <= 1'b0;
            end

            if (wr_en) begin
                case (addr)
                    REG_LINK_CTRL: begin
                        raw_mode_en_q     <= wdata[0];
                        multi_stack_en_q  <= wdata[1];
                        target_width_q    <= wdata[5:2];
                        target_speed_q    <= wdata[9:6];
                        start_training_q  <= wdata[10];
                        retrain_q         <= wdata[11];
                        phy_clk_gate_en_q <= wdata[12];
                    end

                    REG_ERR_LINK_TEST: begin
                        remote_reg_thresh_q <= wdata[3:0];
                        rt_link_test_tx_q   <= wdata[4];
                        rt_link_test_rx_q   <= wdata[5];
                        num_64b_inserts_q   <= wdata[8:6];
                        if (wdata[9]) parity_nak_rcvd_q <= 1'b0; // RW1C
                        crc_inj_en_q        <= wdata[14:13];
                        crc_inj_count_q     <= wdata[16:15];
                    end

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
                    REG_LINK_CAP:
                        rdata <= link_capability;

                    REG_LINK_CTRL:
                        rdata <= {19'b0,
                                  phy_clk_gate_en_q,
                                  retrain_q,
                                  start_training_q,
                                  target_speed_q,
                                  target_width_q,
                                  multi_stack_en_q,
                                  raw_mode_en_q};

                    REG_ERR_LINK_TEST:
                        rdata <= {14'b0,
                                  crc_injection_busy_i,
                                  crc_inj_count_q,
                                  crc_inj_en_q,
                                  3'b0,
                                  parity_nak_rcvd_q,
                                  num_64b_inserts_q,
                                  rt_link_test_rx_q,
                                  rt_link_test_tx_q,
                                  remote_reg_thresh_q};

                    default:
                        rdata <= 32'b0;
                endcase
            end
        end
    end

endmodule
