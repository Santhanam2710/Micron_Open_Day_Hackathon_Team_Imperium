// ============================================================================
//  phase_detect.sv -- Innovation 3: Workload Phase Detector
// ----------------------------------------------------------------------------
//  AI inference is not one access pattern, it is a sequence of them.  A CNN
//  alternates convolution (constant stride) with pooling and flattening
//  (contiguous).  A transformer alternates prefill (long contiguous weight
//  sweeps) with decode (scattered KV-cache and embedding reads).  A prefetcher
//  tuned for one of those is actively harmful during the others: during an
//  embedding gather, next-line and stride predictions are close to random, and
//  every one of them burns DRAM bandwidth and evicts a line that was wanted.
//
//  So classify the phase in hardware and gate the engines accordingly.
//
//  HOW IT CLASSIFIES -- Boyer-Moore majority vote
//  The obvious implementation is a stride histogram, which costs a CAM plus a
//  set of counters plus a max-finder.  Instead this uses the Boyer-Moore
//  majority-vote algorithm, which finds the majority element of a stream using
//  exactly one candidate register and one counter:
//
//      for each delta d:  if count == 0      -> candidate = d, count = 1
//                         else if d == cand  -> count++
//                         else               -> count--
//
//  Boyer-Moore guarantees that *if* a strict majority element exists it ends up
//  in the candidate register.  It does not tell you the element's frequency, so
//  the classic algorithm needs a verification pass.  Rather than pay for a
//  second pass, this detector verifies the candidate found in window N while
//  it searches window N+1 -- one window of lag, which at 64 line-transitions
//  is immaterial, and the state cost stays at two registers instead of a
//  histogram.
//
//  Zero deltas (repeat accesses inside one cache line) are skipped entirely.
//  They hit in the cache, they cost no fill, and letting them into the vote
//  would swamp it and classify everything as "stride zero".
//
//  WHAT THE GATING DOES
//    STREAM : next-line is near-perfect.  Delta-correlation is blocked, which
//             keeps its 64 entries free for genuinely hard patterns instead of
//             filling them with trivial (+1,+1,+1) signatures.
//    STRIDE : stride and delta-correlation both contribute (delta picks up the
//             row-pitch jump that resets the stride detector's confidence).
//    IRREG  : next-line and stride are blocked outright and the confidence
//             threshold is raised, so the prefetcher goes quiet unless the
//             correlation table genuinely recognises the sequence.  This is
//             where the detector earns its area.
// ============================================================================
`default_nettype none

module phase_detect #(
  parameter int ADDR_W     = 32,
  parameter int LINE_BYTES = 64,
  parameter int WINDOW     = 64,   // line-transitions per observation window
  parameter int THRESH_NUM = 7,    // dominant-delta share needed: NUM/DEN
  parameter int THRESH_DEN = 10,
  parameter bit ENABLE     = 1'b1
)(
  input  wire               clk,
  input  wire               rst_n,

  input  wire               trig_vld,
  input  wire [ADDR_W-1:0]  trig_addr,

  // Gating for the prefetch arbiter
  output logic              allow_nl,
  output logic              allow_st,
  output logic              allow_dc,
  output logic [1:0]        conf_thresh,

  // Observability
  output logic [1:0]        phase_o,
  output logic [31:0]       cnt_stream,
  output logic [31:0]       cnt_stride,
  output logic [31:0]       cnt_irreg,
  output logic [31:0]       cnt_transitions
);

  import cache_pkg::*;

  localparam int LOG2_LINE = $clog2(LINE_BYTES);
  localparam int LINE_W    = ADDR_W - LOG2_LINE;
  localparam int DW        = 16;                 // signed delta width, in lines
  localparam int WCNT_W    = $clog2(WINDOW) + 1;
  localparam int MATCH_MIN = (WINDOW * THRESH_NUM) / THRESH_DEN;

  // --------------------------------------------------------------------------
  //  Delta extraction
  // --------------------------------------------------------------------------
  logic [LINE_W-1:0]      last_line;
  logic                   have_last;
  logic [LINE_W-1:0]      cur_line;
  logic signed [LINE_W:0] raw_delta;
  logic signed [DW-1:0]   delta;
  logic                   delta_usable;

  assign cur_line     = trig_addr[ADDR_W-1:LOG2_LINE];
  assign raw_delta    = $signed({1'b0, cur_line}) - $signed({1'b0, last_line});
  assign delta        = raw_delta[DW-1:0];
  // Skip intra-line repeats and deltas too large to represent.
  assign delta_usable = have_last && (raw_delta != 0) &&
                        (raw_delta <=  ((1 <<< (DW-1)) - 1)) &&
                        (raw_delta >= -((1 <<< (DW-1))));

  // --------------------------------------------------------------------------
  //  Boyer-Moore search state (window N) + verification state (window N-1)
  // --------------------------------------------------------------------------
  logic signed [DW-1:0] bm_cand;
  logic [WCNT_W-1:0]    bm_count;
  logic signed [DW-1:0] locked_cand;
  logic                 locked_vld;
  logic [WCNT_W-1:0]    match_cnt;
  logic [WCNT_W-1:0]    win_cnt;

  logic [1:0] phase_q;
  assign phase_o = phase_q;

  // --------------------------------------------------------------------------
  //  Gating (combinational from the current phase)
  // --------------------------------------------------------------------------
  always_comb begin
    if (!ENABLE) begin
      // Detector compiled out: every engine runs all the time at the normal
      // threshold.  This is the control arm for the Innovation-3 ablation.
      allow_nl    = 1'b1;
      allow_st    = 1'b1;
      allow_dc    = 1'b1;
      conf_thresh = 2'd1;
    end else begin
      unique case (phase_q)
        PH_STREAM: begin
          allow_nl = 1'b1; allow_st = 1'b1; allow_dc = 1'b0; conf_thresh = 2'd1;
        end
        PH_STRIDE: begin
          allow_nl = 1'b1; allow_st = 1'b1; allow_dc = 1'b1; conf_thresh = 2'd1;
        end
        PH_IRREG: begin
          // Raise the evidence bar rather than blocking engines outright.
          // Hard-blocking the stride engine here was measured to be wrong: on
          // the blocked-GEMM trace two operands are interleaved, so the GLOBAL
          // delta stream looks irregular while each operand is perfectly
          // strided.  The stride table is region-indexed and therefore holds
          // per-stream evidence, so silencing it threw away real coverage.
          // Demanding maximum confidence instead keeps engines that have
          // genuine per-stream evidence and still silences engines that are
          // guessing -- on a true random gather nothing ever reaches 3.
          // Next-line has no per-stream state at all, so it stays blocked.
          allow_nl = 1'b0; allow_st = 1'b1; allow_dc = 1'b1; conf_thresh = 2'd3;
        end
        default: begin   // PH_WARMUP -- no evidence yet, so do not restrict
          allow_nl = 1'b1; allow_st = 1'b1; allow_dc = 1'b1; conf_thresh = 2'd1;
        end
      endcase
    end
  end

  // --------------------------------------------------------------------------
  //  Sequential
  // --------------------------------------------------------------------------
  logic [1:0] next_phase;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      last_line       <= '0;
      have_last       <= 1'b0;
      bm_cand         <= '0;
      bm_count        <= '0;
      locked_cand     <= '0;
      locked_vld      <= 1'b0;
      match_cnt       <= '0;
      win_cnt         <= '0;
      phase_q         <= PH_WARMUP;
      cnt_stream      <= '0;
      cnt_stride      <= '0;
      cnt_irreg       <= '0;
      cnt_transitions <= '0;
    end else begin
      if (trig_vld) begin
        last_line <= cur_line;
        have_last <= 1'b1;

        // Per-access phase residency, for the report.
        case (phase_q)
          PH_STREAM: cnt_stream <= cnt_stream + 1'b1;
          PH_STRIDE: cnt_stride <= cnt_stride + 1'b1;
          PH_IRREG : cnt_irreg  <= cnt_irreg  + 1'b1;
          default  : ;
        endcase

        if (delta_usable) begin
          // ---- Boyer-Moore vote over this window ------------------------
          if (bm_count == '0) begin
            bm_cand  <= delta;
            bm_count <= 1'b1;
          end else if (delta == bm_cand) begin
            bm_count <= bm_count + 1'b1;
          end else begin
            bm_count <= bm_count - 1'b1;
          end

          // ---- Verify the candidate locked from the previous window -----
          if (locked_vld && (delta == locked_cand))
            match_cnt <= match_cnt + 1'b1;

          // ---- Window boundary ------------------------------------------
          if (win_cnt == WCNT_W'(WINDOW-1)) begin
            if (!locked_vld) begin
              next_phase = PH_WARMUP;          // nothing verified yet
            end else if (match_cnt >= WCNT_W'(MATCH_MIN)) begin
              next_phase = (locked_cand == 1) ? PH_STREAM : PH_STRIDE;
            end else begin
              next_phase = PH_IRREG;
            end

            if (next_phase != phase_q) cnt_transitions <= cnt_transitions + 1'b1;
            phase_q <= next_phase;

            // Hand this window's winner to the next window for verification.
            locked_cand <= bm_cand;
            locked_vld  <= 1'b1;
            bm_count    <= '0;
            match_cnt   <= '0;
            win_cnt     <= '0;
          end else begin
            win_cnt <= win_cnt + 1'b1;
          end
        end
      end
    end
  end

endmodule

`default_nettype wire
