// ============================================================================
//  repl_policy.sv -- Selectable cache replacement policy
// ----------------------------------------------------------------------------
//  POLICY = 0 (POL_LRU)   : exact LRU using a per-set age permutation
//  POLICY = 1 (POL_SRRIP) : static Re-Reference Interval Prediction
//  POLICY = 2 (POL_DRRIP) : SRRIP vs BRRIP selected at run time by set-duelling
//
//  SRRIP recap -- every line carries a 2-bit RRPV ("re-reference prediction
//  value"): 0 means "expected to be re-used soon", 3 means "expected to be
//  re-used only in the distant future".  A hit resets the line to 0.  A new
//  line is inserted at 2, so a line that is never re-used is evicted after one
//  round of ageing instead of displacing the whole set.  That is what makes
//  RRIP scan-resistant, which matters a great deal for embedding-table gathers
//  that sweep through far more data than the cache can hold.
//
//  Victim selection here finds the way holding the largest RRPV and then ages
//  the whole set so that the victim sits exactly at the maximum.  That is
//  algebraically identical to the textbook "increment every RRPV until some
//  way reaches 3" loop, but it completes in a single cycle instead of up to
//  three, which keeps the critical path short.
//
//  PF_INSERT_DISTANT is part of Innovation 2 (pollution control): a line
//  brought in speculatively by the prefetcher is inserted at RRPV 3 rather
//  than 2, so an incorrect prefetch is the first thing evicted and therefore
//  costs almost nothing. A demand line keeps the normal insertion point.
// ============================================================================
`default_nettype none

module repl_policy #(
  parameter int NUM_SETS          = 64,
  parameter int NUM_WAYS          = 4,
  parameter int POLICY            = 2,
  parameter bit PF_INSERT_DISTANT = 1'b1
)(
  input  wire                            clk,
  input  wire                            rst_n,

  // ---- Victim query port A: the demand lookup
  input  wire  [$clog2(NUM_SETS)-1:0]    q_set,
  input  wire  [NUM_WAYS-1:0]            q_valid,    // valid bits of that set
  output logic [$clog2(NUM_WAYS)-1:0]    q_victim,

  // ---- Victim query port B: the prefetch fill unit's probe.
  //      Both ports are pure combinational reads of the same metadata, so the
  //      second one costs only a duplicated comparator tree -- no extra state.
  input  wire  [$clog2(NUM_SETS)-1:0]    q2_set,
  input  wire  [NUM_WAYS-1:0]            q2_valid,
  output logic [$clog2(NUM_WAYS)-1:0]    q2_victim,

  // ---- Metadata update (single port, arbitrated by the cache controller)
  input  wire                            upd_en,
  input  wire  [$clog2(NUM_SETS)-1:0]    upd_set,
  input  wire  [$clog2(NUM_WAYS)-1:0]    upd_way,
  input  wire                            upd_hit,    // 1 = promote, 0 = insert
  input  wire                            upd_is_pf,  // insert came from prefetch

  // ---- Observability
  output logic [9:0]                     psel_o      // DRRIP duelling counter
);

  localparam int IDX_W    = $clog2(NUM_SETS);
  localparam int WAY_W    = $clog2(NUM_WAYS);
  localparam int RRPV_W   = 2;
  localparam logic [RRPV_W-1:0] RRPV_MAX  = 2'd3;  // distant  / eviction candidate
  localparam logic [RRPV_W-1:0] RRPV_LONG = 2'd2;  // SRRIP insertion point
  localparam logic [RRPV_W-1:0] RRPV_NEAR = 2'd0;  // promoted on hit

  // --------------------------------------------------------------------------
  //  State
  // --------------------------------------------------------------------------
  logic [RRPV_W-1:0] rrpv [NUM_SETS][NUM_WAYS];  // used by SRRIP / DRRIP
  logic [WAY_W-1:0]  age  [NUM_SETS][NUM_WAYS];  // used by LRU (0 = MRU)
  logic [9:0]        psel;                       // 10-bit, saturating
  logic [4:0]        lfsr;                       // BRRIP 1/32 bimodal insert

  assign psel_o = psel;

  // --------------------------------------------------------------------------
  //  Set-duelling: a handful of leader sets permanently run one policy each,
  //  and PSEL tracks which leader group is taking fewer misses.  Followers
  //  then adopt the winner.  With 64 sets this dedicates 4 sets to SRRIP and
  //  4 to BRRIP, leaving 56 followers.
  // --------------------------------------------------------------------------
  logic is_srrip_leader, is_brrip_leader, follower_uses_brrip;

  assign is_srrip_leader     = (upd_set[3:0] == 4'd0);
  assign is_brrip_leader     = (upd_set[3:0] == 4'd1);
  assign follower_uses_brrip = psel[9];  // PSEL high => SRRIP is losing

  // --------------------------------------------------------------------------
  //  Victim selection
  //  1. An invalid way is always the cheapest victim, so take it first.
  //  2. Otherwise pick the way with the largest RRPV (LRU: largest age).
  //     The loop runs downwards so the lowest way index wins a tie, which
  //     makes the choice deterministic and therefore reproducible in sim.
  // --------------------------------------------------------------------------
  function automatic [WAY_W-1:0] pick_victim (
      input logic [IDX_W-1:0]    s,
      input logic [NUM_WAYS-1:0] v);
    logic              has_invalid;
    logic [WAY_W-1:0]  inv_way, max_way, old_way;
    logic [RRPV_W-1:0] max_val;
    begin
      // 1. An invalid way is free -- always take it first.
      has_invalid = 1'b0;
      inv_way     = '0;
      for (int k = NUM_WAYS-1; k >= 0; k--)
        if (!v[k]) begin
          has_invalid = 1'b1;
          inv_way     = k[WAY_W-1:0];
        end

      // 2a. RRIP candidate: the largest RRPV in the set.
      max_val = '0;
      max_way = '0;
      for (int k = NUM_WAYS-1; k >= 0; k--)
        if (rrpv[s][k] >= max_val) begin
          max_val = rrpv[s][k];
          max_way = k[WAY_W-1:0];
        end

      // 2b. LRU candidate: age == NUM_WAYS-1 is least recently used.
      old_way = '0;
      for (int k = NUM_WAYS-1; k >= 0; k--)
        if (age[s][k] == WAY_W'(NUM_WAYS-1)) old_way = k[WAY_W-1:0];

      if      (has_invalid)  pick_victim = inv_way;
      else if (POLICY == 0)  pick_victim = old_way;
      else                   pick_victim = max_way;
    end
  endfunction

  assign q_victim  = pick_victim(q_set,  q_valid);
  assign q2_victim = pick_victim(q2_set, q2_valid);

  // --------------------------------------------------------------------------
  //  Insertion RRPV for the update port
  // --------------------------------------------------------------------------
  logic              use_brrip;
  logic [RRPV_W-1:0] brrip_val, ins_val;

  // BRRIP inserts at "distant" almost always, dropping to "long" 1 time in 32.
  // That is what makes it survive a scan: nearly every new line is marked as
  // disposable, so a long streaming sweep cannot flush the lines that do get
  // re-used.
  assign brrip_val = (lfsr == 5'd0) ? RRPV_LONG : RRPV_MAX;

  always_comb begin
    if (POLICY == 2) begin
      if      (is_srrip_leader) use_brrip = 1'b0;
      else if (is_brrip_leader) use_brrip = 1'b1;
      else                      use_brrip = follower_uses_brrip;
    end else begin
      use_brrip = 1'b0;             // SRRIP only
    end

    ins_val = use_brrip ? brrip_val : RRPV_LONG;

    // Innovation 2: speculative lines are inserted as disposable.
    if (PF_INSERT_DISTANT && upd_is_pf) ins_val = RRPV_MAX;
  end

  // --------------------------------------------------------------------------
  //  Ageing amount for the updated set: shift everything up so the way we are
  //  about to evict would have been sitting exactly at RRPV_MAX.
  // --------------------------------------------------------------------------
  logic [RRPV_W-1:0] u_maxv, age_delta;

  always_comb begin
    u_maxv = '0;
    for (int k = 0; k < NUM_WAYS; k++)
      if (rrpv[upd_set][k] > u_maxv) u_maxv = rrpv[upd_set][k];
    age_delta = RRPV_MAX - u_maxv;
  end

  // --------------------------------------------------------------------------
  //  Sequential update
  // --------------------------------------------------------------------------
  logic [WAY_W-1:0] old_age;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int s = 0; s < NUM_SETS; s++) begin
        for (int w = 0; w < NUM_WAYS; w++) begin
          rrpv[s][w] <= RRPV_MAX;         // empty lines are maximally disposable
          age [s][w] <= w[WAY_W-1:0];     // seed a valid age permutation
        end
      end
      psel <= 10'd512;                    // neutral: neither policy favoured
      lfsr <= 5'h1F;
    end else begin
      // 5-bit maximal-length LFSR (x^5 + x^3 + 1) for the BRRIP coin flip
      lfsr <= {lfsr[3:0], lfsr[4] ^ lfsr[2]};

      if (upd_en) begin
        // ---- LRU age permutation -----------------------------------------
        if (POLICY == 0) begin
          old_age = age[upd_set][upd_way];
          for (int k = 0; k < NUM_WAYS; k++)
            if (age[upd_set][k] < old_age)
              age[upd_set][k] <= age[upd_set][k] + 1'b1;
          age[upd_set][upd_way] <= '0;    // becomes MRU
        end

        // ---- RRIP ---------------------------------------------------------
        if (POLICY != 0) begin
          if (upd_hit) begin
            rrpv[upd_set][upd_way] <= RRPV_NEAR;
          end else begin
            for (int k = 0; k < NUM_WAYS; k++)
              rrpv[upd_set][k] <= rrpv[upd_set][k] + age_delta;
            // Later non-blocking assignment to the same element wins, so the
            // freshly installed way lands on its insertion value, not the aged
            // one.
            rrpv[upd_set][upd_way] <= ins_val;
          end
        end

        // ---- PSEL: only leader-set misses move the duelling counter -------
        if ((POLICY == 2) && !upd_hit) begin
          if (is_srrip_leader && (psel != 10'd1023)) psel <= psel + 1'b1;
          if (is_brrip_leader && (psel != 10'd0   )) psel <= psel - 1'b1;
        end
      end
    end
  end

endmodule

`default_nettype wire
