`timescale 1ns/1ps

module UCIe_adapter_csr_block
    import UCIe_csr_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // SW register access (DWORD-aligned, 4KB space)
    input  logic        csr_wr_en,
    input  logic        csr_rd_en,
    input  logic [11:0] csr_addr,
    input  logic [31:0] csr_wdata,
    output logic [31:0] csr_rdata,
    output logic        csr_rdata_valid,

    // HW-init straps
    input  logic        strap_raw_mode_cap,
    input  logic [2:0]  strap_max_link_width,
    input  logic [3:0]  strap_max_link_speed,
    input  logic        strap_multi_stack_cap,
    input  logic        strap_adv_packaging,

    // HW status from PHY / RDI / adapter FSM
    input  logic        hw_raw_mode_enabled,
    input  logic        hw_multi_stack_enabled,
    input  logic [3:0]  hw_link_width_enabled,
    input  logic [3:0]  hw_link_speed_enabled,
    input  logic        hw_link_is_up,
    input  logic        hw_link_training,
    input  logic        link_training_done,
    input  logic        crc_injection_busy,

    input  logic        hw_link_status_changed,
    input  logic        hw_auto_bw_changed,

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

    // header log 2
    input  logic [3:0]  hw_timeout_encoding,
    input  logic [2:0]  hw_overflow_encoding,
    input  logic [2:0]  hw_lsm_response_type,
    input  logic        hw_lsm_id,
    input  logic        hw_param_exchange_ok,
    input  logic [3:0]  hw_flit_format,

    // header log 1
    input  logic [31:0] hw_hdr_log1_lo,
    input  logic [31:0] hw_hdr_log1_hi,

    // parity logs
    input  logic [31:0] hw_parity_log0_lo,
    input  logic [31:0] hw_parity_log0_hi,
    input  logic [31:0] hw_parity_log1_lo,
    input  logic [31:0] hw_parity_log1_hi,

    // capability logs
    input  logic [31:0] hw_adv_adp_cap_lo,
    input  logic [31:0] hw_adv_adp_cap_hi,
    input  logic [31:0] hw_fin_adp_cap_lo,
    input  logic [31:0] hw_fin_adp_cap_hi,
    input  logic        hw_cap_log_valid,

    // config outputs to adapter datapath / PHY
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

    output logic [5:0]  ucerr_masked,
    output logic [5:0]  ucerr_severity,
    output logic [3:0]  cerr_masked,

    output logic        irq_link_event,
    output logic        irq_link_error
);

    logic [31:0] rdata_cfg, rdata_lnk, rdata_err, rdata_sts;
    logic        rvalid_cfg, rvalid_lnk, rvalid_err, rvalid_sts;

    wire hw_correctable_err_any = hw_crc_error | hw_adp_lsm_retrain |
                                  hw_corr_internal_error | hw_sb_corr_err_msg;
    wire hw_uncorr_nonfatal_any = hw_sb_nonfatal_err_msg;
    wire hw_uncorr_fatal_any    = hw_adapter_timeout | hw_receiver_overflow |
                                  hw_internal_error | hw_sb_fatal_err_msg |
                                  hw_invalid_param_exchange;

    UCIe_config_regs u_config_regs (
        .clk                        (clk),
        .rst_n                      (rst_n),
        .wr_en                      (csr_wr_en),
        .rd_en                      (csr_rd_en),
        .addr                       (csr_addr),
        .wdata                      (csr_wdata),
        .rdata                      (rdata_cfg),
        .rdata_valid                (rvalid_cfg),
        .strap_raw_mode_cap         (strap_raw_mode_cap),
        .strap_max_link_width       (strap_max_link_width),
        .strap_max_link_speed       (strap_max_link_speed),
        .strap_multi_stack_cap      (strap_multi_stack_cap),
        .strap_adv_packaging        (strap_adv_packaging),
        .cfg_raw_mode_en            (cfg_raw_mode_en),
        .cfg_multi_stack_en         (cfg_multi_stack_en),
        .cfg_target_link_width      (cfg_target_link_width),
        .cfg_target_link_speed      (cfg_target_link_speed),
        .cfg_start_link_training    (cfg_start_link_training),
        .cfg_retrain_link           (cfg_retrain_link),
        .cfg_phy_clk_gate_en        (cfg_phy_clk_gate_en),
        .cfg_remote_reg_threshold   (cfg_remote_reg_threshold),
        .cfg_runtime_link_test_tx_en(cfg_runtime_link_test_tx_en),
        .cfg_runtime_link_test_rx_en(cfg_runtime_link_test_rx_en),
        .cfg_crc_injection_en       (cfg_crc_injection_en),
        .cfg_crc_injection_count    (cfg_crc_injection_count),
        .link_training_done         (link_training_done),
        .crc_injection_busy_i       (crc_injection_busy)
    );

    UCIe_link_state_regs u_link_state_regs (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .wr_en                  (csr_wr_en),
        .rd_en                  (csr_rd_en),
        .addr                   (csr_addr),
        .wdata                  (csr_wdata),
        .rdata                  (rdata_lnk),
        .rdata_valid            (rvalid_lnk),
        .hw_raw_mode_enabled    (hw_raw_mode_enabled),
        .hw_multi_stack_enabled (hw_multi_stack_enabled),
        .hw_link_width_enabled  (hw_link_width_enabled),
        .hw_link_speed_enabled  (hw_link_speed_enabled),
        .hw_link_is_up          (hw_link_is_up),
        .hw_link_training       (hw_link_training),
        .hw_link_status_changed (hw_link_status_changed),
        .hw_auto_bw_changed     (hw_auto_bw_changed),
        .hw_correctable_err     (hw_correctable_err_any),
        .hw_uncorr_nonfatal_err (hw_uncorr_nonfatal_any),
        .hw_uncorr_fatal_err    (hw_uncorr_fatal_any),
        .irq_link_event         (irq_link_event),
        .irq_link_error         (irq_link_error)
    );

    UCIe_error_regs u_error_regs (
        .clk                       (clk),
        .rst_n                     (rst_n),
        .wr_en                     (csr_wr_en),
        .rd_en                     (csr_rd_en),
        .addr                      (csr_addr),
        .wdata                     (csr_wdata),
        .rdata                     (rdata_err),
        .rdata_valid               (rvalid_err),
        .hw_adapter_timeout        (hw_adapter_timeout),
        .hw_receiver_overflow      (hw_receiver_overflow),
        .hw_internal_error         (hw_internal_error),
        .hw_sb_fatal_err_msg       (hw_sb_fatal_err_msg),
        .hw_sb_nonfatal_err_msg    (hw_sb_nonfatal_err_msg),
        .hw_invalid_param_exchange (hw_invalid_param_exchange),
        .hw_crc_error              (hw_crc_error),
        .hw_adp_lsm_retrain       (hw_adp_lsm_retrain),
        .hw_corr_internal_error    (hw_corr_internal_error),
        .hw_sb_corr_err_msg        (hw_sb_corr_err_msg),
        .hw_timeout_encoding       (hw_timeout_encoding),
        .hw_overflow_encoding      (hw_overflow_encoding),
        .hw_lsm_response_type      (hw_lsm_response_type),
        .hw_lsm_id                 (hw_lsm_id),
        .hw_param_exchange_ok      (hw_param_exchange_ok),
        .hw_flit_format            (hw_flit_format),
        .hw_hdr_log1_lo            (hw_hdr_log1_lo),
        .hw_hdr_log1_hi            (hw_hdr_log1_hi),
        .hw_parity_log0_lo         (hw_parity_log0_lo),
        .hw_parity_log0_hi         (hw_parity_log0_hi),
        .hw_parity_log1_lo         (hw_parity_log1_lo),
        .hw_parity_log1_hi         (hw_parity_log1_hi),
        .ucerr_masked              (ucerr_masked),
        .ucerr_severity            (ucerr_severity),
        .cerr_masked               (cerr_masked)
    );

    UCIe_status_regs u_status_regs (
        .clk               (clk),
        .rst_n             (rst_n),
        .wr_en             (csr_wr_en),
        .rd_en             (csr_rd_en),
        .addr              (csr_addr),
        .wdata             (csr_wdata),
        .rdata             (rdata_sts),
        .rdata_valid       (rvalid_sts),
        .hw_adv_adp_cap_lo (hw_adv_adp_cap_lo),
        .hw_adv_adp_cap_hi (hw_adv_adp_cap_hi),
        .hw_fin_adp_cap_lo (hw_fin_adp_cap_lo),
        .hw_fin_adp_cap_hi (hw_fin_adp_cap_hi),
        .hw_cap_log_valid  (hw_cap_log_valid)
    );

    // read data mux (only one submodule drives non-zero per address)
    always_comb begin
        csr_rdata       = rdata_cfg | rdata_lnk | rdata_err | rdata_sts;
        csr_rdata_valid = rvalid_cfg | rvalid_lnk | rvalid_err | rvalid_sts;
    end

endmodule
