// ============================================================================
//  pf_delta_corr.sv -- Strategy C: Delta-Signature Correlation Prefetcher
//                      (the novel engine in this submission)
// ----------------------------------------------------------------------------
//  WHAT IT DOES
//  A stride prefetcher can only express "the address advances by a constant".
//  Plenty of AI access patterns are perfectly repeatable without ever being
//  constant-stride.  A convolution window walks +1, +1, then jumps back by a
//  row pitch; a blocked GEMM walks a tile then jumps to the next tile; a
//  KV-cache read walks one head then jumps by the head stride.  Every one of
//  those is a short REPEATING SEQUENCE of deltas, and a stride detector sees
//  only a good stride being interrupted by noise, losing confidence at exactly
//  the transitions that matter.
//
//  This engine learns the sequence instead of the step.  It keeps the last
//  HIST_DEPTH line-granular deltas as a "signature", hashes it into a small
//  table, and stores the delta that historically followed it.  Seeing the same
//  recent delta sequence again is then enough to predict what comes next --
//  exactly the information a stride detector throws away.
//
//  WHY LINE-GRANULAR DELTAS
//  Byte deltas inside one cache line are noise: those accesses hit anyway.
//  Working in line units collapses all intra-line traffic to a delta of zero,
//  and pf_engine only triggers this engine on accesses that change the line,
//  so the table sees nothing but transitions that actually cost a fill.
//
//  WHY HIST_DEPTH IS 6 AND NOT 3
//  This was measured, not guessed.  The convolution trace produces the
//  periodic delta sequence
//
//      +1, +1, +62, +1, +1, +62, +1, +1, -129   (period 9)
//
//  With a 3-deep history the signature (+1, +1, +62) occurs twice in that
//  period, once followed by +62 and once by -129.  The entry therefore
//  oscillates between two successors, its confidence never gets above the
//  issue threshold, and the engine contributes nothing at all -- which is
//  precisely what the first measurement showed: 0 arbitration wins on the
//  convolution trace.  A 4-deep history is still ambiguous.  At 6 deep all
//  nine positions in the period become distinguishable, and the engine locks
//  on.  Pattern period, not intuition, sets this parameter, which is why it is
//  exposed and swept.
//
//  THE SIGNATURE IS STORED AS A HASH, NOT IN FULL
//  A 6-deep history of 12-bit deltas is a 72-bit signature, and storing that
//  as a tag in every entry would cost more than the rest of the prefetcher put
//  together.  Instead each entry keeps a 24-bit XOR-fold of the signature.
//  Two different signatures can collide, but a collision only produces one
//  wrong prediction before the confidence counter decays it away, so the cost
//  of a collision is bounded and self-correcting.  This is what makes
//  HIST_DEPTH a free parameter instead of an area cliff.
//
//  TRAINING ORDER
//  To learn "signature -> next delta" the entry belonging to the PREVIOUS
//  signature has to be updated once the current delta is known.  So each
//  trigger does: (1) settle the debt on the previous signature using the delta
//  just observed, (2) shift that delta into the history, (3) look up the new
//  signature to make a prediction, (4) remember the new signature's hash.
//
//  COST
//  TABLE_SIZE x (24-bit tag + 12-bit delta + 2-bit confidence + valid) plus a
//  HIST_DEPTH x 12-bit shift register.  At 128 entries that is under 5 kbit --
//  comfortably one M10K block.
// ============================================================================
`default_nettype none

module pf_delta_corr #(
  parameter int ADDR_W     = 32,
  parameter int LINE_BYTES = 64,
  parameter int HIST_DEPTH = 6,    // see header: set by pattern period
  parameter int DELTA_W    = 12,   // signed, in cache lines (+/- 2047 lines)
  parameter int SIGTAG_W   = 24,   // hashed signature tag
  parameter int TABLE_SIZE = 128
)(
  input  wire                     clk,
  input  wire                     rst_n,

  // Line-transition stream (training + trigger)
  input  wire                     trig_vld,
  input  wire  [ADDR_W-1:0]       trig_addr,

  // Prediction
  output logic                    pred_vld,
  output logic [ADDR_W-1:0]       pred_addr,
  output logic signed [31:0]      pred_step,
  output logic [1:0]              pred_conf,

  // Observability
  output logic [15:0]             n_alloc,     // new signatures installed
  output logic [15:0]             n_confirm    // signatures that predicted right
);

  localparam int LOG2_LINE = $clog2(LINE_BYTES);
  localparam int LINE_W    = ADDR_W - LOG2_LINE;
  localparam int SIG_W     = DELTA_W * HIST_DEPTH;
  localparam int IDX_W     = $clog2(TABLE_SIZE);
  localparam signed [DELTA_W-1:0] DELTA_MAX =  (1 <<< (DELTA_W-1)) - 1;
  localparam signed [DELTA_W-1:0] DELTA_MIN = -(1 <<< (DELTA_W-1));

  // --------------------------------------------------------------------------
  //  Delta history
  // --------------------------------------------------------------------------
  logic [LINE_W-1:0]         last_line;
  logic                      have_last;
  logic [3:0]                warm;              // transitions seen, saturating
  logic signed [DELTA_W-1:0] hist [HIST_DEPTH];  // hist[0] = most recent

  logic [LINE_W-1:0]         cur_line;
  logic signed [LINE_W:0]    raw_delta;
  logic signed [DELTA_W-1:0] cur_delta;
  logic                      delta_in_range;

  assign cur_line  = trig_addr[ADDR_W-1:LOG2_LINE];
  assign raw_delta = $signed({1'b0, cur_line}) - $signed({1'b0, last_line});

  // Deltas that do not fit the field are DROPPED, not clamped: clamping would
  // make two different huge jumps look like the same event and teach the table
  // a correlation that does not exist.  Dropping leaves the engine silent on
  // workloads whose streams are far apart in memory (where the region-indexed
  // stride engine is the right tool anyway).
  assign delta_in_range = (raw_delta <= DELTA_MAX) && (raw_delta >= DELTA_MIN);
  assign cur_delta      = raw_delta[DELTA_W-1:0];

  // --------------------------------------------------------------------------
  //  Signature construction and hashing
  // --------------------------------------------------------------------------
  logic [SIG_W-1:0] sig_new;

  always_comb begin
    sig_new = '0;
    sig_new[DELTA_W-1:0] = cur_delta;
    for (int i = 1; i < HIST_DEPTH; i++)
      sig_new[i*DELTA_W +: DELTA_W] = hist[i-1];
  end

  function automatic [SIGTAG_W-1:0] fold_tag (input logic [SIG_W-1:0] s);
    logic [SIGTAG_W-1:0] acc;
    begin
      acc = '0;
      for (int b = 0; b < SIG_W; b += SIGTAG_W) begin
        logic [SIGTAG_W-1:0] chunk;
        chunk = '0;
        for (int j = 0; j < SIGTAG_W; j++)
          if ((b + j) < SIG_W) chunk[j] = s[b + j];
        acc = acc ^ chunk;
      end
      fold_tag = acc;
    end
  endfunction

  function automatic [IDX_W-1:0] fold_idx (input logic [SIGTAG_W-1:0] t);
    logic [IDX_W-1:0] acc;
    begin
      acc = '0;
      for (int b = 0; b < SIGTAG_W; b += IDX_W) begin
        logic [IDX_W-1:0] chunk;
        chunk = '0;
        for (int j = 0; j < IDX_W; j++)
          if ((b + j) < SIGTAG_W) chunk[j] = t[b + j];
        acc = acc ^ chunk;
      end
      fold_idx = acc;
    end
  endfunction

  logic [SIGTAG_W-1:0] tag_new, tag_prev;
  logic                tag_prev_vld;
  logic [IDX_W-1:0]    idx_new, idx_prev;

  assign tag_new  = fold_tag(sig_new);
  assign idx_new  = fold_idx(tag_new);
  assign idx_prev = fold_idx(tag_prev);

  // --------------------------------------------------------------------------
  //  Correlation table
  // --------------------------------------------------------------------------
  logic                      tb_vld   [TABLE_SIZE];
  logic [SIGTAG_W-1:0]       tb_tag   [TABLE_SIZE];
  logic signed [DELTA_W-1:0] tb_delta [TABLE_SIZE];
  logic [1:0]                tb_conf  [TABLE_SIZE];

  logic upd_hit, look_hit;
  assign upd_hit  = tb_vld[idx_prev] && (tb_tag[idx_prev] == tag_prev);
  assign look_hit = tb_vld[idx_new]  && (tb_tag[idx_new]  == tag_new);

  logic signed [LINE_W:0] tgt_line;
  assign tgt_line = $signed({1'b0, cur_line}) + $signed(tb_delta[idx_new]);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      last_line    <= '0;
      have_last    <= 1'b0;
      warm         <= '0;
      tag_prev     <= '0;
      tag_prev_vld <= 1'b0;
      for (int i = 0; i < HIST_DEPTH; i++) hist[i] <= '0;
      for (int i = 0; i < TABLE_SIZE; i++) begin
        tb_vld[i]   <= 1'b0;
        tb_tag[i]   <= '0;
        tb_delta[i] <= '0;
        tb_conf[i]  <= '0;
      end
      pred_vld  <= 1'b0;
      pred_addr <= '0;
      pred_step <= '0;
      pred_conf <= '0;
      n_alloc   <= '0;
      n_confirm <= '0;
    end else begin
      pred_vld <= 1'b0;

      if (trig_vld) begin
        last_line <= cur_line;
        have_last <= 1'b1;

        if (!have_last || !delta_in_range) begin
          // Unusable delta -- clear the history so no signature is ever formed
          // across the discontinuity.
          warm         <= '0;
          tag_prev_vld <= 1'b0;
          for (int i = 0; i < HIST_DEPTH; i++) hist[i] <= '0;
        end else begin
          if (warm != 4'd15) warm <= warm + 4'd1;

          // ---- (1) settle the previous signature's debt -------------------
          if (tag_prev_vld) begin
            if (upd_hit) begin
              if (tb_delta[idx_prev] == cur_delta) begin
                if (tb_conf[idx_prev] != 2'd3)
                  tb_conf[idx_prev] <= tb_conf[idx_prev] + 2'd1;
                n_confirm <= n_confirm + 1'b1;
              end else if (tb_conf[idx_prev] == 2'd0) begin
                tb_delta[idx_prev] <= cur_delta;      // retrain
              end else begin
                tb_conf[idx_prev] <= tb_conf[idx_prev] - 2'd1;
              end
            end else begin
              // Install at weak confidence: one sighting is evidence, not
              // proof, so this entry cannot issue a prefetch yet.
              tb_vld[idx_prev]   <= 1'b1;
              tb_tag[idx_prev]   <= tag_prev;
              tb_delta[idx_prev] <= cur_delta;
              tb_conf[idx_prev]  <= 2'd1;
              n_alloc            <= n_alloc + 1'b1;
            end
          end

          // ---- (2) shift the observed delta into the history --------------
          for (int i = HIST_DEPTH-1; i > 0; i--) hist[i] <= hist[i-1];
          hist[0] <= cur_delta;

          // ---- (3) predict from the new signature -------------------------
          if ((warm >= 4'(HIST_DEPTH)) && look_hit &&
              (tb_delta[idx_new] != '0) && (tgt_line >= 0)) begin
            pred_vld  <= 1'b1;
            pred_addr <= {tgt_line[LINE_W-1:0], {LOG2_LINE{1'b0}}};
            pred_step <= 32'($signed(tb_delta[idx_new])) <<< LOG2_LINE;
            pred_conf <= tb_conf[idx_new];
          end

          // ---- (4) remember the signature we just used -------------------
          tag_prev     <= tag_new;
          tag_prev_vld <= 1'b1;
        end
      end
    end
  end

endmodule

`default_nettype wire
