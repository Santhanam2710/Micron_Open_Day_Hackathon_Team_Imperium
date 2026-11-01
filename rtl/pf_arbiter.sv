// ============================================================================
//  pf_arbiter.sv -- Innovation 1: confidence arbitration across three engines
// ----------------------------------------------------------------------------
//  The three prefetch engines run concurrently on the same demand stream and
//  each one bids with a 2-bit confidence.  This block picks at most one winner
//  per trigger.
//
//  Three rules do the work:
//
//  1. A bid below the confidence threshold is not a weak prefetch, it is *no*
//     prefetch.  An engine that has not yet seen its pattern repeat is
//     guessing, and a guess costs a memory burst plus an eviction.  Issuing
//     nothing is strictly better than issuing a coin flip, and this is the
//     single most important line in the file.
//
//  2. CORROBORATION BEATS SPECIFICITY.  If the stride engine and the
//     correlation engine predict the same next delta, they are confirming each
//     other, and the stride form of that prediction is strictly more valuable:
//     a constant stride can be walked out to many lines ahead, whereas the
//     correlation table only ever speaks about the single next transition.
//     Since lookahead distance is what determines whether a prefetch arrives
//     in time, the expandable form wins whenever both engines agree.
//
//     This rule was added after measurement, not before.  On the strided
//     column-sweep trace the correlation engine was winning 29,587 of 29,940
//     arbitrations on a tie, replacing a prediction that could have been
//     expanded eight lines ahead with one that reached exactly one line ahead
//     -- so the prefetches were accurate and consistently late.
//
//  3. When the engines genuinely disagree, the most specific confident engine
//     wins: delta-correlation, then stride, then next-line.  If the
//     correlation table recognises the exact delta sequence it is in, that is
//     stronger evidence than "the last two lines happened to be adjacent".
//     Next-line becomes confident very easily, so without this ordering it
//     would take most ties and the specialised engines would never contribute.
//
//  The per-engine win counters exist so the ablation study can show that all
//  three engines actually earn their area, rather than one doing all the work
//  while the other two are decoration.
// ============================================================================
`default_nettype none

module pf_arbiter #(
  parameter int ADDR_W = 32,
  parameter bit EN_NL  = 1'b1,
  parameter bit EN_ST  = 1'b1,
  parameter bit EN_DC  = 1'b1
)(
  input  wire               clk,
  input  wire               rst_n,

  // ---- Candidate A: next-line
  input  wire               nl_vld,
  input  wire [ADDR_W-1:0]  nl_addr,
  input  wire signed [31:0] nl_step,
  input  wire [1:0]         nl_conf,
  // ---- Candidate B: stride
  input  wire               st_vld,
  input  wire [ADDR_W-1:0]  st_addr,
  input  wire signed [31:0] st_step,
  input  wire [1:0]         st_conf,
  // ---- Candidate C: delta-correlation
  input  wire               dc_vld,
  input  wire [ADDR_W-1:0]  dc_addr,
  input  wire signed [31:0] dc_step,
  input  wire [1:0]         dc_conf,

  // ---- Gating from the phase detector and the throttle
  input  wire               allow_nl,
  input  wire               allow_st,
  input  wire               allow_dc,
  input  wire [1:0]         conf_thresh,
  input  wire               suppress,
  input  wire [3:0]         degree,

  // ---- Winner
  output logic              win_vld,
  output logic [ADDR_W-1:0] win_addr,
  output logic signed [31:0] win_step,
  output logic [3:0]        win_count,
  output logic [1:0]        win_src,

  // ---- Observability
  output logic [31:0]       cnt_win_nl,
  output logic [31:0]       cnt_win_st,
  output logic [31:0]       cnt_win_dc,
  output logic [31:0]       cnt_gated_lowconf, // bid existed, confidence too low
  output logic [31:0]       cnt_gated_phase,   // bid existed, phase blocked it
  output logic [31:0]       cnt_gated_throttle // bid existed, throttle suppressed
);

  import cache_pkg::*;

  // --------------------------------------------------------------------------
  //  Eligibility
  // --------------------------------------------------------------------------
  logic cand_nl, cand_st, cand_dc;
  logic any_bid, any_phase_ok, any_conf_ok;

  assign cand_nl = EN_NL && nl_vld && allow_nl && (nl_conf >= conf_thresh);
  assign cand_st = EN_ST && st_vld && allow_st && (st_conf >= conf_thresh);
  assign cand_dc = EN_DC && dc_vld && allow_dc && (dc_conf >= conf_thresh);

  assign any_bid      = (EN_NL && nl_vld) || (EN_ST && st_vld) || (EN_DC && dc_vld);
  assign any_phase_ok = (EN_NL && nl_vld && allow_nl) ||
                        (EN_ST && st_vld && allow_st) ||
                        (EN_DC && dc_vld && allow_dc);
  assign any_conf_ok  = cand_nl || cand_st || cand_dc;

  // --------------------------------------------------------------------------
  //  Selection
  // --------------------------------------------------------------------------
  logic [1:0] best_conf;
  logic       corroborated;

  // The two specialised engines independently predict the same next delta.
  assign corroborated = cand_st && cand_dc && (st_step == dc_step);

  always_comb begin
    best_conf = 2'd0;
    if (cand_nl && (nl_conf > best_conf)) best_conf = nl_conf;
    if (cand_st && (st_conf > best_conf)) best_conf = st_conf;
    if (cand_dc && (dc_conf > best_conf)) best_conf = dc_conf;

    win_vld   = 1'b0;
    win_addr  = '0;
    win_step  = '0;
    win_src   = SRC_NONE;
    win_count = 4'd1;

    if (!suppress && corroborated) begin
      // Rule 2: both engines agree, so take the expandable form and walk it
      // out to the full degree.  This is the timeliness path.
      win_vld   = 1'b1;
      win_addr  = st_addr;
      win_step  = st_step;
      win_src   = SRC_STRIDE;
      win_count = degree;
    end else if (!suppress && any_conf_ok) begin
      // Rule 3: they disagree -- most specific confident engine first.
      if (cand_dc && (dc_conf == best_conf)) begin
        win_vld   = 1'b1;
        win_addr  = dc_addr;
        win_step  = dc_step;
        win_src   = SRC_DELTA;
        // The correlation table predicts exactly one transition ahead, so
        // chaining it would be extrapolation it has no evidence for.
        win_count = 4'd1;
      end else if (cand_st && (st_conf == best_conf)) begin
        win_vld   = 1'b1;
        win_addr  = st_addr;
        win_step  = st_step;
        win_src   = SRC_STRIDE;
        win_count = degree;
      end else if (cand_nl && (nl_conf == best_conf)) begin
        win_vld   = 1'b1;
        win_addr  = nl_addr;
        win_step  = nl_step;
        win_src   = SRC_NEXTLINE;
        win_count = degree;
      end
    end
  end

  // --------------------------------------------------------------------------
  //  Counters
  // --------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt_win_nl         <= '0;
      cnt_win_st         <= '0;
      cnt_win_dc         <= '0;
      cnt_gated_lowconf  <= '0;
      cnt_gated_phase    <= '0;
      cnt_gated_throttle <= '0;
    end else begin
      if (win_vld) begin
        case (win_src)
          SRC_NEXTLINE: cnt_win_nl <= cnt_win_nl + 1'b1;
          SRC_STRIDE  : cnt_win_st <= cnt_win_st + 1'b1;
          SRC_DELTA   : cnt_win_dc <= cnt_win_dc + 1'b1;
          default     : ;
        endcase
      end
      // Attribute each refused bid to the stage that refused it.
      if (any_bid && suppress)
        cnt_gated_throttle <= cnt_gated_throttle + 1'b1;
      else if (any_bid && !any_phase_ok)
        cnt_gated_phase <= cnt_gated_phase + 1'b1;
      else if (any_phase_ok && !any_conf_ok)
        cnt_gated_lowconf <= cnt_gated_lowconf + 1'b1;
    end
  end

endmodule

`default_nettype wire
