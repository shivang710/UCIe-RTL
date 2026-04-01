// =============================================================================
// Module: ucie_sync_fifo
// Description: Synthesizable synchronous FIFO with:
//   - Configurable depth (must be power of 2) and data width
//   - Full/empty/occupancy flags
//   - Head-peek output (pop_data valid without consuming entry)
//   - One-cycle push/pop latency
//   - Used for both ingress and egress FIFOs in the UCIe switch
// =============================================================================
`timescale 1ns/1ps

module ucie_sync_fifo #(
    parameter integer DATA_WIDTH = 256,
    parameter integer DEPTH      = 16   // must be power of 2
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // Push interface
    input  wire                   push_v,    // write request
    input  wire [DATA_WIDTH-1:0]  push_data,
    output wire                   push_r,    // ready (not full)

    // Pop interface
    input  wire                   pop_r,     // read request (consume head)
    output wire                   pop_v,     // head is valid (not empty)
    output wire [DATA_WIDTH-1:0]  pop_data,  // head data (peek without pop_r)

    // Status
    output wire                   full,
    output wire                   empty,
    output wire [$clog2(DEPTH):0] occupancy  // 0..DEPTH
);
    localparam PTR_W = $clog2(DEPTH);

    // Storage
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // Read/write pointers (one extra bit for full/empty disambiguation)
    reg [PTR_W:0] wr_ptr;
    reg [PTR_W:0] rd_ptr;

    wire do_push = push_v & push_r;
    wire do_pop  = pop_r  & pop_v;

    // Full/empty
    assign full      = (wr_ptr[PTR_W] != rd_ptr[PTR_W]) &&
                       (wr_ptr[PTR_W-1:0] == rd_ptr[PTR_W-1:0]);
    assign empty     = (wr_ptr == rd_ptr);
    assign occupancy = wr_ptr - rd_ptr;

    assign push_r  = ~full;
    assign pop_v   = ~empty;
    assign pop_data = mem[rd_ptr[PTR_W-1:0]];  // head peek

    // Write
    always @(posedge clk) begin
        if (do_push)
            mem[wr_ptr[PTR_W-1:0]] <= push_data;
    end

    // Pointer updates
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
        end else begin
            if (do_push) wr_ptr <= wr_ptr + 1'b1;
            if (do_pop)  rd_ptr <= rd_ptr + 1'b1;
        end
    end

endmodule