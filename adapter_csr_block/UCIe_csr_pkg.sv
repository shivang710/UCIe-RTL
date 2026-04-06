`timescale 1ns/1ps

package UCIe_csr_pkg;

    localparam ADDR_WIDTH = 12;
    localparam DATA_WIDTH = 32;

    // D2D Adapter register offsets
    localparam REG_BLK_HDR_LO      = 12'h000;
    localparam REG_BLK_HDR_HI      = 12'h004;
    localparam REG_LINK_CAP        = 12'h00C;
    localparam REG_LINK_CTRL       = 12'h010;
    localparam REG_LINK_STATUS     = 12'h014;
    localparam REG_LINK_EVT_CTRL   = 12'h018;
    localparam REG_ERR_NOTIF_CTRL  = 12'h01C;
    localparam REG_UCERR_STS       = 12'h040;
    localparam REG_UCERR_MASK      = 12'h044;
    localparam REG_UCERR_SEV       = 12'h048;
    localparam REG_CERR_STS        = 12'h04C;
    localparam REG_CERR_MASK       = 12'h050;
    localparam REG_HDR_LOG1_LO     = 12'h054;
    localparam REG_HDR_LOG1_HI     = 12'h058;
    localparam REG_HDR_LOG2        = 12'h05C;
    localparam REG_ERR_LINK_TEST   = 12'h060;
    localparam REG_PARITY_LOG0_LO  = 12'h064;
    localparam REG_PARITY_LOG0_HI  = 12'h068;
    localparam REG_PARITY_LOG1_LO  = 12'h06C;
    localparam REG_PARITY_LOG1_HI  = 12'h070;
    localparam REG_ADV_ADP_CAP_LO  = 12'h074;
    localparam REG_ADV_ADP_CAP_HI  = 12'h078;
    localparam REG_FIN_ADP_CAP_LO  = 12'h07C;
    localparam REG_FIN_ADP_CAP_HI  = 12'h080;

    typedef enum logic [2:0] {
        LINK_WIDTH_X16  = 3'h0,
        LINK_WIDTH_X32  = 3'h1,
        LINK_WIDTH_X64  = 3'h2,
        LINK_WIDTH_X128 = 3'h3,
        LINK_WIDTH_X256 = 3'h4
    } link_width_t;

    typedef enum logic [3:0] {
        LINK_SPEED_4GT  = 4'h0,
        LINK_SPEED_8GT  = 4'h1,
        LINK_SPEED_12GT = 4'h2,
        LINK_SPEED_16GT = 4'h3,
        LINK_SPEED_24GT = 4'h4,
        LINK_SPEED_32GT = 4'h5
    } link_speed_t;

    typedef enum logic [3:0] {
        TIMEOUT_NONE            = 4'h0,
        TIMEOUT_PARAM_EXCHANGE  = 4'h1,
        TIMEOUT_LSM_NO_RESP     = 4'h2,
        TIMEOUT_LSM_ACTIVE      = 4'h3,
        TIMEOUT_RETRY           = 4'h4,
        TIMEOUT_LOCAL_SB        = 4'h5,
        TIMEOUT_RETIMER_CREDIT  = 4'h6,
        TIMEOUT_REMOTE_REG      = 4'h7
    } adapter_timeout_t;

endpackage
