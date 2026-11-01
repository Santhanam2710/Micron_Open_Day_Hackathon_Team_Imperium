// ============================================================================
//  dram_model.sv -- SIMULATION-ONLY main memory model
// ----------------------------------------------------------------------------
//  Not part of the synthesised design.  Quartus builds synth_top.sv, which
//  brings this port out to pins where a real SDRAM/HBM controller would sit.
//  The model exists so that simulation can charge a realistic cost for going
//  off-chip and can self-check the cache's data.
//
//  WHY IT IS PIPELINED, AND WHY THAT MATTERS
//  The first version of this file allowed exactly one transaction in flight.
//  That single assumption invalidated the whole experiment: prefetch
//  throughput was capped at one line per LATENCY cycles, so a prefetcher that
//  predicted perfectly still could not run far enough ahead to hide anything,
//  and the measured speedup was zero.  Real DRAM does not behave that way.
//  Latency is high, but many requests are in flight at once across banks, and
//  the thing that is actually scarce is BANDWIDTH.
//
//  So this model has three separate properties, and each one constrains the
//  design in a different and necessary way:
//
//    LATENCY          -- cycles from acceptance to data.  This is what a
//                        prefetcher exists to hide, and hiding it requires
//                        running far enough ahead.
//    MAX_OUTSTANDING  -- how many requests may be in flight.  This is what
//                        lets a prefetcher run ahead at all, and it is why
//                        the cache needs an MSHR file rather than one slot.
//    BURST_CYCLES     -- minimum cycles between two data returns, i.e. the
//                        bus occupancy of one cache line.  This is the one
//                        that makes speculation cost something.  Without a
//                        bandwidth ceiling an incorrect prefetch is free, and
//                        no throttling mechanism could ever be shown to help.
//
//  Requests carry an ID and responses echo it, so the cache can have a demand
//  miss and several prefetches outstanding at once and still tell them apart.
//  Completion is in order, which is a simplification -- a real controller
//  reorders for row locality -- but in-order completion only ever makes the
//  design's job harder, so no result here is flattered by it.
//
//  SELF-CHECKING
//  A line that has never been written reads back a deterministic pattern:
//  every 32-bit word in the address space holds its own word index, so the
//  testbench can predict any read with no bookkeeping.  Written lines are held
//  in a backing array, so a dirty eviction followed by a re-read returns the
//  written data -- which is what actually exercises the write-back path.
// ============================================================================
`default_nettype none

module dram_model #(
  parameter int ADDR_W          = 32,
  parameter int LINE_BYTES      = 64,
  parameter int ID_W            = 4,
  parameter int LATENCY         = 100,   // acceptance -> data
  parameter int MAX_OUTSTANDING = 16,    // bank-level parallelism
  parameter int BURST_CYCLES    = 4,     // bus occupancy of one line
  parameter int MEM_LINES       = 65536  // 4 MiB of addressable footprint
)(
  input  wire                     clk,
  input  wire                     rst_n,

  // ---- Request
  input  wire                     req,
  input  wire                     req_we,
  input  wire  [ID_W-1:0]         req_id,
  input  wire  [ADDR_W-1:0]       req_addr,
  input  wire  [LINE_BYTES*8-1:0] req_wdata,
  output logic                    gnt,

  // ---- Response
  output logic                    resp_vld,
  output logic [ID_W-1:0]         resp_id,
  output logic                    resp_is_write,
  output logic [LINE_BYTES*8-1:0] resp_data,

  // ---- Statistics
  output logic [31:0]             n_reads,
  output logic [31:0]             n_writes,
  output logic [31:0]             n_bus_cycles,  // cycles the data bus was busy
  output logic [31:0]             n_stall_cycles // cycles a request was refused
);

  localparam int LINE_W    = LINE_BYTES * 8;
  localparam int WORDS     = LINE_W / 32;
  localparam int LOG2_LINE = $clog2(LINE_BYTES);
  localparam int MIDX_W    = $clog2(MEM_LINES);
  localparam int QD        = MAX_OUTSTANDING;
  localparam int QP_W      = $clog2(QD);

  // -------------------------------------------------------------------------
  //  Backing store, only for lines that have actually been written
  // -------------------------------------------------------------------------
  logic [LINE_W-1:0] store [MEM_LINES];
  logic              wrote [MEM_LINES];

  // A non-blocking assignment to a 65 k-entry array inside a loop is not
  // synthesisable and simulators refuse to unroll it.  This file is a
  // simulation model, so a time-zero initialisation is legal and sufficient.
  initial begin
    for (int i = 0; i < MEM_LINES; i++) wrote[i] = 1'b0;
  end

  function automatic [LINE_W-1:0] pattern (input logic [ADDR_W-1:0] line_addr);
    logic [LINE_W-1:0] v;
    begin
      v = '0;
      for (int w = 0; w < WORDS; w++)
        v[w*32 +: 32] = (line_addr + ADDR_W'(w*4)) >> 2;
      pattern = v;
    end
  endfunction

  // -------------------------------------------------------------------------
  //  In-flight request queue (in-order completion)
  // -------------------------------------------------------------------------
  logic [ID_W-1:0]   q_id   [QD];
  logic              q_we   [QD];
  logic [MIDX_W-1:0] q_idx  [QD];
  logic [ADDR_W-1:0] q_addr [QD];
  logic [31:0]       q_due  [QD];

  logic [QP_W-1:0] head, tail;
  logic [QP_W:0]   cnt;
  logic [31:0]     now, last_resp_at;

  logic q_full, bus_free, head_due, do_resp;

  assign q_full   = (cnt == (QP_W+1)'(QD));
  assign gnt      = req && !q_full;
  // Honour the data-bus occupancy of the previous return.
  assign bus_free = (now - last_resp_at) >= 32'(BURST_CYCLES);
  assign head_due = (cnt != 0) && (now >= q_due[head]);
  assign do_resp  = head_due && bus_free;

  logic [MIDX_W-1:0] acc_idx;
  assign acc_idx = req_addr[LOG2_LINE+MIDX_W-1 : LOG2_LINE];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      head           <= '0;
      tail           <= '0;
      cnt            <= '0;
      now            <= '0;
      last_resp_at   <= '0;
      resp_vld       <= 1'b0;
      resp_id        <= '0;
      resp_is_write  <= 1'b0;
      resp_data      <= '0;
      n_reads        <= '0;
      n_writes       <= '0;
      n_bus_cycles   <= '0;
      n_stall_cycles <= '0;
    end else begin
      now      <= now + 1'b1;
      resp_vld <= 1'b0;

      if (req && q_full) n_stall_cycles <= n_stall_cycles + 1'b1;

      // ---- Accept ---------------------------------------------------------
      if (gnt) begin
        q_id  [tail] <= req_id;
        q_we  [tail] <= req_we;
        q_idx [tail] <= acc_idx;
        q_addr[tail] <= {req_addr[ADDR_W-1:LOG2_LINE], {LOG2_LINE{1'b0}}};
        q_due [tail] <= now + 32'(LATENCY);
        tail         <= tail + 1'b1;
        if (req_we) begin
          n_writes      <= n_writes + 1'b1;
          store[acc_idx] <= req_wdata;
          wrote[acc_idx] <= 1'b1;
        end else begin
          n_reads <= n_reads + 1'b1;
        end
      end

      // ---- Complete -------------------------------------------------------
      if (do_resp) begin
        resp_vld      <= 1'b1;
        resp_id       <= q_id[head];
        resp_is_write <= q_we[head];
        resp_data     <= wrote[q_idx[head]] ? store[q_idx[head]]
                                            : pattern(q_addr[head]);
        head          <= head + 1'b1;
        last_resp_at  <= now;
        n_bus_cycles  <= n_bus_cycles + 32'(BURST_CYCLES);
      end

      // ---- Occupancy ------------------------------------------------------
      if (gnt && !do_resp)      cnt <= cnt + 1'b1;
      else if (do_resp && !gnt) cnt <= cnt - 1'b1;
    end
  end

endmodule

`default_nettype wire
