// ucie_switch_top.sv
// Top-level wrapper for UCIe Central Switch
// - Parameterized N ports
// - Flit handshake per-port (flit_data / valid / ready)
// - Instantiates stubs for mandatory modules:
//    Ingress Parser, Ingress FIFO, Routing Table, Arbiter,
//    Crossbar Fabric, Egress FIFO, Egress Formatter, Switch Control
//
// Notes:
// - This is a structural top wrapper (control/data wiring).
// - Submodules are provided as stubs; implement internal behavior per spec.
// - Author: ChatGPT (for iterative expansion)

`timescale 1ns/1ps

module ucie_switch_top #(
    parameter integer N_PORTS    = 4,              // number of chiplet ports
    parameter integer FLIT_WIDTH = 256,            // flit width in bits (e.g., 256)
    parameter integer ID_WIDTH   = 16,             // destination ID field width
    parameter integer CSR_ADDR_WIDTH = 12          // CSR address width
)(
    input  logic                     clk,
    input  logic                     rst_n,

    // Per-port input flit interface (FDI-style)
    input  logic [N_PORTS*FLIT_WIDTH-1:0] flit_in_data,   // concatenated [P-1:0] flit
    input  logic [N_PORTS-1:0]            flit_in_valid,
    output logic [N_PORTS-1:0]            flit_in_ready,

    // Per-port output flit interface (FDI-style)
    output logic [N_PORTS*FLIT_WIDTH-1:0] flit_out_data,
    output logic [N_PORTS-1:0]            flit_out_valid,
    input  logic [N_PORTS-1:0]            flit_out_ready,

    // Link health/status (simple up flag per port)
    input  logic [N_PORTS-1:0] link_up,

    // CSR/APB/AXI-Lite (minimal) for config & status
    input  logic                     cfg_clk,
    input  logic                     cfg_rst_n,
    input  logic                     cfg_valid,      // simple valid/addr/data handshake for example
    input  logic [CSR_ADDR_WIDTH-1:0] cfg_addr,
    input  logic [31:0]              cfg_wdata,
    input  logic                     cfg_write,
    output logic [31:0]              cfg_rdata,
    output logic                     cfg_ready
);

    // ---------- Local typedefs / helpers ----------
    localparam integer PORT = N_PORTS;
    // Helper to index flits in concatenated vector
    function automatic int flit_hi(int p); return (p+1)*FLIT_WIDTH-1; endfunction
    function automatic int flit_lo(int p); return p*FLIT_WIDTH; endfunction

    // Parsed header signals (one-hot or ID per ingress port)
    logic [PORT-1:0]               ingress_valid;
    logic [PORT-1:0]               ingress_ready;
    logic [ID_WIDTH-1:0]           ingress_dest_id [PORT]; // unpacked per-port dest ID
    logic [FLIT_WIDTH-1:0]         ingress_flit   [PORT];
    logic                          ingress_err    [PORT];   // parse error

    // Ingress FIFO outputs (after parser + fifo)
    logic [PORT-1:0]               fifo_to_route_valid;
    logic [PORT-1:0]               fifo_to_route_ready;
    logic [ID_WIDTH-1:0]           fifo_dest_id   [PORT];
    logic [FLIT_WIDTH-1:0]         fifo_flit      [PORT];

    // Arbitration outputs (which ingress wins to which egress)
    // For simplicity, arbiter will produce per-egress grant vectors indicating which ingress selected.
    logic [PORT-1:0]               arb_grant     [PORT]; // arb_grant[egr][ing]

    // Crossbar internal wires
    logic [FLIT_WIDTH-1:0]         xbar_in_flit  [PORT]; // selected flit presented to each egress
    logic [PORT-1:0]               xbar_in_valid [PORT];
    logic [PORT-1:0]               xbar_in_ready [PORT];

    // Egress FIFO -> Egress Formatter signals
    logic [PORT-1:0]               egress_valid;
    logic [PORT-1:0]               egress_ready;
    logic [FLIT_WIDTH-1:0]         egress_flit [PORT];

    // Link-state monitor signals
    logic [PORT-1:0] port_disabled;

    // CSR/status registers (simple)
    logic [31:0]  port_status_cnt [PORT]; // telemetry counters (example)

    // ---------- Per-port generate: Ingress parser and FIFO ----------
    genvar pi;
    generate
        for (pi = 0; pi < PORT; pi = pi + 1) begin : GEN_INGRESS
            // Extract per-port flit signals from concatenated buses
            assign ingress_flit[pi] = flit_in_data[flit_hi(pi):flit_lo(pi)];
            assign ingress_valid[pi] = flit_in_valid[pi];

            // Ingress parser: parses header to extract destination ID, flags
            ingress_flit_parser #(
                .FLIT_WIDTH(FLIT_WIDTH),
                .ID_WIDTH(ID_WIDTH)
            ) u_ingress_parser (
                .clk       (clk),
                .rst_n     (rst_n),
                .flit_in   (ingress_flit[pi]),
                .flit_v    (ingress_valid[pi]),
                .flit_r    (ingress_ready[pi]),   // parser backpressure to link
                .dest_id   (ingress_dest_id[pi]),
                .valid_out (fifo_to_route_valid[pi]),
                .err       (ingress_err[pi]),
                .parsed_flit_out (fifo_flit[pi])
            );

            // Ingress FIFO: absorb bursts and present to routing fabric
            ingress_fifo #(
                .FLIT_WIDTH(FLIT_WIDTH),
                .DEPTH(16)
            ) u_ingress_fifo (
                .clk        (clk),
                .rst_n      (rst_n),
                .push_v     (fifo_to_route_valid[pi]),
                .push_data  (fifo_flit[pi]),
                .push_r     (fifo_to_route_ready[pi]),
                .pop_v      (/*wired by arbiter: see below*/),
                .pop_r      (/*wired by arbiter*/)
                // expose head dest id for routing decision:
                // For simplicity parser already provided dest id when pushing; routing table will sample head if needed.
            );

            // Hook flit_in_ready back to top-level (basic flow control)
            assign flit_in_ready[pi] = ingress_ready[pi] & ~port_disabled[pi];

            // Basic status counters
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) port_status_cnt[pi] <= 32'd0;
                else if (fifo_to_route_valid[pi] & fifo_to_route_ready[pi]) port_status_cnt[pi] <= port_status_cnt[pi] + 1;
            end
        end
    endgenerate

    // ---------- Routing table ----------
    // Accept requests from ingress FIFOs (request: dest_id), produce target egress port(s)
    // This model assumes unicast routing; routing_table returns egress port index.
    logic [ID_WIDTH-1:0] route_req_dest [PORT];
    logic [PORT-1:0]     route_req_valid;
    logic [PORT-1:0]     route_req_ready;
    logic [PORT-1:0]     route_resp_one_hot [PORT]; // one-hot egress per ingress

    routing_table #(
        .N_PORTS(PORT),
        .ID_WIDTH(ID_WIDTH)
    ) u_routing_table (
        .clk        (clk),
        .rst_n      (rst_n),
        // request array (one entry per ingress)
        .req_valid  (route_req_valid),
        .req_dest   (route_req_dest),
        .req_ready  (route_req_ready),
        // responses: for each ingress a one_hot egress select
        .resp_one_hot(route_resp_one_hot)
    );

    // ---------- Arbiter(s) ----------
    // For each egress port, an arbiter selects among ingress ports that routed to this egress.
    // Build request matrix: req_matrix[egr][ing] = ingress has flit and routing says egr
    logic [PORT-1:0] req_matrix [PORT]; // [egress][ingress]
    // Build matrix
    integer i,j;
    always_comb begin
        // default
        for (i = 0; i < PORT; i = i + 1) begin
            for (j = 0; j < PORT; j = j + 1) begin
                req_matrix[i][j] = 1'b0;
            end
        end
        // populate from route_resp_one_hot & fifo_to_route_valid
        for (j = 0; j < PORT; j = j + 1) begin
            if (fifo_to_route_valid[j]) begin
                // route_resp_one_hot[j] is one-hot vector of target egress for ingress j
                for (i = 0; i < PORT; i = i + 1) begin
                    req_matrix[i][j] = route_resp_one_hot[j][i];
                end
            end
        end
    end

    // Instantiate per-egress arbiter; grants one ingress per egress.
    generate
        for (pi = 0; pi < PORT; pi = pi + 1) begin : GEN_ARBITER
            arbiter_rr #(.N_ENTRIES(PORT)) u_arbiter (
                .clk    (clk),
                .rst_n  (rst_n),
                .req    (req_matrix[pi]),      // requests from all ingress for egress 'pi'
                .grant  (arb_grant[pi])        // one-hot grant vector (which ingress selected)
            );
        end
    endgenerate

    // ---------- Crossbar fabric ----------
    // For each egress port, pick flit from winning ingress based on arb_grant
    // Simple muxing
    always_comb begin
        for (i = 0; i < PORT; i = i + 1) begin
            xbar_in_valid[i] = 1'b0;
            xbar_in_flit[i]  = '0;
            for (j = 0; j < PORT; j = j + 1) begin
                if (arb_grant[i][j]) begin
                    // select head flit from ingress j FIFO
                    xbar_in_valid[i] = fifo_to_route_valid[j];
                    xbar_in_flit[i]  = fifo_flit[j];
                end
            end
        end
    end

    // Accept xbar handshake with egress FIFO/backpressure
    // Egress FIFO instantiation per egress port
    generate
        for (pi = 0; pi < PORT; pi = pi + 1) begin : GEN_EGRESS
            // Egress FIFO
            egress_fifo #(
                .FLIT_WIDTH(FLIT_WIDTH),
                .DEPTH(16)
            ) u_eg_fifo (
                .clk       (clk),
                .rst_n     (rst_n),
                .push_v    (xbar_in_valid[pi]),
                .push_d    (xbar_in_flit[pi]),
                .push_r    (/*tie to grant/pop handshake - omitted for brevity*/),
                .pop_v     (egress_valid[pi]),
                .pop_d     (egress_flit[pi]),
                .pop_r     (egress_ready[pi])
            );

            // Egress formatter: regenerate flit_out_data/valid/ready interface signals
            egress_formatter #(
                .FLIT_WIDTH(FLIT_WIDTH)
            ) u_eg_formatter (
                .clk        (clk),
                .rst_n      (rst_n),
                .in_v       (egress_valid[pi]),
                .in_flit    (egress_flit[pi]),
                .in_r       (egress_ready[pi]),
                .out_data   (flit_out_data[flit_hi(pi):flit_lo(pi)]),
                .out_v      (flit_out_valid[pi]),
                .out_r      (flit_out_ready[pi])
            );
        end
    endgenerate

    // ---------- Simple link-state monitor (disable ports with link_down) ----------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            port_disabled <= '0;
        end else begin
            // disable any port which has link_up=0
            for (i = 0; i < PORT; i = i + 1) begin
                port_disabled[i] <= ~link_up[i];
            end
        end
    end

    // ---------- Simple CSR / control block (stub) ----------
    switch_control #(
        .N_PORTS(PORT),
        .CSR_ADDR_WIDTH(CSR_ADDR_WIDTH)
    ) u_switch_ctrl (
        .clk        (cfg_clk),
        .rst_n      (cfg_rst_n),
        .cfg_valid  (cfg_valid),
        .cfg_addr   (cfg_addr),
        .cfg_wdata  (cfg_wdata),
        .cfg_write  (cfg_write),
        .cfg_rdata  (cfg_rdata),
        .cfg_ready  (cfg_ready),

        // status hooks
        .port_disabled (port_disabled)
    );

endmodule


// ============================================================================
// Submodule stubs (interfaces only) - implement per spec
// ============================================================================

// Ingress Flit Parser: extracts destination ID and passes flit to FIFO
module ingress_flit_parser #(
    parameter integer FLIT_WIDTH = 256,
    parameter integer ID_WIDTH   = 16
)(
    input  logic                     clk,
    input  logic                     rst_n,
    input  logic [FLIT_WIDTH-1:0]    flit_in,
    input  logic                     flit_v,
    output logic                     flit_r,        // backpressure to link
    output logic [ID_WIDTH-1:0]      dest_id,
    output logic                     valid_out,     // push into ingress FIFO
    output logic                     err,
    output logic [FLIT_WIDTH-1:0]    parsed_flit_out
);
    // Simple pass-through parser stub (real parser must extract header fields)
    assign parsed_flit_out = flit_in;
    assign dest_id = flit_in[ID_WIDTH-1:0]; // placeholder: real header mapping needed
    assign valid_out = flit_v;
    assign err = 1'b0;
    assign flit_r = 1'b1;
endmodule


// Ingress FIFO (push/pop handshake)
// Minimal stub; implement robust FIFO with occupancy, flow control, and head peek
module ingress_fifo #(
    parameter integer FLIT_WIDTH = 256,
    parameter integer DEPTH = 16
)(
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    push_v,
    input  logic [FLIT_WIDTH-1:0]   push_data,
    output logic                    push_r,
    output logic                    pop_v,
    output logic [FLIT_WIDTH-1:0]   pop_data,
    input  logic                    pop_r
);
    // Very small behavioral FIFO (non-synth-friendly placeholder)
    // Implement real FIFO (synthesizable) for production
    always_comb begin
        push_r = 1'b1;
        pop_v  = push_v;
        pop_data = push_data;
    end
endmodule


// Routing Table stub
module routing_table #(
    parameter integer N_PORTS = 4,
    parameter integer ID_WIDTH = 16
)(
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic [N_PORTS-1:0]      req_valid,   // per-ingress request valid (packed)
    input  logic [ID_WIDTH-1:0]     req_dest [N_PORTS],
    output logic [N_PORTS-1:0]      req_ready,
    output logic [N_PORTS-1:0]      resp_one_hot [N_PORTS]
);
    // Simple round-robin mapping as placeholder: dest_id[0] -> port 0, etc.
    integer i;
    always_comb begin
        for (i=0;i<N_PORTS;i=i+1) begin
            req_ready[i] = 1'b1;
            resp_one_hot[i] = '0;
            // naive mapping: low bits of dest point to egress
            resp_one_hot[i][ req_dest[i][ $clog2(N_PORTS)-1 : 0 ] ] = req_valid[i];
        end
    end
endmodule


// Round-robin arbiter stub
module arbiter_rr #(
    parameter integer N_ENTRIES = 4
)(
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic [N_ENTRIES-1:0] req,
    output logic [N_ENTRIES-1:0] grant
);
    // naive priority: pick lowest index request (placeholder)
    integer k;
    always_comb begin
        grant = '0;
        for (k = 0; k < N_ENTRIES; k = k + 1) begin
            if (req[k]) begin
                grant[k] = 1'b1;
                disable for;
            end
        end
    end
endmodule


// Egress FIFO stub
module egress_fifo #(
    parameter integer FLIT_WIDTH = 256,
    parameter integer DEPTH = 16
)(
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    push_v,
    input  logic [FLIT_WIDTH-1:0]   push_d,
    output logic                    push_r,
    output logic                    pop_v,
    output logic [FLIT_WIDTH-1:0]   pop_d,
    input  logic                    pop_r
);
    // pass-through placeholder
    always_comb begin
        push_r = 1'b1;
        pop_v = push_v;
        pop_d = push_d;
    end
endmodule


// Egress Formatter: regenerates FDI signals (valid/ready/data)
module egress_formatter #(
    parameter integer FLIT_WIDTH = 256
)(
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    in_v,
    input  logic [FLIT_WIDTH-1:0]   in_flit,
    output logic                    in_r,
    output logic [FLIT_WIDTH-1:0]   out_data,
    output logic                    out_v,
    input  logic                    out_r
);
    // passthrough stub
    assign out_data = in_flit;
    assign out_v    = in_v;
    assign in_r     = out_r;
endmodule


// Switch control / CSR stub
module switch_control #(
    parameter integer N_PORTS = 4,
    parameter integer CSR_ADDR_WIDTH = 12
)(
    input  logic                     clk,
    input  logic                     rst_n,
    input  logic                     cfg_valid,
    input  logic [CSR_ADDR_WIDTH-1:0] cfg_addr,
    input  logic [31:0]              cfg_wdata,
    input  logic                     cfg_write,
    output logic [31:0]              cfg_rdata,
    output logic                     cfg_ready,
    input  logic [N_PORTS-1:0]       port_disabled
);
    // very small CSR: return port_disabled mask in read 0
    assign cfg_ready = cfg_valid;
    assign cfg_rdata = (cfg_addr == 0) ? {{(32-N_PORTS){1'b0}}, port_disabled} : 32'd0;
endmodule