`default_nettype none
`timescale 1ns/1ns

// COALESCER (PHASE 1)
// > One instance per core
// > Merges multiple same-address READ requests from threads in that core
// > Forwards only one "leader" read to the existing memory controller
// > Fans returned data out to all matching threads
// > WRITE requests are passed through unchanged
// > Different read addresses are handled one group at a time

module coalescer #(
  parameter ADDR_BITS   = 8,
  parameter DATA_BITS   = 8,
  parameter NUM_THREADS = 4
) (
  input wire clk,
  input wire reset,

  // ----------------------------------------------------------------------
  // Upstream side: from LSUs in one core
  // ----------------------------------------------------------------------

  input  reg [NUM_THREADS-1:0] lsu_read_valid,
  input  reg [ADDR_BITS-1:0]   lsu_read_address [NUM_THREADS-1:0],
  output reg [NUM_THREADS-1:0] lsu_read_ready,
  output reg [DATA_BITS-1:0]   lsu_read_data [NUM_THREADS-1:0],

  input  reg [NUM_THREADS-1:0] lsu_write_valid,
  input  reg [ADDR_BITS-1:0]   lsu_write_address [NUM_THREADS-1:0],
  input  reg [DATA_BITS-1:0]   lsu_write_data [NUM_THREADS-1:0],
  output reg [NUM_THREADS-1:0] lsu_write_ready,

  // ----------------------------------------------------------------------
  // Downstream side: to existing global controller
  // Same shape as the existing per-thread data-memory LSU bundle
  // ----------------------------------------------------------------------

  output reg [NUM_THREADS-1:0] consumer_read_valid,
  output reg [ADDR_BITS-1:0]   consumer_read_address [NUM_THREADS-1:0],
  input  reg [NUM_THREADS-1:0] consumer_read_ready,
  input  reg [DATA_BITS-1:0]   consumer_read_data [NUM_THREADS-1:0],

  output reg [NUM_THREADS-1:0] consumer_write_valid,
  output reg [ADDR_BITS-1:0]   consumer_write_address [NUM_THREADS-1:0],
  output reg [DATA_BITS-1:0]   consumer_write_data [NUM_THREADS-1:0],
  input  reg [NUM_THREADS-1:0] consumer_write_ready
);

  localparam IDLE       = 2'b00;
  localparam READ_WAIT  = 2'b01;
  localparam READ_RELAY = 2'b10;

  reg [1:0] state;

  reg [$clog2(NUM_THREADS)-1:0] leader_idx;
  reg [NUM_THREADS-1:0]         group_mask;
  reg [ADDR_BITS-1:0]           group_address;
  reg [DATA_BITS-1:0]           group_data;

  // ----------------------------------------------------------------------
  // Combinational helpers to find the next read group
  // ----------------------------------------------------------------------

  reg                            found_group;
  reg [$clog2(NUM_THREADS)-1:0]  found_leader_idx;
  reg [NUM_THREADS-1:0]          found_group_mask;
  reg [ADDR_BITS-1:0]            found_group_address;

  // We also track pending read requests in registers so that we can hold onto them
  // while we're waiting for the global read to return. 
  reg [NUM_THREADS-1:0]       pending_read_valid;
  reg [ADDR_BITS-1:0]         pending_read_address [NUM_THREADS-1:0];

  reg [NUM_THREADS-1:0]       next_group_mask_after_clear;
  reg                         pending_reads_exist;
  reg                         pending_reads_remain_after_clear;

  reg all_group_released;

  integer i;
  integer j;
  integer k;

  always @(*) begin
    found_group         = 0;
    found_leader_idx    = 0;
    found_group_mask    = 0;
    found_group_address = 0;
    pending_reads_exist = 1'b0;

    for (i = 0; i < NUM_THREADS; i = i + 1) begin
      if (pending_read_valid[i]) begin
        pending_reads_exist = 1'b1;
      end
    end

    for (i = 0; i < NUM_THREADS; i = i + 1) begin
      if (!found_group && pending_read_valid[i]) begin
        found_group         = 1'b1;
        found_leader_idx    = i[$clog2(NUM_THREADS)-1:0];
        found_group_address = pending_read_address[i];

        for (j = 0; j < NUM_THREADS; j = j + 1) begin
          if (pending_read_valid[j] &&
              (pending_read_address[j] == pending_read_address[i])) begin
            found_group_mask[j] = 1'b1;
          end
        end
      end
    end
  end

  always @(*) begin
    next_group_mask_after_clear       = pending_read_valid & ~group_mask;
    pending_reads_remain_after_clear  = |next_group_mask_after_clear;
    all_group_released = 1'b1;

    for (i = 0; i < NUM_THREADS; i = i + 1) begin
      if (group_mask[i] && lsu_read_valid[i]) begin
        all_group_released = 1'b0;
      end
    end
  end

  // ----------------------------------------------------------------------
  // Output behavior
  // ----------------------------------------------------------------------

  always @(*) begin
    // Defaults
    lsu_read_ready     = 0;
    consumer_read_valid = 0;

    for (i = 0; i < NUM_THREADS; i = i + 1) begin
      lsu_read_data[i]         = 0;
      consumer_read_address[i] = 0;

      // Phase 1: writes are not coalesced; just pass them through
      consumer_write_valid[i]   = lsu_write_valid[i];
      consumer_write_address[i] = lsu_write_address[i];
      consumer_write_data[i]    = lsu_write_data[i];
      lsu_write_ready[i]        = consumer_write_ready[i];
    end

    case (state)
      READ_WAIT: begin
        // Only the leader thread actually goes to the global controller
        consumer_read_valid[leader_idx]   = 1'b1;
        consumer_read_address[leader_idx] = group_address;
      end

      READ_RELAY: begin
        // Fan returned data out to every thread in the same-address group
        for (i = 0; i < NUM_THREADS; i = i + 1) begin
          if (group_mask[i]) begin
            lsu_read_ready[i] = 1'b1;
            lsu_read_data[i]  = group_data;
          end
        end
      end

      default: begin
        // nothing extra
      end
    endcase
  end

  // ----------------------------------------------------------------------
  // State machine
  // ----------------------------------------------------------------------

  always @(posedge clk) begin
    if (reset) begin
      state         <= IDLE;
      leader_idx    <= 0;
      group_mask    <= 0;
      group_address <= 0;
      group_data    <= 0;
      pending_read_valid <= 0;

      for (k = 0; k < NUM_THREADS; k = k + 1) begin
        pending_read_address[k] <= 0;
      end
    end else begin
      case (state)

        IDLE: begin 
          for (k = 0; k < NUM_THREADS; k = k + 1) begin
            if (!pending_read_valid[k] && lsu_read_valid[k]) begin
              pending_read_valid[k]   <= 1'b1;
              pending_read_address[k] <= lsu_read_address[k];
            end
          end
          
          if (found_group) begin
            leader_idx    <= found_leader_idx;
            group_mask    <= found_group_mask;
            group_address <= found_group_address;
            state         <= READ_WAIT;
          end
        end

        READ_WAIT: begin
          // Wait for the single forwarded external read to complete
          if (consumer_read_ready[leader_idx]) begin
            group_data <= consumer_read_data[leader_idx];
            state      <= READ_RELAY;
          end
        end

        READ_RELAY: begin
          // Hold read_ready/data to the grouped LSUs until all of them
          // drop their valid request lines
          // if (all_group_released) begin
          //   group_mask    <= 0;
          //   group_address <= 0;
          //   group_data    <= 0;
          //   state         <= IDLE;
          if (all_group_released) begin
            for (k = 0; k < NUM_THREADS; k = k + 1) begin
              if (group_mask[k]) begin
                pending_read_valid[k] <= 1'b0;
              end
            end

            if (pending_reads_remain_after_clear) begin
              // stay in the coalescer and immediately work on the next address group
              // selection logic will pick the next leader/group from pending_read_valid
              state <= IDLE;
            end else begin
              state <= IDLE;
            end

            group_mask    <= '0;
            group_address <= '0;
            group_data    <= '0;
          end
        end

        default: begin
          state <= IDLE;
        end
      endcase
    end
  end

endmodule