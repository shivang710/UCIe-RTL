// =============================================================================
// Module: ucie_crossbar
// Description: N×N non-blocking crossbar fabric for UCIe switch.
//   - For each egress port: one-hot grant selects which ingress drives it
//   - Registered output (one-cycle pipeline stage)
//   - Backpressure: if egress FIFO is full, egress_stall[e] suppresses push
//   - ingress_consumed[i] pulses when ingress i's flit is forwarded (FIFO pop)
// =============================================================================
`timescale 1ns/1ps

module ucie_crossbar #(
    parameter integer N_PORTS    = 4,
    parameter integer FLIT_WIDTH = 256
)(
    input  wire                        clk,
    input  wire                        rst_n,

    // Ingress side — head-of-line flit per port
    input  wire [FLIT_WIDTH-1:0]       ing_flit    [N_PORTS],
    input  wire [N_PORTS-1:0]          ing_valid,          // ingress has data

    // Grant matrix from arbiter: grant[e][i] = ingress i wins to egress e
    input  wire [N_PORTS-1:0]          grant       [N_PORTS], // [egress][ingress]

    // Egress backpressure
    input  wire [N_PORTS-1:0]          egress_stall,       // egress FIFO full

    // Egress output (registered)
    output reg  [FLIT_WIDTH-1:0]       egr_flit    [N_PORTS],
    output reg  [N_PORTS-1:0]          egr_valid,

    // Inform ingress FIFOs which slots were consumed this cycle
    output reg  [N_PORTS-1:0]          ingress_consumed    // one-hot per ingress
);
    integer e, i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            egr_valid        <= {N_PORTS{1'b0}};
            ingress_consumed <= {N_PORTS{1'b0}};
            for (e = 0; e < N_PORTS; e = e + 1)
                egr_flit[e] <= {FLIT_WIDTH{1'b0}};
        end else begin
            // Default: clear consumed and valid
            ingress_consumed <= {N_PORTS{1'b0}};
            egr_valid        <= {N_PORTS{1'b0}};

            for (e = 0; e < N_PORTS; e = e + 1) begin
                egr_flit[e] <= {FLIT_WIDTH{1'b0}};

                if (!egress_stall[e]) begin
                    for (i = 0; i < N_PORTS; i = i + 1) begin
                        if (grant[e][i] && ing_valid[i]) begin
                            egr_flit[e]          <= ing_flit[i];
                            egr_valid[e]         <= 1'b1;
                            ingress_consumed[i]  <= 1'b1;
                        end
                    end
                end
            end
        end
    end

endmodule