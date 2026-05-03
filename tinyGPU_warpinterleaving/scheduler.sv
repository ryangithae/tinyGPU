`default_nettype none
`timescale 1ns/1ns

// WARP-INTERLEAVING SCHEDULER
// > Manages per-warp pipeline state machines within a single compute core
// > When one warp stalls on memory (WAIT), switches to another ready warp
// > Hides memory latency by overlapping computation with memory access
// > The fetcher/decoder are shared resources: only the active warp uses them
module scheduler #(
    parameter THREADS_PER_BLOCK = 4,
    parameter NUM_WARPS = 2,
    parameter THREADS_PER_WARP = THREADS_PER_BLOCK / NUM_WARPS
) (
    input wire clk,
    input wire reset,
    input wire start,

    // Per-warp decoded ret (from core's per-warp storage)
    input reg [NUM_WARPS-1:0] warp_decoded_ret,

    // Fetcher state
    input reg [2:0] fetcher_state,

    // Per-thread LSU state
    input reg [1:0] lsu_state [THREADS_PER_BLOCK-1:0],

    // Per-warp next PC (from each warp's last thread)
    input reg [7:0] warp_next_pc [NUM_WARPS-1:0],

    // Outputs
    output reg [7:0] current_pc,
    output reg [2:0] core_state,
    output reg [2:0] warp_state [NUM_WARPS-1:0],
    output reg [7:0] warp_pc [NUM_WARPS-1:0],
    output reg [$clog2(NUM_WARPS)-1:0] active_warp,
    output reg done
);
    localparam IDLE = 3'b000,
        FETCH = 3'b001,
        DECODE = 3'b010,
        REQUEST = 3'b011,
        WAIT = 3'b100,
        EXECUTE = 3'b101,
        UPDATE = 3'b110,
        DONE = 3'b111;

    // Determine if a warp's LSUs are all done (not in REQUESTING or WAITING)
    reg [NUM_WARPS-1:0] warp_lsus_done;
    integer t;
    always @(*) begin
        for (int w = 0; w < NUM_WARPS; w = w + 1) begin
            warp_lsus_done[w] = 1'b1;
            for (t = w * THREADS_PER_WARP; t < (w + 1) * THREADS_PER_WARP; t = t + 1) begin
                if (lsu_state[t] == 2'b01 || lsu_state[t] == 2'b10) begin
                    warp_lsus_done[w] = 1'b0;
                end
            end
        end
    end

    // Warp switching: can switch when fetcher is idle and active warp doesn't need it
    wire can_switch = (fetcher_state == 3'b000) &&
                      (warp_state[active_warp] != FETCH) &&
                      (warp_state[active_warp] != DECODE);
    wire [$clog2(NUM_WARPS)-1:0] other_warp = ~active_warp;
    wire want_switch = (warp_state[other_warp] == FETCH);
    wire do_switch = can_switch && want_switch;

    // Drive core_state for fetcher/decoder (active warp's state)
    always @(*) begin
        core_state = warp_state[active_warp];
        current_pc = warp_pc[active_warp];
    end

    integer w;
    always @(posedge clk) begin
        if (reset) begin
            for (w = 0; w < NUM_WARPS; w = w + 1) begin
                warp_state[w] <= IDLE;
                warp_pc[w] <= 0;
            end
            active_warp <= 0;
            done <= 0;
        end else begin
            // Per-warp state machines
            for (w = 0; w < NUM_WARPS; w = w + 1) begin
                case (warp_state[w])
                    IDLE: begin
                        if (start) begin
                            warp_state[w] <= FETCH;
                        end
                    end
                    FETCH: begin
                        // Only advance if this warp is active and fetcher completed
                        if (w[$clog2(NUM_WARPS)-1:0] == active_warp && fetcher_state == 3'b010) begin
                            warp_state[w] <= DECODE;
                        end
                    end
                    DECODE: begin
                        // Only advance if this warp is active (decoder needs 1 cycle)
                        if (w[$clog2(NUM_WARPS)-1:0] == active_warp) begin
                            warp_state[w] <= REQUEST;
                        end
                    end
                    REQUEST: begin
                        warp_state[w] <= WAIT;
                    end
                    WAIT: begin
                        if (warp_lsus_done[w]) begin
                            warp_state[w] <= EXECUTE;
                        end
                    end
                    EXECUTE: begin
                        warp_state[w] <= UPDATE;
                    end
                    UPDATE: begin
                        if (warp_decoded_ret[w]) begin
                            warp_state[w] <= DONE;
                        end else begin
                            warp_pc[w] <= warp_next_pc[w];
                            warp_state[w] <= FETCH;
                        end
                    end
                    DONE: begin
                        // Terminal
                    end
                endcase
            end

            // Active warp switching
            if (do_switch) begin
                active_warp <= other_warp;
            end

            // Block is done when all warps are done
            done <= (warp_state[0] == DONE) && (warp_state[1] == DONE);
        end
    end
endmodule

