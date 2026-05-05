`default_nettype none
`timescale 1ns/1ns

// COMPUTE CORE (with Warp Interleaving)
// > Handles processing 1 block at a time with warp-level pipeline interleaving
// > Threads are split into NUM_WARPS warps; when one warp stalls on memory,
//   the scheduler switches to another warp to hide latency
// > Each core contains 1 fetcher & decoder (shared), and register files, ALUs, LSUs, PC per thread
module core #(
    parameter DATA_MEM_ADDR_BITS = 8,
    parameter DATA_MEM_DATA_BITS = 8,
    parameter PROGRAM_MEM_ADDR_BITS = 8,
    parameter PROGRAM_MEM_DATA_BITS = 16,
    parameter THREADS_PER_BLOCK = 32,
    parameter NUM_WARPS = 2,
    parameter THREADS_PER_WARP = THREADS_PER_BLOCK / NUM_WARPS
) (
    input wire clk,
    input wire reset,

    // Kernel Execution
    input wire start,
    output wire done,

    // Block Metadata
    input wire [7:0] block_id,
    input wire [$clog2(THREADS_PER_BLOCK):0] thread_count,

    // Program Memory
    output reg program_mem_read_valid,
    output reg [PROGRAM_MEM_ADDR_BITS-1:0] program_mem_read_address,
    input reg program_mem_read_ready,
    input reg [PROGRAM_MEM_DATA_BITS-1:0] program_mem_read_data,

    // Data Memory
    output reg [THREADS_PER_BLOCK-1:0] data_mem_read_valid,
    output reg [DATA_MEM_ADDR_BITS-1:0] data_mem_read_address [THREADS_PER_BLOCK-1:0],
    input reg [THREADS_PER_BLOCK-1:0] data_mem_read_ready,
    input reg [DATA_MEM_DATA_BITS-1:0] data_mem_read_data [THREADS_PER_BLOCK-1:0],
    output reg [THREADS_PER_BLOCK-1:0] data_mem_write_valid,
    output reg [DATA_MEM_ADDR_BITS-1:0] data_mem_write_address [THREADS_PER_BLOCK-1:0],
    output reg [DATA_MEM_DATA_BITS-1:0] data_mem_write_data [THREADS_PER_BLOCK-1:0],
    input reg [THREADS_PER_BLOCK-1:0] data_mem_write_ready
);
    // Scheduler outputs
    reg [2:0] core_state;
    reg [2:0] warp_state [NUM_WARPS-1:0];
    reg [7:0] warp_pc [NUM_WARPS-1:0];
    reg [$clog2(NUM_WARPS)-1:0] active_warp;
    reg [7:0] current_pc;

    // Fetcher/Decoder shared state
    reg [2:0] fetcher_state;
    reg [15:0] instruction;

    // Decoder direct outputs (valid 1 cycle after DECODE, i.e. during REQUEST of active warp)
    reg [3:0] decoded_rd_address;
    reg [3:0] decoded_rs_address;
    reg [3:0] decoded_rt_address;
    reg [2:0] decoded_nzp;
    reg [7:0] decoded_immediate;
    reg decoded_reg_write_enable;
    reg decoded_mem_read_enable;
    reg decoded_mem_write_enable;
    reg decoded_nzp_write_enable;
    reg [1:0] decoded_reg_input_mux;
    reg [1:0] decoded_alu_arithmetic_mux;
    reg decoded_alu_output_mux;
    reg decoded_pc_mux;
    reg decoded_ret;

    // Per-warp stored decoded signals (latched when active warp reaches REQUEST)
    reg [3:0] warp_decoded_rd_address [NUM_WARPS-1:0];
    reg [3:0] warp_decoded_rs_address [NUM_WARPS-1:0];
    reg [3:0] warp_decoded_rt_address [NUM_WARPS-1:0];
    reg [2:0] warp_decoded_nzp [NUM_WARPS-1:0];
    reg [7:0] warp_decoded_immediate [NUM_WARPS-1:0];
    reg [NUM_WARPS-1:0] warp_decoded_reg_write_enable;
    reg [NUM_WARPS-1:0] warp_decoded_mem_read_enable;
    reg [NUM_WARPS-1:0] warp_decoded_mem_write_enable;
    reg [NUM_WARPS-1:0] warp_decoded_nzp_write_enable;
    reg [1:0] warp_decoded_reg_input_mux [NUM_WARPS-1:0];
    reg [1:0] warp_decoded_alu_arithmetic_mux [NUM_WARPS-1:0];
    reg [NUM_WARPS-1:0] warp_decoded_alu_output_mux;
    reg [NUM_WARPS-1:0] warp_decoded_pc_mux;
    reg [NUM_WARPS-1:0] warp_decoded_ret;

    // Per-thread intermediate signals
    wire [7:0] next_pc [THREADS_PER_BLOCK-1:0];
    reg [7:0] rs [THREADS_PER_BLOCK-1:0];
    reg [7:0] rt [THREADS_PER_BLOCK-1:0];
    reg [1:0] lsu_state [THREADS_PER_BLOCK-1:0];
    reg [7:0] lsu_out [THREADS_PER_BLOCK-1:0];
    wire [7:0] alu_out [THREADS_PER_BLOCK-1:0];

    // Per-warp next PC (from each warp's last thread)
    reg [7:0] warp_next_pc [NUM_WARPS-1:0];
    genvar wp;
    generate
        for (wp = 0; wp < NUM_WARPS; wp = wp + 1) begin : warp_pc_gen
            assign warp_next_pc[wp] = next_pc[(wp + 1) * THREADS_PER_WARP - 1];
        end
    endgenerate

    // Latch decoded signals into active warp's storage when active warp is in REQUEST
    // (decoder outputs become valid 1 cycle after DECODE, which is the REQUEST cycle)
    integer w_idx;
    always @(posedge clk) begin
        if (reset) begin
            for (w_idx = 0; w_idx < NUM_WARPS; w_idx = w_idx + 1) begin
                warp_decoded_rd_address[w_idx] <= 0;
                warp_decoded_rs_address[w_idx] <= 0;
                warp_decoded_rt_address[w_idx] <= 0;
                warp_decoded_nzp[w_idx] <= 0;
                warp_decoded_immediate[w_idx] <= 0;
                warp_decoded_reg_write_enable[w_idx] <= 0;
                warp_decoded_mem_read_enable[w_idx] <= 0;
                warp_decoded_mem_write_enable[w_idx] <= 0;
                warp_decoded_nzp_write_enable[w_idx] <= 0;
                warp_decoded_reg_input_mux[w_idx] <= 0;
                warp_decoded_alu_arithmetic_mux[w_idx] <= 0;
                warp_decoded_alu_output_mux[w_idx] <= 0;
                warp_decoded_pc_mux[w_idx] <= 0;
                warp_decoded_ret[w_idx] <= 0;
            end
        end else begin
            // Latch on REQUEST cycle: decoder outputs are valid, active_warp is still correct
            if (core_state == 3'b011) begin
                warp_decoded_rd_address[active_warp] <= decoded_rd_address;
                warp_decoded_rs_address[active_warp] <= decoded_rs_address;
                warp_decoded_rt_address[active_warp] <= decoded_rt_address;
                warp_decoded_nzp[active_warp] <= decoded_nzp;
                warp_decoded_immediate[active_warp] <= decoded_immediate;
                warp_decoded_reg_write_enable[active_warp] <= decoded_reg_write_enable;
                warp_decoded_mem_read_enable[active_warp] <= decoded_mem_read_enable;
                warp_decoded_mem_write_enable[active_warp] <= decoded_mem_write_enable;
                warp_decoded_nzp_write_enable[active_warp] <= decoded_nzp_write_enable;
                warp_decoded_reg_input_mux[active_warp] <= decoded_reg_input_mux;
                warp_decoded_alu_arithmetic_mux[active_warp] <= decoded_alu_arithmetic_mux;
                warp_decoded_alu_output_mux[active_warp] <= decoded_alu_output_mux;
                warp_decoded_pc_mux[active_warp] <= decoded_pc_mux;
                warp_decoded_ret[active_warp] <= decoded_ret;
            end
        end
    end

    // Fetcher (shared, driven by active warp's state and PC)
    fetcher #(
        .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS)
    ) fetcher_instance (
        .clk(clk),
        .reset(reset),
        .core_state(core_state),
        .current_pc(current_pc),
        .mem_read_valid(program_mem_read_valid),
        .mem_read_address(program_mem_read_address),
        .mem_read_ready(program_mem_read_ready),
        .mem_read_data(program_mem_read_data),
        .fetcher_state(fetcher_state),
        .instruction(instruction)
    );

    // Decoder (shared, driven by active warp's state)
    decoder decoder_instance (
        .clk(clk),
        .reset(reset),
        .core_state(core_state),
        .instruction(instruction),
        .decoded_rd_address(decoded_rd_address),
        .decoded_rs_address(decoded_rs_address),
        .decoded_rt_address(decoded_rt_address),
        .decoded_nzp(decoded_nzp),
        .decoded_immediate(decoded_immediate),
        .decoded_reg_write_enable(decoded_reg_write_enable),
        .decoded_mem_read_enable(decoded_mem_read_enable),
        .decoded_mem_write_enable(decoded_mem_write_enable),
        .decoded_nzp_write_enable(decoded_nzp_write_enable),
        .decoded_reg_input_mux(decoded_reg_input_mux),
        .decoded_alu_arithmetic_mux(decoded_alu_arithmetic_mux),
        .decoded_alu_output_mux(decoded_alu_output_mux),
        .decoded_pc_mux(decoded_pc_mux),
        .decoded_ret(decoded_ret)
    );

    // Scheduler (warp-interleaving)
    scheduler #(
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK),
        .NUM_WARPS(NUM_WARPS),
        .THREADS_PER_WARP(THREADS_PER_WARP)
    ) scheduler_instance (
        .clk(clk),
        .reset(reset),
        .start(start),
        .warp_decoded_ret(warp_decoded_ret),
        .fetcher_state(fetcher_state),
        .lsu_state(lsu_state),
        .warp_next_pc(warp_next_pc),
        .current_pc(current_pc),
        .core_state(core_state),
        .warp_state(warp_state),
        .warp_pc(warp_pc),
        .active_warp(active_warp),
        .done(done)
    );

    // Per-thread hardware: each thread sees its own warp's state and decoded signals.
    // Mux: if thread's warp IS active, use decoder direct outputs (they're valid for that warp).
    //       if thread's warp is NOT active, use stored warp_decoded_* signals.
    genvar i;
    generate
        for (i = 0; i < THREADS_PER_BLOCK; i = i + 1) begin : threads
            localparam WARP_ID = i / THREADS_PER_WARP;

            wire [2:0] thread_state = warp_state[WARP_ID];
            wire thread_is_active = (WARP_ID[$clog2(NUM_WARPS)-1:0] == active_warp);

            // Muxed decoded signals: direct decoder output when active, stored otherwise
            wire [3:0] thread_decoded_rd_address = thread_is_active ?
                decoded_rd_address : warp_decoded_rd_address[WARP_ID];
            wire [3:0] thread_decoded_rs_address = thread_is_active ?
                decoded_rs_address : warp_decoded_rs_address[WARP_ID];
            wire [3:0] thread_decoded_rt_address = thread_is_active ?
                decoded_rt_address : warp_decoded_rt_address[WARP_ID];
            wire [2:0] thread_decoded_nzp = thread_is_active ?
                decoded_nzp : warp_decoded_nzp[WARP_ID];
            wire [7:0] thread_decoded_immediate = thread_is_active ?
                decoded_immediate : warp_decoded_immediate[WARP_ID];
            wire thread_decoded_reg_write_enable = thread_is_active ?
                decoded_reg_write_enable : warp_decoded_reg_write_enable[WARP_ID];
            wire thread_decoded_mem_read_enable = thread_is_active ?
                decoded_mem_read_enable : warp_decoded_mem_read_enable[WARP_ID];
            wire thread_decoded_mem_write_enable = thread_is_active ?
                decoded_mem_write_enable : warp_decoded_mem_write_enable[WARP_ID];
            wire thread_decoded_nzp_write_enable = thread_is_active ?
                decoded_nzp_write_enable : warp_decoded_nzp_write_enable[WARP_ID];
            wire [1:0] thread_decoded_reg_input_mux = thread_is_active ?
                decoded_reg_input_mux : warp_decoded_reg_input_mux[WARP_ID];
            wire [1:0] thread_decoded_alu_arithmetic_mux = thread_is_active ?
                decoded_alu_arithmetic_mux : warp_decoded_alu_arithmetic_mux[WARP_ID];
            wire thread_decoded_alu_output_mux = thread_is_active ?
                decoded_alu_output_mux : warp_decoded_alu_output_mux[WARP_ID];
            wire thread_decoded_pc_mux = thread_is_active ?
                decoded_pc_mux : warp_decoded_pc_mux[WARP_ID];

            // Per-warp PC for this thread's PC module
            wire [7:0] thread_current_pc = warp_pc[WARP_ID];

            // ALU
            alu alu_instance (
                .clk(clk),
                .reset(reset),
                .enable(i < thread_count),
                .core_state(thread_state),
                .decoded_alu_arithmetic_mux(thread_decoded_alu_arithmetic_mux),
                .decoded_alu_output_mux(thread_decoded_alu_output_mux),
                .rs(rs[i]),
                .rt(rt[i]),
                .alu_out(alu_out[i])
            );

            // LSU
            lsu lsu_instance (
                .clk(clk),
                .reset(reset),
                .enable(i < thread_count),
                .core_state(thread_state),
                .decoded_mem_read_enable(thread_decoded_mem_read_enable),
                .decoded_mem_write_enable(thread_decoded_mem_write_enable),
                .mem_read_valid(data_mem_read_valid[i]),
                .mem_read_address(data_mem_read_address[i]),
                .mem_read_ready(data_mem_read_ready[i]),
                .mem_read_data(data_mem_read_data[i]),
                .mem_write_valid(data_mem_write_valid[i]),
                .mem_write_address(data_mem_write_address[i]),
                .mem_write_data(data_mem_write_data[i]),
                .mem_write_ready(data_mem_write_ready[i]),
                .rs(rs[i]),
                .rt(rt[i]),
                .lsu_state(lsu_state[i]),
                .lsu_out(lsu_out[i])
            );

            // Register File
            registers #(
                .THREADS_PER_BLOCK(THREADS_PER_BLOCK),
                .THREAD_ID(i),
                .DATA_BITS(DATA_MEM_DATA_BITS)
            ) register_instance (
                .clk(clk),
                .reset(reset),
                .enable(i < thread_count),
                .block_id(block_id),
                .core_state(thread_state),
                .decoded_reg_write_enable(thread_decoded_reg_write_enable),
                .decoded_reg_input_mux(thread_decoded_reg_input_mux),
                .decoded_rd_address(thread_decoded_rd_address),
                .decoded_rs_address(thread_decoded_rs_address),
                .decoded_rt_address(thread_decoded_rt_address),
                .decoded_immediate(thread_decoded_immediate),
                .alu_out(alu_out[i]),
                .lsu_out(lsu_out[i]),
                .rs(rs[i]),
                .rt(rt[i])
            );

            // Program Counter
            pc #(
                .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
                .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS)
            ) pc_instance (
                .clk(clk),
                .reset(reset),
                .enable(i < thread_count),
                .core_state(thread_state),
                .decoded_nzp(thread_decoded_nzp),
                .decoded_immediate(thread_decoded_immediate),
                .decoded_nzp_write_enable(thread_decoded_nzp_write_enable),
                .decoded_pc_mux(thread_decoded_pc_mux),
                .alu_out(alu_out[i]),
                .current_pc(thread_current_pc),
                .next_pc(next_pc[i])
            );
        end
    endgenerate
endmodule
