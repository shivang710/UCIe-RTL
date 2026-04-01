// =============================================================================
// Module: ucie_arbiter_rr
// Description: Synthesizable round-robin arbiter.
//   - N_ENTRIES requesters compete for one grant per cycle
//   - True round-robin: priority rotates past last winner each cycle
//   - Grant is one-hot; no grant when no requests
//   - grant_valid asserted when any grant is issued
//   - Uses classic "double-the-width" mask technique (no loops needed)
// =============================================================================
`timescale 1ns/1ps

module ucie_arbiter_rr #(
    parameter integer N_ENTRIES = 4
)(
    input  wire                   clk,
    input  wire                   rst_n,

    input  wire [N_ENTRIES-1:0]   req,          // request vector (combinational)
    output reg  [N_ENTRIES-1:0]   grant,        // one-hot grant
    output reg                    grant_valid,  // at least one grant issued

    // Pulse this when the granted transaction completes (advances round-robin)
    input  wire                   grant_done
);
    // Priority pointer: one-hot, points to the entry AFTER last winner
    reg [N_ENTRIES-1:0] priority_oh;

    // Double-width mask trick:
    //   masked_req = req & ~(priority_oh - 1)  — requests at or after priority
    //   If masked_req != 0, grant lowest set bit of masked_req
    //   Else grant lowest set bit of req (wrap-around)
    wire [N_ENTRIES-1:0]   mask;
    wire [N_ENTRIES-1:0]   masked_req;
    wire [N_ENTRIES-1:0]   grant_masked;
    wire [N_ENTRIES-1:0]   grant_wrap;
    wire [N_ENTRIES-1:0]   grant_next;

    // mask: all bits from priority position onward
    assign mask        = ~(priority_oh - 1'b1);
    assign masked_req  = req & mask;

    // Lowest-set-bit extraction (synthesizable)
    assign grant_masked = masked_req & (~masked_req + 1'b1);
    assign grant_wrap   = req        & (~req        + 1'b1);
    assign grant_next   = (|masked_req) ? grant_masked : grant_wrap;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grant         <= {N_ENTRIES{1'b0}};
            grant_valid   <= 1'b0;
            priority_oh   <= {{(N_ENTRIES-1){1'b0}}, 1'b1}; // start at entry 0
        end else begin
            grant_valid <= |req;
            grant       <= (|req) ? grant_next : {N_ENTRIES{1'b0}};

            // Advance priority past winner when transaction completes
            if (grant_done && grant_valid) begin
                // Rotate priority one past the current winner
                priority_oh <= {grant[N_ENTRIES-2:0], grant[N_ENTRIES-1]};
            end
        end
    end

endmodule