// ============================================================================
//  pf_throttle.sv -- Innovation 2: Feedback-Driven Prefetch Throttle
// ----------------------------------------------------------------------------
//  A prefetcher has two ways to lose.  The obvious one is predicting wrongly.
//  The less obvious and more damaging one is predicting wrongly *at high
//  volume*: every incorrect prefetch consumes a DRAM burst that a demand miss
//  needed, and installs a line that evicts something that was going to be
//  used.  Past a certain aggressiveness, turning the prefetcher up makes the
//  machine slower, and nothing inside the predictors themselves can see that
//  happening.
//
//  So close the loop.  The cache already knows the ground truth for every
//  speculative line it installs:
//
//    useful  -- a demand access hit a line that had been prefetched and not
//               yet touched (the prefetch paid for itself)
//    useless -- such a line was evicted having never been touched (the
//               prefetch cost a fill and an eviction and returned nothing)
//
//  Those two counters are an online measurement of prefetch accuracy, and this
//  module turns them into an aggressiveness control:
//
//    accuracy below ~50%  (useless > useful)      -> halve the degree
//    accuracy above ~75%  (useful  > 3 x useless) -> double the degree
//    otherwise                                     -> hold
//
//  Both tests are comparisons against shifted sums, so there is no divider on
//  the control path.
//
//  SUPPRESSION AND RECOVERY
//  If accuracy is still poor at degree 1 there is nothing left to halve, so the
//  prefetcher is suppressed outright.  A suppressed prefetcher issues nothing,
//  which means both counters stay at zero and no rule can ever fire again --
//  so suppression would latch up forever.  The fix is an explicit exploration
//  timer: after RETRY_WINDOWS quiet windows the throttle releases itself back
//  to degree 1 and re-measures.  A phase change that makes the workload
//  predictable again is therefore picked up automatically.
// ============================================================================
`default_nettype none

module pf_throttle #(
  parameter int WINDOW        = 256,  // demand accesses per control window
  parameter int DEGREE_INIT   = 2,
  parameter int DEGREE_MAX    = 8,
  parameter int RETRY_WINDOWS = 4,    // quiet windows before re-probing
  parameter bit ENABLE        = 1'b1
)(
  input  wire        clk,
  input  wire        rst_n,

  input  wire        acc_vld,      // one demand access
  input  wire        pf_useful,    // demand hit on an untouched prefetched line
  input  wire        pf_useless,   // untouched prefetched line evicted

  output logic [3:0] degree,       // prefetches to issue per winning trigger
  output logic       suppress,     // hold all prefetching

  // Observability
  output logic [31:0] cnt_down,
  output logic [31:0] cnt_up,
  output logic [31:0] cnt_suppress_win,
  output logic [31:0] cnt_degree_acc,  // sum of degree over windows -> mean
  output logic [31:0] cnt_windows
);

  localparam int WCNT_W = $clog2(WINDOW) + 1;

  logic [WCNT_W-1:0] acc_cnt;
  logic [15:0]       useful_w, useless_w;
  logic [3:0]        quiet_cnt;

  // 3 x useless, built from a shift and an add rather than a multiplier.
  logic [17:0] useless_x3;
  assign useless_x3 = {1'b0, useless_w, 1'b0} + {2'b0, useless_w};

  logic acc_low, acc_high;
  assign acc_low  = (useless_w > useful_w);                    // < ~50% accurate
  assign acc_high = ({2'b0, useful_w} > useless_x3);           // > ~75% accurate

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc_cnt          <= '0;
      useful_w         <= '0;
      useless_w        <= '0;
      quiet_cnt        <= '0;
      degree           <= 4'(DEGREE_INIT);
      suppress         <= 1'b0;
      cnt_down         <= '0;
      cnt_up           <= '0;
      cnt_suppress_win <= '0;
      cnt_degree_acc   <= '0;
      cnt_windows      <= '0;
    end else if (!ENABLE) begin
      // Throttle compiled out: fixed aggressiveness, never suppressed.
      // This is the control arm for the Innovation-2 ablation.
      degree   <= 4'(DEGREE_INIT);
      suppress <= 1'b0;
    end else begin
      if (pf_useful)  useful_w  <= useful_w  + 1'b1;
      if (pf_useless) useless_w <= useless_w + 1'b1;

      if (acc_vld) begin
        if (acc_cnt == WCNT_W'(WINDOW-1)) begin
          acc_cnt        <= '0;
          cnt_windows    <= cnt_windows + 1'b1;
          cnt_degree_acc <= cnt_degree_acc + (suppress ? 32'd0 : {28'b0, degree});

          if (suppress) begin
            cnt_suppress_win <= cnt_suppress_win + 1'b1;
            // Exploration: come back on after a few quiet windows, otherwise
            // suppression is a one-way door.
            if (quiet_cnt == 4'(RETRY_WINDOWS-1)) begin
              suppress  <= 1'b0;
              degree    <= 4'd1;
              quiet_cnt <= '0;
            end else begin
              quiet_cnt <= quiet_cnt + 1'b1;
            end
          end else if (acc_low) begin
            if (degree > 4'd1) begin
              degree   <= degree >> 1;
              cnt_down <= cnt_down + 1'b1;
            end else begin
              suppress  <= 1'b1;         // nothing left to halve
              quiet_cnt <= '0;
              cnt_down  <= cnt_down + 1'b1;
            end
          end else if (acc_high) begin
            if (degree < 4'(DEGREE_MAX)) begin
              degree <= degree << 1;
              cnt_up <= cnt_up + 1'b1;
            end
          end
          // else: accuracy is in the acceptable band -- leave it alone.

          useful_w  <= '0;
          useless_w <= '0;
        end else begin
          acc_cnt <= acc_cnt + 1'b1;
        end
      end
    end
  end

endmodule

`default_nettype wire
