`default_nettype none
`timescale 1ns/1ns

// MEMORY COALESCING UNIT
// > Sits between per-thread LSUs and the data memory controller
// > Each LSU maps 1:1 to a controller consumer slot by default
// > When multiple LSUs request the SAME address, only one request is
//   forwarded to the controller; the others are "shadowed" and get the
//   same response fanned out from the lead request
// > This is fully transparent: the controller still sees NUM_LSUS consumer
//   ports, but shadowed slots never assert valid, so channels are freed
module coalescer #(
    parameter ADDR_BITS = 8,
    parameter DATA_BITS = 8,
    parameter NUM_LSUS  = 8
) (
    // --- LSU side (upstream) ---
    input  wire [NUM_LSUS-1:0]       lsu_read_valid,
    input  wire [ADDR_BITS-1:0]      lsu_read_address  [NUM_LSUS-1:0],
    output reg  [NUM_LSUS-1:0]       lsu_read_ready,
    output reg  [DATA_BITS-1:0]      lsu_read_data     [NUM_LSUS-1:0],

    input  wire [NUM_LSUS-1:0]       lsu_write_valid,
    input  wire [ADDR_BITS-1:0]      lsu_write_address [NUM_LSUS-1:0],
    input  wire [DATA_BITS-1:0]      lsu_write_data    [NUM_LSUS-1:0],
    output reg  [NUM_LSUS-1:0]       lsu_write_ready,

    // --- Controller side (downstream, same width as LSU side) ---
    output reg  [NUM_LSUS-1:0]       ctrl_read_valid,
    output reg  [ADDR_BITS-1:0]      ctrl_read_address [NUM_LSUS-1:0],
    input  wire [NUM_LSUS-1:0]       ctrl_read_ready,
    input  wire [DATA_BITS-1:0]      ctrl_read_data    [NUM_LSUS-1:0],

    output reg  [NUM_LSUS-1:0]       ctrl_write_valid,
    output reg  [ADDR_BITS-1:0]      ctrl_write_address [NUM_LSUS-1:0],
    output reg  [DATA_BITS-1:0]      ctrl_write_data    [NUM_LSUS-1:0],
    input  wire [NUM_LSUS-1:0]       ctrl_write_ready
);

    integer i, k;

    // =========================================================================
    // Combinational: determine which LSUs are leads vs shadows THIS cycle
    // =========================================================================
    reg [NUM_LSUS-1:0]         c_read_shadowed;
    reg [$clog2(NUM_LSUS)-1:0] c_read_lead [NUM_LSUS-1:0];
    reg [NUM_LSUS-1:0]         c_write_shadowed;
    reg [$clog2(NUM_LSUS)-1:0] c_write_lead [NUM_LSUS-1:0];

    always @(*) begin
        for (i = 0; i < NUM_LSUS; i = i + 1) begin
            c_read_shadowed[i] = 0;
            c_read_lead[i] = i;
            c_write_shadowed[i] = 0;
            c_write_lead[i] = i;
        end

        for (i = 0; i < NUM_LSUS; i = i + 1) begin
            for (k = 0; k < i; k = k + 1) begin
                if (lsu_read_valid[i] && lsu_read_valid[k] &&
                    !c_read_shadowed[k] &&
                    lsu_read_address[i] == lsu_read_address[k]) begin
                    c_read_shadowed[i] = 1;
                    c_read_lead[i] = k;
                end
            end
        end

        for (i = 0; i < NUM_LSUS; i = i + 1) begin
            for (k = 0; k < i; k = k + 1) begin
                if (lsu_write_valid[i] && lsu_write_valid[k] &&
                    !c_write_shadowed[k] &&
                    lsu_write_address[i] == lsu_write_address[k]) begin
                    c_write_shadowed[i] = 1;
                    c_write_lead[i] = k;
                end
            end
        end
    end

    // =========================================================================
    // Combinational: forward/gate signals — zero-latency transparent mux
    // =========================================================================
    always @(*) begin
        for (i = 0; i < NUM_LSUS; i = i + 1) begin
            if (c_read_shadowed[i]) begin
                ctrl_read_valid[i]   = 0;
                ctrl_read_address[i] = {ADDR_BITS{1'b0}};
                lsu_read_ready[i]    = ctrl_read_ready[c_read_lead[i]];
                lsu_read_data[i]     = ctrl_read_data[c_read_lead[i]];
            end else begin
                ctrl_read_valid[i]   = lsu_read_valid[i];
                ctrl_read_address[i] = lsu_read_address[i];
                lsu_read_ready[i]    = ctrl_read_ready[i];
                lsu_read_data[i]     = ctrl_read_data[i];
            end

            if (c_write_shadowed[i]) begin
                ctrl_write_valid[i]   = 0;
                ctrl_write_address[i] = {ADDR_BITS{1'b0}};
                ctrl_write_data[i]    = {DATA_BITS{1'b0}};
                lsu_write_ready[i]    = ctrl_write_ready[c_write_lead[i]];
            end else begin
                ctrl_write_valid[i]   = lsu_write_valid[i];
                ctrl_write_address[i] = lsu_write_address[i];
                ctrl_write_data[i]    = lsu_write_data[i];
                lsu_write_ready[i]    = ctrl_write_ready[i];
            end
        end
    end
endmodule
