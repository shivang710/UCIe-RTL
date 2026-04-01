// =============================================================================
// Module: ucie_routing_table
// Description: Programmable per-destination routing table for UCIe switch.
//   - 2^ID_WIDTH entries, each storing a one-hot egress port vector
//   - Written via CSR interface (cfg_we / cfg_addr / cfg_wdata)
//   - Lookup is fully combinational (single-cycle)
//   - Supports N_PORTS up to 16 (one-hot stored in lower 16 bits of entry)
//   - Invalid/unconfigured destinations map to port 0 (drop/default)
// =============================================================================
`timescale 1ns/1ps

module ucie_routing_table #(
    parameter integer N_PORTS  = 4,
    parameter integer ID_WIDTH = 8    // 2^ID_WIDTH routing entries
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // Lookup interface (one per ingress port, combinational)
    input  wire [ID_WIDTH-1:0]    lookup_dest  [N_PORTS],  // destination IDs
    input  wire [N_PORTS-1:0]     lookup_valid,            // ingress has valid flit
    output wire [N_PORTS-1:0]     egress_sel   [N_PORTS],  // one-hot egress per ingress

    // CSR programming interface
    input  wire                   cfg_we,
    input  wire [ID_WIDTH-1:0]    cfg_addr,    // destination ID to program
    input  wire [N_PORTS-1:0]     cfg_wdata,   // one-hot egress port
    output wire [N_PORTS-1:0]     cfg_rdata    // readback
);
    localparam integer TABLE_DEPTH = 1 << ID_WIDTH;

    // Routing table storage
    reg [N_PORTS-1:0] route_mem [0:TABLE_DEPTH-1];

    // Initialise all entries to port 0 (default/drop)
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < TABLE_DEPTH; k = k + 1)
                route_mem[k] <= {{(N_PORTS-1){1'b0}}, 1'b1}; // default → port 0
        end else if (cfg_we) begin
            route_mem[cfg_addr] <= cfg_wdata;
        end
    end

    // Combinational lookup per ingress port
    genvar gi;
    generate
        for (gi = 0; gi < N_PORTS; gi = gi + 1) begin : GEN_LOOKUP
            assign egress_sel[gi] = lookup_valid[gi]
                                    ? route_mem[lookup_dest[gi]]
                                    : {N_PORTS{1'b0}};
        end
    endgenerate

    // CSR readback
    assign cfg_rdata = route_mem[cfg_addr];

endmodule