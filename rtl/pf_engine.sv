// ============================================================================
//  pf_engine.sv -- Multi-Modal Adaptive Prefetcher (MMAP), top level
// ----------------------------------------------------------------------------
//  Wires the three prediction engines, the phase detector, the throttle and
//  the confidence arbiter into one block, then turns the arbiter's single
//  winning prediction into a stream of prefetch requests for the cache.
//
//  Three pieces of plumbing matter as much as the predictors themselves:
//
//  DEGREE EXPANSION -- the arbiter emits one address plus a byte step plus a
//  count.  The expander walks that out into `count` separate requests
//  (base, base+step, base+2*step, ...).  Degree therefore means "how many
//  lines we commit to" rather than "how far ahead we jump", which is what
//  makes the throttle's halve/double control meaningful: halving the degree
//  halves the speculative bandwidth instead of just moving the target.
//
//  REDUNDANCY FILTER -- a 16-entry ring of recently requested and recently
//  accessed line addresses.  Without it a degree-4 next-line stream re-requests
//  the same lines on every access and the "prefetches issued" figure becomes
//  meaningless.  The cache probes its own tags as well, so this filter is
//  about not wasting queue slots and cache cycles on requests that are already
//  in flight.
//
//  REQUEST QUEUE -- a short FIFO that decouples prediction from service.  The
//  cache drains it only when it has no demand work, so prefetching uses idle
//  cycles and never delays a real access that has already been accepted.
//  Dropping on full is deliberate: a stale prediction is worth less than the
//  queue slot it would occupy.
// ============================================================================
`default_nettype none

module pf_engine #(
  parameter bit EN_PERCEPTRON = 1'b0,
  parameter int ML_MARGIN = 16,
  parameter int ML_EXPLORE_LOG2 = 5,
  parameter int ADDR_W        = 32,
  parameter int LINE_BYTES    = 64,
  // ---- Innovation 1: which engines exist
  parameter bit EN_NEXTLINE   = 1'b1,
  parameter bit EN_STRIDE     = 1'b1,
  parameter bit EN_DELTA      = 1'b1,
  // ---- Innovation 2: feedback throttle
  parameter bit EN_THROTTLE   = 1'b1,
  parameter int DEGREE_INIT   = 2,
  parameter int DEGREE_MAX    = 8,
  parameter int THR_WINDOW    = 256,
  // ---- Innovation 3: phase detector
  parameter bit EN_PHASE      = 1'b1,
  parameter int PHASE_WINDOW  = 64,
  // ---- Structural sizing
  parameter int ST_TABLE      = 16,
  parameter int ST_REGION_LOG2= 16,
  parameter int DC_TABLE      = 128,
  parameter int DC_HIST       = 6,
  parameter int QUEUE_DEPTH   = 16,
  parameter int FILTER_DEPTH  = 32
)(
  input  wire               clk,
  input  wire               rst_n,

  // ---- Demand access stream from the cache (training + trigger)
  input  wire               acc_vld,
  input  wire [ADDR_W-1:0]  acc_addr,

  // ---- Prefetch outcome feedback from the cache
  input  wire               fb_useful,
  input  wire               fb_useless,
  input wire [9:0] fb_useful_meta, fb_useless_meta,

  // ---- Prefetch request interface to the cache
  output wire [9:0] pf_meta,
  output logic              pf_vld,
  output logic [ADDR_W-1:0] pf_addr,
  input  wire               pf_take,

  // ---- Observability ------------------------------------------------------
  output logic [31:0]       st_win_nl,
  output logic [31:0]       st_win_st,
  output logic [31:0]       st_win_dc,
  output logic [31:0]       st_gated_lowconf,
  output logic [31:0]       st_gated_phase,
  output logic [31:0]       st_gated_throttle,
  output logic [31:0]       st_enq,
  output logic [31:0]       st_drop_dup,
  output logic [31:0]       st_drop_qfull,
  output logic [31:0]       st_drop_busy,
  output logic [31:0]       st_thr_down,
  output logic [31:0]       st_thr_up,
  output logic [31:0]       st_thr_suppress_win,
  output logic [31:0]       st_thr_degree_acc,
  output logic [31:0]       st_thr_windows,
  output logic [31:0]       st_ph_stream,
  output logic [31:0]       st_ph_stride,
  output logic [31:0]       st_ph_irreg,
  output logic [31:0]       st_ph_transitions,
  output logic [15:0]       st_dc_alloc,
  output logic [15:0]       st_dc_confirm,
  output logic [15:0]       st_st_retrain,
  output logic [1:0]        phase_cur,
  output logic [3:0]        degree_cur
);

  import cache_pkg::*;

  localparam int LOG2_LINE = $clog2(LINE_BYTES);
  localparam int LINE_W    = ADDR_W - LOG2_LINE;
  localparam int QPTR_W    = $clog2(QUEUE_DEPTH);
  localparam int FPTR_W    = $clog2(FILTER_DEPTH);

  // ==========================================================================
  //  The prefetcher trains on the LINE-TRANSITION stream, not the raw access
  //  stream.  A kernel sweeping a float32 array issues sixteen accesses per
  //  64-byte line; fifteen of them hit, cost no fill, and carry no information
  //  a prefetcher can act on.  Letting them through makes every predictor see
  //  a delta of zero most of the time -- the next-line streak counter resets
  //  on every one of them, the stride table keeps re-learning a stride of
  //  zero, and the correlation table fills up with (0,0,0) signatures.
  //  Filtering once, here, fixes all three engines at once and is cheaper than
  //  fixing each of them separately.
  //
  //  The phase detector deliberately keeps the ungated stream: it does its own
  //  zero-skipping internally, and its residency counters are more useful
  //  expressed per access than per line transition.
  // ==========================================================================
  logic [LINE_W-1:0] prev_trig_line;
  logic              have_prev;
  logic              trig_vld;

  assign trig_vld = acc_vld &&
                    (!have_prev || (acc_addr[ADDR_W-1:LOG2_LINE] != prev_trig_line));

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      prev_trig_line <= '0;
      have_prev      <= 1'b0;
    end else if (acc_vld) begin
      prev_trig_line <= acc_addr[ADDR_W-1:LOG2_LINE];
      have_prev      <= 1'b1;
    end
  end

  // ==========================================================================
  //  Prediction engines
  // ==========================================================================
  logic               nl_vld, st_vld, dc_vld;
  logic [ADDR_W-1:0]  nl_addr, st_addr, dc_addr;
  logic signed [31:0] nl_step, st_step, dc_step;
  logic [1:0]         nl_conf, st_conf, dc_conf;

  generate
    if (EN_NEXTLINE) begin : g_nl
      pf_nextline #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES)) u_nl (
        .clk, .rst_n,
        .trig_vld (trig_vld),
        .trig_addr(acc_addr),
        .pred_vld (nl_vld),
        .pred_addr(nl_addr),
        .pred_step(nl_step),
        .pred_conf(nl_conf)
      );
    end else begin : g_no_nl
      assign nl_vld = 1'b0; assign nl_addr = '0;
      assign nl_step = '0;  assign nl_conf = '0;
    end

    if (EN_STRIDE) begin : g_st
      pf_stride #(
        .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES),
        .TABLE_SIZE(ST_TABLE), .REGION_LOG2(ST_REGION_LOG2)
      ) u_st (
        .clk, .rst_n,
        .trig_vld (trig_vld),
        .trig_addr(acc_addr),
        .pred_vld (st_vld),
        .pred_addr(st_addr),
        .pred_step(st_step),
        .pred_conf(st_conf),
        .n_retrain(st_st_retrain)
      );
    end else begin : g_no_st
      assign st_vld = 1'b0; assign st_addr = '0;
      assign st_step = '0;  assign st_conf = '0;
      assign st_st_retrain = '0;
    end

    if (EN_DELTA) begin : g_dc
      pf_delta_corr #(
        .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES),
        .HIST_DEPTH(DC_HIST), .TABLE_SIZE(DC_TABLE)
      ) u_dc (
        .clk, .rst_n,
        .trig_vld (trig_vld),
        .trig_addr(acc_addr),
        .pred_vld (dc_vld),
        .pred_addr(dc_addr),
        .pred_step(dc_step),
        .pred_conf(dc_conf),
        .n_alloc  (st_dc_alloc),
        .n_confirm(st_dc_confirm)
      );
    end else begin : g_no_dc
      assign dc_vld = 1'b0; assign dc_addr = '0;
      assign dc_step = '0;  assign dc_conf = '0;
      assign st_dc_alloc = '0; assign st_dc_confirm = '0;
    end
  endgenerate

  // ==========================================================================
  //  Innovation 3: phase detector
  // ==========================================================================
  logic       allow_nl, allow_st, allow_dc;
  logic [1:0] conf_thresh;

  phase_detect #(
    .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES),
    .WINDOW(PHASE_WINDOW), .ENABLE(EN_PHASE)
  ) u_phase (
    .clk, .rst_n,
    .trig_vld (acc_vld),
    .trig_addr(acc_addr),
    .allow_nl, .allow_st, .allow_dc, .conf_thresh,
    .phase_o        (phase_cur),
    .cnt_stream     (st_ph_stream),
    .cnt_stride     (st_ph_stride),
    .cnt_irreg      (st_ph_irreg),
    .cnt_transitions(st_ph_transitions)
  );

  // ==========================================================================
  //  Innovation 2: feedback throttle
  // ==========================================================================
  logic       suppress;

  pf_throttle #(
    .WINDOW(THR_WINDOW), .DEGREE_INIT(DEGREE_INIT),
    .DEGREE_MAX(DEGREE_MAX), .ENABLE(EN_THROTTLE)
  ) u_thr (
    .clk, .rst_n,
    .acc_vld   (acc_vld),
    .pf_useful (fb_useful),
    .pf_useless(fb_useless),
    .degree    (degree_cur),
    .suppress  (suppress),
    .cnt_down        (st_thr_down),
    .cnt_up          (st_thr_up),
    .cnt_suppress_win(st_thr_suppress_win),
    .cnt_degree_acc  (st_thr_degree_acc),
    .cnt_windows     (st_thr_windows)
  );

  // ==========================================================================
  //  Innovation 1: confidence arbiter
  // ==========================================================================
  logic              win_vld;
  logic [ADDR_W-1:0] win_addr;
  logic signed[31:0] win_step;
  logic [3:0]        win_count;
  logic [1:0]        win_src;

  pf_arbiter #(
    .ADDR_W(ADDR_W),
    .EN_NL(EN_NEXTLINE), .EN_ST(EN_STRIDE), .EN_DC(EN_DELTA)
  ) u_arb (
    .clk, .rst_n,
    .nl_vld, .nl_addr, .nl_step, .nl_conf,
    .st_vld, .st_addr, .st_step, .st_conf,
    .dc_vld, .dc_addr, .dc_step, .dc_conf,
    .allow_nl, .allow_st, .allow_dc, .conf_thresh,
    .suppress, .degree(degree_cur),
    .win_vld, .win_addr, .win_step, .win_count, .win_src,
    .cnt_win_nl        (st_win_nl),
    .cnt_win_st        (st_win_st),
    .cnt_win_dc        (st_win_dc),
    .cnt_gated_lowconf (st_gated_lowconf),
    .cnt_gated_phase   (st_gated_phase),
    .cnt_gated_throttle(st_gated_throttle)
  );

  // ==========================================================================
  //  Redundancy filter: ring of recently requested / accessed line addresses
  // ==========================================================================
  logic [LINE_W-1:0] filt_line [FILTER_DEPTH];
  logic              filt_vld  [FILTER_DEPTH];
  logic [FPTR_W-1:0] filt_ptr;

  // Two combinational lookups are needed: one for the address the expander is
  // about to push, and one for a fresh winner's first address.  Checking the
  // winner up front matters -- without it the expander spends its cycles
  // walking out a prediction whose every line is already resident, and starves
  // the predictions that would have been useful.
  function automatic logic in_filter (input logic [LINE_W-1:0] l);
    begin
      in_filter = 1'b0;
      for (int i = 0; i < FILTER_DEPTH; i++)
        if (filt_vld[i] && (filt_line[i] == l)) in_filter = 1'b1;
    end
  endfunction

  // ==========================================================================
  //  Degree expander
  // ==========================================================================
  logic              exp_busy;
  logic [ADDR_W-1:0] exp_addr;
  logic signed[31:0] exp_step;
  logic [3:0]        exp_rem;
  logic [1:0] exp_src, exp_phase;
  logic [3:0] exp_index;

  logic [LINE_W-1:0] cand_line, win_line;
  logic              is_dup, win_dup;

  assign cand_line = exp_addr[ADDR_W-1:LOG2_LINE];
  assign win_line  = win_addr[ADDR_W-1:LOG2_LINE];
  assign is_dup    = in_filter(cand_line);
  assign win_dup   = in_filter(win_line);

  // ==========================================================================
  //  Request queue
  // ==========================================================================
  logic [ADDR_W-1:0] q_mem [QUEUE_DEPTH];
  logic [9:0] q_meta [QUEUE_DEPTH];
  wire [7:0] ml_features = {exp_addr[12], exp_step[31],
    (exp_step > LINE_BYTES || exp_step < -LINE_BYTES),
    (exp_index >= 4), (exp_index >= 2), (exp_index >= 1), exp_phase};
  wire [9:0] ml_meta = {exp_src, ml_features};
  wire ml_allow;
  wire ml_candidate = exp_busy && !q_full && !is_dup && (cand_line != last_acc_line);
  pf_perceptron #(.ENABLE(EN_PERCEPTRON), .MARGIN(ML_MARGIN),
    .EXPLORE_LOG2(ML_EXPLORE_LOG2)) u_ml (
    .clk, .rst_n, .candidate(ml_candidate), .meta(ml_meta), .allow(ml_allow),
    .useful(fb_useful), .useless(fb_useless),
    .useful_meta(fb_useful_meta), .useless_meta(fb_useless_meta)
  );
  assign pf_meta = q_meta[q_head];
  logic [QPTR_W-1:0] q_head, q_tail;
  logic [QPTR_W:0]   q_cnt;
  logic              q_full, q_empty;

  assign q_full  = (q_cnt == (QPTR_W+1)'(QUEUE_DEPTH));
  assign q_empty = (q_cnt == '0);
  assign pf_vld  = !q_empty;
  assign pf_addr = q_mem[q_head];

  logic [LINE_W-1:0] last_acc_line;

  logic do_push, do_pop;
  assign do_pop  = pf_vld && pf_take;
  assign do_push = ml_candidate && ml_allow;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < FILTER_DEPTH; i++) begin
        filt_vld[i]  <= 1'b0;
        filt_line[i] <= '0;
      end
      filt_ptr      <= '0;
      exp_busy      <= 1'b0;
      exp_addr      <= '0;
      exp_step      <= '0;
      exp_rem       <= '0;
      exp_src <= '0; exp_phase <= '0; exp_index <= '0;
      q_head        <= '0;
      q_tail        <= '0;
      q_cnt         <= '0;
      last_acc_line <= '0;
      st_enq        <= '0;
      st_drop_dup   <= '0;
      st_drop_qfull <= '0;
      st_drop_busy  <= '0;
    end else begin
      if (acc_vld) last_acc_line <= acc_addr[ADDR_W-1:LOG2_LINE];

      // ---- Queue pointers --------------------------------------------------
      if (do_pop) begin
        q_head <= q_head + 1'b1;
      end
      if (do_push) begin
        q_mem[q_tail] <= exp_addr;
        q_meta[q_tail] <= EN_PERCEPTRON ? ml_meta : 10'd0;
        q_tail        <= q_tail + 1'b1;
        st_enq        <= st_enq + 1'b1;
      end
      if (do_push && !do_pop)      q_cnt <= q_cnt + 1'b1;
      else if (do_pop && !do_push) q_cnt <= q_cnt - 1'b1;

      // ---- Filter insertion (requests take priority over demand lines) ----
      if (do_push) begin
        filt_line[filt_ptr] <= cand_line;
        filt_vld [filt_ptr] <= 1'b1;
        filt_ptr            <= filt_ptr + 1'b1;
      end else if (acc_vld) begin
        filt_line[filt_ptr] <= acc_addr[ADDR_W-1:LOG2_LINE];
        filt_vld [filt_ptr] <= 1'b1;
        filt_ptr            <= filt_ptr + 1'b1;
      end

      // ---- Expander --------------------------------------------------------
      if (exp_busy) begin
        if (q_full) begin
          st_drop_qfull <= st_drop_qfull + 1'b1;   // stalled this cycle
        end else begin
          if (is_dup || (cand_line == last_acc_line))
            st_drop_dup <= st_drop_dup + 1'b1;
          exp_addr <= exp_addr + exp_step[ADDR_W-1:0];
          exp_index <= exp_index + 1'b1;
          exp_rem  <= exp_rem - 1'b1;
          if (exp_rem <= 4'd1) exp_busy <= 1'b0;
        end
      end else if (win_vld) begin
        if (win_dup || (win_line == last_acc_line)) begin
          // Everything this prediction would fetch is already here.
          st_drop_dup <= st_drop_dup + 1'b1;
        end else begin
          exp_busy <= 1'b1;
          exp_addr <= win_addr;
          exp_step <= win_step;
          exp_rem  <= win_count;
          exp_src <= win_src; exp_phase <= phase_cur; exp_index <= 0;
        end
      end

      // A fresh winner arriving mid-expansion is dropped: the in-flight
      // expansion is already the better-established prediction.
      if (exp_busy && win_vld) st_drop_busy <= st_drop_busy + 1'b1;
    end
  end

endmodule

`default_nettype wire
