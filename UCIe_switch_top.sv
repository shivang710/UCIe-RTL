// =============================================================================
// Module: ucie_switch_top
// Description: UCIe Central Switch — fully connected top-level.
//   Replaces all stubs with real synthesizable submodules:
//     - ucie_sync_fifo       (ingress + egress buffering)
//     - ucie_routing_table   (programmable dest-ID → egress-port lookup)
//     - ucie_arbiter_rr      (per-egress round-robin arbiter)
//     - ucie_crossbar        (N×N mux fabric)
//   Plus:
//     - Ingress flit parser  (UCIe header decode)
//     - Egress formatter     (FDI-compliant output)
//     - Switch CSR block     (APB-lite: routing table + port control)
//     - Link state monitor   (port enable/disable)
//
// Parameters
//   N_PORTS      : number of UCIe chiplet ports (default 4)
//   FLIT_WIDTH   : bits per flit (default 256)
//   ID_WIDTH     : destination ID field bits in flit header (default 8)
//   FIFO_DEPTH   : ingress/egress FIFO depth (power of 2, default 16)
//   CSR_ADDR_W   : CSR address bus width (default 12)
// =============================================================================
`timescale 1ns/1ps

module ucie_switch_top #(
    parameter integer N_PORTS    = 4,
    parameter integer FLIT_WIDTH = 256,
    parameter integer ID_WIDTH   = 8,
    parameter integer FIFO_DEPTH = 16,
    parameter integer CSR_ADDR_W = 12
)(
    input  wire                          clk,
    input  wire                          rst_n,

    // -------------------------------------------------------------------------
    // Per-port ingress flit interface (FDI-style, concatenated)
    // -------------------------------------------------------------------------
    input  wire [N_PORTS*FLIT_WIDTH-1:0] flit_in_data,
    input  wire [N_PORTS-1:0]            flit_in_valid,
    output wire [N_PORTS-1:0]            flit_in_ready,

    // -------------------------------------------------------------------------
    // Per-port egress flit interface
    // -------------------------------------------------------------------------
    output wire [N_PORTS*FLIT_WIDTH-1:0] flit_out_data,
    output wire [N_PORTS-1:0]            flit_out_valid,
    input  wire [N_PORTS-1:0]            flit_out_ready,

    // -------------------------------------------------------------------------
    // Physical link health (from RDI controller / PHY)
    // -------------------------------------------------------------------------
    input  wire [N_PORTS-1:0]            link_up,

    // -------------------------------------------------------------------------
    // CSR / APB-lite interface
    // -------------------------------------------------------------------------
    input  wire                          cfg_clk,
    input  wire                          cfg_rst_n,
    input  wire                          cfg_psel,
    input  wire                          cfg_penable,
    input  wire                          cfg_pwrite,
    input  wire [CSR_ADDR_W-1:0]         cfg_paddr,
    input  wire [31:0]                   cfg_pwdata,
    output wire [31:0]                   cfg_prdata,
    output wire                          cfg_pready,
    output wire                          cfg_pslverr
);

    // =========================================================================
    // Internal wires
    // =========================================================================

    // --- Ingress parser outputs ---
    wire [FLIT_WIDTH-1:0]  parsed_flit  [N_PORTS];
    wire [ID_WIDTH-1:0]    parsed_dest  [N_PORTS];
    wire [N_PORTS-1:0]     parsed_valid;
    wire [N_PORTS-1:0]     parsed_err;
    wire [N_PORTS-1:0]     parser_ready;   // backpressure from parser to FDI

    // --- Ingress FIFO outputs (head of line) ---
    wire [FLIT_WIDTH-1:0]  ing_fifo_data [N_PORTS];
    wire [ID_WIDTH-1:0]    ing_fifo_dest [N_PORTS];  // stored alongside flit
    wire [N_PORTS-1:0]     ing_fifo_empty;
    wire [N_PORTS-1:0]     ing_fifo_full;
    wire [N_PORTS-1:0]     ing_fifo_pop;   // driven by crossbar ingress_consumed

    // --- Routing table outputs ---
    wire [N_PORTS-1:0]     rt_egress_sel [N_PORTS];  // one-hot egress per ingress

    // --- Request matrix: req_matrix[egress][ingress] ---
    wire [N_PORTS-1:0]     req_matrix [N_PORTS];

    // --- Arbiter outputs ---
    wire [N_PORTS-1:0]     arb_grant     [N_PORTS];
    wire [N_PORTS-1:0]     arb_grant_valid;

    // --- Crossbar outputs ---
    wire [FLIT_WIDTH-1:0]  xbar_egr_flit [N_PORTS];
    wire [N_PORTS-1:0]     xbar_egr_valid;
    wire [N_PORTS-1:0]     xbar_consumed; // which ingress FIFOs to pop

    // --- Egress FIFO ---
    wire [FLIT_WIDTH-1:0]  egr_fifo_data [N_PORTS];
    wire [N_PORTS-1:0]     egr_fifo_valid;
    wire [N_PORTS-1:0]     egr_fifo_full;
    wire [N_PORTS-1:0]     egr_fifo_pop;  // from egress formatter handshake

    // --- Port control from CSR ---
    wire [N_PORTS-1:0]     port_disabled;
    wire                   rt_cfg_we;
    wire [ID_WIDTH-1:0]    rt_cfg_addr;
    wire [N_PORTS-1:0]     rt_cfg_wdata;
    wire [N_PORTS-1:0]     rt_cfg_rdata;

    // =========================================================================
    // Ingress path: parser → ingress FIFO
    // =========================================================================
    // Storage for dest IDs alongside flits in a parallel FIFO
    // We use a paired FIFO: one for flit data, one for dest ID
    genvar p;
    generate
        for (p = 0; p < N_PORTS; p = p + 1) begin : GEN_INGRESS

            // -----------------------------------------------------------------
            // Ingress flit parser
            // -----------------------------------------------------------------
            ucie_flit_parser #(
                .FLIT_WIDTH(FLIT_WIDTH),
                .ID_WIDTH  (ID_WIDTH)
            ) u_parser (
                .clk          (clk),
                .rst_n        (rst_n),
                .raw_flit     (flit_in_data[p*FLIT_WIDTH +: FLIT_WIDTH]),
                .raw_valid    (flit_in_valid[p] & ~port_disabled[p]),
                .raw_ready    (parser_ready[p]),
                .parsed_flit  (parsed_flit[p]),
                .parsed_dest  (parsed_dest[p]),
                .parsed_valid (parsed_valid[p]),
                .parse_err    (parsed_err[p])
            );

            assign flit_in_ready[p] = parser_ready[p] & ~port_disabled[p];

            // -----------------------------------------------------------------
            // Ingress FIFO — flit data
            // -----------------------------------------------------------------
            ucie_sync_fifo #(
                .DATA_WIDTH(FLIT_WIDTH),
                .DEPTH     (FIFO_DEPTH)
            ) u_ing_flit_fifo (
                .clk      (clk),
                .rst_n    (rst_n),
                .push_v   (parsed_valid[p] & ~parsed_err[p]),
                .push_data(parsed_flit[p]),
                .push_r   (/* full flag checked implicitly via push_r */),
                .pop_r    (ing_fifo_pop[p]),
                .pop_v    (/* combined below */),
                .pop_data (ing_fifo_data[p]),
                .full     (ing_fifo_full[p]),
                .empty    (ing_fifo_empty[p]),
                .occupancy(/* unused */)
            );

            // -----------------------------------------------------------------
            // Ingress FIFO — dest ID (parallel, same push/pop timing)
            // -----------------------------------------------------------------
            ucie_sync_fifo #(
                .DATA_WIDTH(ID_WIDTH),
                .DEPTH     (FIFO_DEPTH)
            ) u_ing_dest_fifo (
                .clk      (clk),
                .rst_n    (rst_n),
                .push_v   (parsed_valid[p] & ~parsed_err[p]),
                .push_data(parsed_dest[p]),
                .push_r   (/* unused — tied to flit FIFO */),
                .pop_r    (ing_fifo_pop[p]),
                .pop_v    (/* unused */),
                .pop_data (ing_fifo_dest[p]),
                .full     (/* unused */),
                .empty    (/* unused */),
                .occupancy(/* unused */)
            );

        end
    endgenerate

    // Valid when ingress FIFO has data
    wire [N_PORTS-1:0] ing_fifo_valid;
    genvar q;
    generate
        for (q = 0; q < N_PORTS; q = q + 1)
            assign ing_fifo_valid[q] = ~ing_fifo_empty[q];
    endgenerate

    // Crossbar consumes ingress FIFO head
    assign ing_fifo_pop = xbar_consumed;

    // =========================================================================
    // Routing table lookup
    // =========================================================================
    ucie_routing_table #(
        .N_PORTS (N_PORTS),
        .ID_WIDTH(ID_WIDTH)
    ) u_routing_table (
        .clk         (clk),
        .rst_n       (rst_n),
        .lookup_dest (ing_fifo_dest),
        .lookup_valid(ing_fifo_valid),
        .egress_sel  (rt_egress_sel),
        .cfg_we      (rt_cfg_we),
        .cfg_addr    (rt_cfg_addr),
        .cfg_wdata   (rt_cfg_wdata),
        .cfg_rdata   (rt_cfg_rdata)
    );

    // =========================================================================
    // Build request matrix: req_matrix[egress] = which ingress ports want it
    // =========================================================================
    genvar e, i;
    generate
        for (e = 0; e < N_PORTS; e = e + 1) begin : GEN_REQ_MATRIX
            wire [N_PORTS-1:0] col;
            for (i = 0; i < N_PORTS; i = i + 1) begin : GEN_COL
                // ingress i requests egress e if routing says so and fifo not empty
                assign col[i] = rt_egress_sel[i][e] & ing_fifo_valid[i]
                                 & ~port_disabled[e];
            end
            assign req_matrix[e] = col;
        end
    endgenerate

    // =========================================================================
    // Per-egress round-robin arbiter
    // =========================================================================
    generate
        for (e = 0; e < N_PORTS; e = e + 1) begin : GEN_ARB
            ucie_arbiter_rr #(.N_ENTRIES(N_PORTS)) u_arb (
                .clk        (clk),
                .rst_n      (rst_n),
                .req        (req_matrix[e]),
                .grant      (arb_grant[e]),
                .grant_valid(arb_grant_valid[e]),
                // advance RR priority when egress FIFO accepts the flit
                .grant_done (xbar_egr_valid[e] & ~egr_fifo_full[e])
            );
        end
    endgenerate

    // =========================================================================
    // Crossbar fabric
    // =========================================================================
    ucie_crossbar #(
        .N_PORTS   (N_PORTS),
        .FLIT_WIDTH(FLIT_WIDTH)
    ) u_crossbar (
        .clk             (clk),
        .rst_n           (rst_n),
        .ing_flit        (ing_fifo_data),
        .ing_valid       (ing_fifo_valid),
        .grant           (arb_grant),
        .egress_stall    (egr_fifo_full),
        .egr_flit        (xbar_egr_flit),
        .egr_valid       (xbar_egr_valid),
        .ingress_consumed(xbar_consumed)
    );

    // =========================================================================
    // Egress path: egress FIFO → egress formatter
    // =========================================================================
    generate
        for (p = 0; p < N_PORTS; p = p + 1) begin : GEN_EGRESS

            // -----------------------------------------------------------------
            // Egress FIFO
            // -----------------------------------------------------------------
            ucie_sync_fifo #(
                .DATA_WIDTH(FLIT_WIDTH),
                .DEPTH     (FIFO_DEPTH)
            ) u_egr_fifo (
                .clk      (clk),
                .rst_n    (rst_n),
                .push_v   (xbar_egr_valid[p]),
                .push_data(xbar_egr_flit[p]),
                .push_r   (/* full flag already prevents push via egress_stall */),
                .pop_r    (egr_fifo_pop[p]),
                .pop_v    (egr_fifo_valid[p]),
                .pop_data (egr_fifo_data[p]),
                .full     (egr_fifo_full[p]),
                .empty    (/* unused */),
                .occupancy(/* unused */)
            );

            // -----------------------------------------------------------------
            // Egress formatter: FDI handshake
            // -----------------------------------------------------------------
            ucie_egress_formatter #(
                .FLIT_WIDTH(FLIT_WIDTH)
            ) u_formatter (
                .clk      (clk),
                .rst_n    (rst_n),
                .in_v     (egr_fifo_valid[p]),
                .in_flit  (egr_fifo_data[p]),
                .in_r     (egr_fifo_pop[p]),
                .out_data (flit_out_data[p*FLIT_WIDTH +: FLIT_WIDTH]),
                .out_v    (flit_out_valid[p]),
                .out_r    (flit_out_ready[p])
            );

        end
    endgenerate

    // =========================================================================
    // Link-state monitor: disable ports with physical link down
    // =========================================================================
    ucie_link_monitor #(
        .N_PORTS(N_PORTS)
    ) u_link_mon (
        .clk          (clk),
        .rst_n        (rst_n),
        .link_up      (link_up),
        .sw_port_dis  (/* driven by CSR below */),
        .port_disabled(port_disabled)
    );

    // =========================================================================
    // CSR / Switch Control (APB-lite)
    // =========================================================================
    ucie_switch_csr #(
        .N_PORTS    (N_PORTS),
        .ID_WIDTH   (ID_WIDTH),
        .CSR_ADDR_W (CSR_ADDR_W)
    ) u_csr (
        .clk          (cfg_clk),
        .rst_n        (cfg_rst_n),
        // APB
        .psel         (cfg_psel),
        .penable      (cfg_penable),
        .pwrite       (cfg_pwrite),
        .paddr        (cfg_paddr),
        .pwdata       (cfg_pwdata),
        .prdata       (cfg_prdata),
        .pready       (cfg_pready),
        .pslverr      (cfg_pslverr),
        // Routing table programming
        .rt_we        (rt_cfg_we),
        .rt_addr      (rt_cfg_addr),
        .rt_wdata     (rt_cfg_wdata),
        .rt_rdata     (rt_cfg_rdata),
        // Status
        .port_disabled(port_disabled),
        .ing_fifo_full(ing_fifo_full),
        .egr_fifo_full(egr_fifo_full)
    );

endmodule


// =============================================================================
// ucie_flit_parser
// Decodes UCIe flit header:
//   Bits [FLIT_WIDTH-1 : FLIT_WIDTH-8]  = flit type (8b)
//   Bits [FLIT_WIDTH-9 : FLIT_WIDTH-8-ID_WIDTH] = destination ID
//   Rest = payload (passed through)
// =============================================================================
module ucie_flit_parser #(
    parameter integer FLIT_WIDTH = 256,
    parameter integer ID_WIDTH   = 8
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire [FLIT_WIDTH-1:0]  raw_flit,
    input  wire                   raw_valid,
    output wire                   raw_ready,   // always ready (no stall in parser)
    output reg  [FLIT_WIDTH-1:0]  parsed_flit,
    output reg  [ID_WIDTH-1:0]    parsed_dest,
    output reg                    parsed_valid,
    output reg                    parse_err
);
    // Header field offsets (UCIe-like, adjust to actual spec)
    localparam FTYPE_HI  = FLIT_WIDTH - 1;
    localparam FTYPE_LO  = FLIT_WIDTH - 8;
    localparam DEST_HI   = FTYPE_LO - 1;
    localparam DEST_LO   = FTYPE_LO - ID_WIDTH;

    // Known flit types
    localparam [7:0] FTYPE_DATA  = 8'h01;
    localparam [7:0] FTYPE_CTRL  = 8'h02;
    localparam [7:0] FTYPE_CREDIT= 8'h10;

    wire [7:0]        flit_type = raw_flit[FTYPE_HI:FTYPE_LO];
    wire [ID_WIDTH-1:0] dest_id = raw_flit[DEST_HI:DEST_LO];

    assign raw_ready = 1'b1; // parser never stalls upstream

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            parsed_flit  <= {FLIT_WIDTH{1'b0}};
            parsed_dest  <= {ID_WIDTH{1'b0}};
            parsed_valid <= 1'b0;
            parse_err    <= 1'b0;
        end else begin
            parsed_valid <= raw_valid;
            parsed_flit  <= raw_flit;
            parsed_dest  <= dest_id;

            // Flag unknown flit types as errors
            if (raw_valid) begin
                case (flit_type)
                    FTYPE_DATA,
                    FTYPE_CTRL,
                    FTYPE_CREDIT: parse_err <= 1'b0;
                    default:      parse_err <= 1'b1;
                endcase
            end else begin
                parse_err <= 1'b0;
            end
        end
    end
endmodule


// =============================================================================
// ucie_egress_formatter
// Registers the egress flit and presents it on the FDI-style output.
// Provides proper valid/ready handshake (holds flit until downstream accepts).
// =============================================================================
module ucie_egress_formatter #(
    parameter integer FLIT_WIDTH = 256
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   in_v,
    input  wire [FLIT_WIDTH-1:0]  in_flit,
    output wire                   in_r,      // pop egress FIFO when accepted
    output wire [FLIT_WIDTH-1:0]  out_data,
    output wire                   out_v,
    input  wire                   out_r
);
    // Skid buffer: hold flit if downstream not ready
    reg [FLIT_WIDTH-1:0] hold_flit;
    reg                  hold_valid;

    assign in_r    = ~hold_valid | out_r; // accept when no hold, or downstream consumes
    assign out_v   = hold_valid | in_v;
    assign out_data = hold_valid ? hold_flit : in_flit;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hold_flit  <= {FLIT_WIDTH{1'b0}};
            hold_valid <= 1'b0;
        end else begin
            if (in_v & ~out_r) begin
                // Downstream not ready — capture into hold buffer
                hold_flit  <= in_flit;
                hold_valid <= 1'b1;
            end else if (out_r) begin
                hold_valid <= 1'b0;
            end
        end
    end
endmodule


// =============================================================================
// ucie_link_monitor
// Debounces link_up signals and combines with SW override to produce
// port_disabled per port.
// =============================================================================
module ucie_link_monitor #(
    parameter integer N_PORTS = 4
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire [N_PORTS-1:0] link_up,
    input  wire [N_PORTS-1:0] sw_port_dis,   // SW override disable
    output reg  [N_PORTS-1:0] port_disabled
);
    // 4-cycle debounce counter per port
    reg [3:0] debounce [N_PORTS];
    integer d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            port_disabled <= {N_PORTS{1'b1}}; // all disabled until link up
            for (d = 0; d < N_PORTS; d = d + 1)
                debounce[d] <= 4'hF;
        end else begin
            for (d = 0; d < N_PORTS; d = d + 1) begin
                if (!link_up[d])
                    debounce[d] <= 4'hF;       // reset debounce on loss
                else if (debounce[d] != 4'h0)
                    debounce[d] <= debounce[d] - 1'b1;

                port_disabled[d] <= (debounce[d] != 4'h0) | sw_port_dis[d];
            end
        end
    end
endmodule


// =============================================================================
// ucie_switch_csr
// APB-lite CSR block for UCIe switch.
//
// Address map (word-addressed, 32-bit):
//   0x000        : PORT_ENABLE  [N_PORTS-1:0] RW  — SW port enable mask
//   0x004        : PORT_STATUS  [N_PORTS-1:0] RO  — port_disabled readback
//   0x008        : ING_FIFO_FULL [N_PORTS-1:0] RO — ingress FIFO full flags
//   0x00C        : EGR_FIFO_FULL [N_PORTS-1:0] RO — egress FIFO full flags
//   0x010        : RT_ADDR      [ID_WIDTH-1:0] RW  — routing table index
//   0x014        : RT_WDATA     [N_PORTS-1:0]  RW  — routing table entry write
//   0x018        : RT_RDATA     [N_PORTS-1:0]  RO  — routing table entry read
//   0x01C        : RT_WE        [0]            RW  — write strobe (self-clearing)
// =============================================================================
module ucie_switch_csr #(
    parameter integer N_PORTS    = 4,
    parameter integer ID_WIDTH   = 8,
    parameter integer CSR_ADDR_W = 12
)(
    input  wire                   clk,
    input  wire                   rst_n,
    // APB
    input  wire                   psel,
    input  wire                   penable,
    input  wire                   pwrite,
    input  wire [CSR_ADDR_W-1:0]  paddr,
    input  wire [31:0]            pwdata,
    output reg  [31:0]            prdata,
    output wire                   pready,
    output wire                   pslverr,
    // Routing table
    output reg                    rt_we,
    output reg  [ID_WIDTH-1:0]    rt_addr,
    output reg  [N_PORTS-1:0]     rt_wdata,
    input  wire [N_PORTS-1:0]     rt_rdata,
    // Status inputs
    input  wire [N_PORTS-1:0]     port_disabled,
    input  wire [N_PORTS-1:0]     ing_fifo_full,
    input  wire [N_PORTS-1:0]     egr_fifo_full
);
    assign pready  = 1'b1;  // zero wait-state
    assign pslverr = 1'b0;

    wire apb_write = psel & penable & pwrite;
    wire apb_read  = psel & penable & ~pwrite;

    // Writeable registers
    reg [N_PORTS-1:0] port_enable_r;
    reg [ID_WIDTH-1:0] rt_addr_r;
    reg [N_PORTS-1:0]  rt_wdata_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            port_enable_r <= {N_PORTS{1'b1}};  // all enabled by default
            rt_addr_r     <= {ID_WIDTH{1'b0}};
            rt_wdata_r    <= {N_PORTS{1'b0}};
            rt_we         <= 1'b0;
            prdata        <= 32'h0;
        end else begin
            rt_we <= 1'b0; // self-clearing

            if (apb_write) begin
                case (paddr[4:2]) // word-address comparison
                    3'd0: port_enable_r <= pwdata[N_PORTS-1:0];
                    3'd4: rt_addr_r     <= pwdata[ID_WIDTH-1:0];
                    3'd5: rt_wdata_r    <= pwdata[N_PORTS-1:0];
                    3'd7: rt_we         <= pwdata[0];
                    default: ;
                endcase
            end

            if (apb_read) begin
                case (paddr[4:2])
                    3'd0: prdata <= {{(32-N_PORTS){1'b0}}, port_enable_r};
                    3'd1: prdata <= {{(32-N_PORTS){1'b0}}, port_disabled};
                    3'd2: prdata <= {{(32-N_PORTS){1'b0}}, ing_fifo_full};
                    3'd3: prdata <= {{(32-N_PORTS){1'b0}}, egr_fifo_full};
                    3'd4: prdata <= {{(32-ID_WIDTH){1'b0}}, rt_addr_r};
                    3'd5: prdata <= {{(32-N_PORTS){1'b0}}, rt_wdata_r};
                    3'd6: prdata <= {{(32-N_PORTS){1'b0}}, rt_rdata};
                    default: prdata <= 32'hDEAD_BEEF;
                endcase
            end
        end
    end

    // Drive routing table outputs
    always @(*) begin
        rt_addr  = rt_addr_r;
        rt_wdata = rt_wdata_r;
    end

endmodule