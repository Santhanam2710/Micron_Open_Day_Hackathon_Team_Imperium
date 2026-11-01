// ============================================================================
//  pf_nextline.sv -- Strategy A of the Multi-Modal Adaptive Prefetcher
// ----------------------------------------------------------------------------
//  The cheapest useful predictor there is: if the last two demand accesses
//  landed on consecutive cache lines, guess that the sweep continues.
//
//  Despite how trivial it is, this is the right answer for a large share of AI
//  memory traffic.  Loading a weight matrix for a GEMM, streaming an
//  activation tensor, or walking a KV-cache block all produce long contiguous
//  runs where "the next line" is correct essentially every time.  Spending a
//  16-entry table on that would be a waste, so this engine keeps exactly two
//  registers and hands the arbiter a confidence value built from how long the
//  current contiguous run has been going.
//
//  Confidence is a 2-bit saturating streak counter, so a run has to survive a
//  few accesses before this engine can outbid a more specific predictor.
// ============================================================================
`default_nettype none

module pf_nextline #(
  parameter int ADDR_W     = 32,
  parameter int LINE_BYTES = 64
)(
  input  wire                     clk,
  input  wire                     rst_n,

  // Demand access stream (training + trigger)
  input  wire                     trig_vld,
  input  wire  [ADDR_W-1:0]       trig_addr,

  // Prediction
  output logic                    pred_vld,
  output logic [ADDR_W-1:0]       pred_addr,   // first line to fetch
  output logic signed [31:0]      pred_step,   // byte step between fetches
  output logic [1:0]              pred_conf
);

  localparam int LOG2_LINE = $clog2(LINE_BYTES);
  localparam int LINE_W    = ADDR_W - LOG2_LINE;

  logic [LINE_W-1:0] last_line;
  logic              have_last;
  logic [1:0]        streak;

  logic [LINE_W-1:0] cur_line;
  logic              is_sequential;

  assign cur_line      = trig_addr[ADDR_W-1:LOG2_LINE];
  assign is_sequential = have_last && (cur_line == (last_line + 1'b1));

  assign pred_step = 32'sd1 <<< LOG2_LINE;      // always +1 line

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      last_line <= '0;
      have_last <= 1'b0;
      streak    <= '0;
      pred_vld  <= 1'b0;
      pred_addr <= '0;
      pred_conf <= '0;
    end else begin
      pred_vld <= 1'b0;

      if (trig_vld) begin
        last_line <= cur_line;
        have_last <= 1'b1;

        if (is_sequential) begin
          // Grow the streak and offer the line after this one.
          streak    <= (streak == 2'd3) ? 2'd3 : (streak + 2'd1);
          pred_vld  <= 1'b1;
          pred_addr <= {(cur_line + 1'b1), {LOG2_LINE{1'b0}}};
          pred_conf <= (streak == 2'd3) ? 2'd3 : (streak + 2'd1);
        end else begin
          // Discontinuity: the run is over, start counting again.
          streak <= 2'd0;
        end
      end
    end
  end

endmodule

`default_nettype wire
