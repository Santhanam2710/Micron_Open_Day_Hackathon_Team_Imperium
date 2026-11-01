// ============================================================================
//  cache_controller.sv -- Set-associative cache with a non-blocking prefetch
//                         path (prefetch MSHR file)
// ----------------------------------------------------------------------------
//  STORAGE SPLIT
//  Tag, valid, dirty and prefetch-bit arrays are flip-flops: for 64 sets x 4
//  ways that is about 6 kbit, all four ways compare in one cycle with no array
//  latency, and extra combinational read ports for the prefetch logic are
//  free.  The data array is a synchronous-read memory so it maps onto FPGA
//  block RAM -- 16 KiB of cache data in flip-flops would need ~131 k registers
//  and would not fit in any student-class device.  The split is a requirement,
//  not a preference.
//
//  DEMAND TIMING
//  The data array read is launched in the cycle the request is accepted, so
//  tag comparison and data availability coincide one cycle later.  A read hit
//  answers in that cycle, and because ready is re-asserted while answering,
//  back-to-back read hits sustain one access per cycle.  A write hit needs the
//  array's write port, so ready drops for that one cycle: a synchronous memory
//  read launched in the same cycle as a write to the same row returns
//  pre-write data, and delaying acceptance by a cycle is far cheaper to trust
//  than a bypass network.
//
//  WHY THE PREFETCH PATH IS SEPARATE, AND WHY IT HAS MULTIPLE SLOTS
//  Two measured failures drove this structure, and both are worth stating
//  because they are the real engineering content of the project.
//
//  First, the prefetch queue was originally drained by the demand FSM whenever
//  the cache was idle.  Under a saturated access stream the cache is never
//  idle, so almost nothing was ever prefetched.  A blocking cache with one
//  miss slot cannot prefetch at all, however good its predictors are.
//
//  Second, giving prefetch its own single slot fixed accuracy but not
//  performance: misses on the streaming trace fell from 1250 to 2 and the
//  cycle count got slightly WORSE.  The prefetcher was only ever one or two
//  lines ahead, while a fetch costs ~100 cycles and the demand stream consumes
//  a line every ~16.  Every demand request caught up with the prefetch that
//  was fetching its line and waited for it, so a 103-cycle miss simply became
//  a 100-cycle merge wait.  Perfect prediction, zero benefit.  Accuracy
//  without TIMELINESS buys nothing.
//
//  Timeliness needs depth, so the prefetch path below is a small MSHR file:
//  PF_MSHR independent slots, each able to have a line in flight, tagged with
//  a request ID so responses can be matched.  With PF_MSHR slots and a
//  pipelined memory the prefetcher sustains PF_MSHR lines per memory latency,
//  which is what lets it get and stay far enough ahead.
//
//  Three further consequences, all measured rather than asserted:
//    * LATE-PREFETCH MERGE -- a demand miss on a line already in flight waits
//      for that fill instead of issuing a duplicate fetch, so it pays only the
//      remainder of the latency.  st_pf_merge_cycles counts it.
//    * INTERFERENCE -- st_pf_interf_cycles counts cycles where a demand miss
//      could not issue because memory was full of prefetch traffic, so the
//      report can state the price of speculation instead of pretending there
//      isn't one.
//    * NO DUPLICATE TAGS -- at most one in-flight prefetch per set, no
//      prefetch into a set with an outstanding demand miss, and a fresh tag
//      and victim probe at fill time.  Together these make it impossible to
//      install one line into two ways, or to overwrite a line the demand path
//      has reserved.
//
//  REPLACEMENT METADATA FOR PREFETCHED LINES
//  The replacement block has one update port and the demand path owns it.  A
//  prefetch fill that cannot get the port simply does not update, so the new
//  line inherits the victim's metadata position -- the evicted-soonest slot.
//  The failure mode of the arbitration is itself the insert-distant policy, so
//  a speculative line is never more protected than the line it displaced.
//
//  PREFETCH ACCOUNTING (the feedback that drives Innovation 2)
//    pf_bit set                      line installed speculatively, not yet used
//    demand hit on a pf_bit line  -> useful,  bit cleared
//    pf_bit line evicted untouched -> useless
// ============================================================================
`default_nettype none

module cache_controller #(
  parameter int ADDR_W            = 32,
  parameter int DATA_W            = 32,
  parameter int LINE_BYTES        = 64,
  parameter int NUM_SETS          = 64,
  parameter int NUM_WAYS          = 4,
  parameter int POLICY            = 2,
  parameter bit PF_INSERT_DISTANT = 1'b1,
  parameter int PF_MSHR           = 16,
  parameter int MEM_ID_W          = 5
)(
  input  wire                     clk,
  input  wire                     rst_n,

  // ---- CPU / workload port
  input  wire                     cpu_vld,
  input  wire                     cpu_we,
  input  wire  [ADDR_W-1:0]       cpu_addr,
  input  wire  [DATA_W-1:0]       cpu_wdata,
  output logic                    cpu_rdy,
  output logic                    cpu_rvld,
  output logic [DATA_W-1:0]       cpu_rdata,

  // ---- Prefetch request port (from the pf_engine queue)
  input  wire                     pf_vld,
  input  wire  [ADDR_W-1:0]       pf_addr,
  input wire [9:0]                pf_meta,
  output logic                    pf_take,

  // ---- Demand access stream out (prefetcher training / trigger)
  output logic                    acc_vld,
  output logic [ADDR_W-1:0]       acc_addr,

  // ---- Prefetch outcome feedback out
  output logic                    fb_useful,
  output logic                    fb_useless,
  output logic [9:0] fb_useful_meta, fb_useless_meta,

  // ---- Memory port
  output logic                    mem_req,
  output logic                    mem_we,
  output logic [MEM_ID_W-1:0]     mem_id,
  output logic [ADDR_W-1:0]       mem_addr,
  output logic [LINE_BYTES*8-1:0] mem_wdata,
  input  wire                     mem_gnt,
  input  wire                     mem_resp_vld,
  input  wire  [MEM_ID_W-1:0]     mem_resp_id,
  input  wire                     mem_resp_is_write,
  input  wire  [LINE_BYTES*8-1:0] mem_resp_data,

  // ---- Statistics
  output logic [31:0]             st_dem_acc,
  output logic [31:0]             st_dem_hit,
  output logic [31:0]             st_dem_miss,
  output logic [31:0]             st_dem_lat_acc,
  output logic [31:0]             st_pf_probe,
  output logic [31:0]             st_pf_probe_hit,
  output logic [31:0]             st_pf_fill,
  output logic [31:0]             st_pf_useful,
  output logic [31:0]             st_pf_useless,
  output logic [31:0]             st_pf_drop_dirty,
  output logic [31:0]             st_pf_drop_conflict,
  output logic [31:0]             st_pf_drop_inflight,
  output logic [31:0]             st_pf_drop_nomshr,
  output logic [31:0]             st_pf_drop_late,
  output logic [31:0]             st_pf_merge_cycles,
  output logic [31:0]             st_pf_interf_cycles,
  output logic [31:0]             st_writeback
);

  // --------------------------------------------------------------------------
  //  Derived geometry
  // --------------------------------------------------------------------------
  localparam int LINE_W    = LINE_BYTES * 8;
  localparam int LOG2_LINE = $clog2(LINE_BYTES);
  localparam int IDX_W     = $clog2(NUM_SETS);
  localparam int WAY_W     = $clog2(NUM_WAYS);
  localparam int TAG_W     = ADDR_W - IDX_W - LOG2_LINE;
  localparam int LOG2_WB   = $clog2(DATA_W / 8);
  localparam int WSEL_W    = LOG2_LINE - LOG2_WB;
  localparam int SLOT_W    = (PF_MSHR <= 1) ? 1 : $clog2(PF_MSHR);

  // --------------------------------------------------------------------------
  //  Arrays
  // --------------------------------------------------------------------------
  logic [TAG_W-1:0] tag_a [NUM_SETS][NUM_WAYS];
  logic             vld_a [NUM_SETS][NUM_WAYS];
  logic             drt_a [NUM_SETS][NUM_WAYS];
  logic             pfb_a [NUM_SETS][NUM_WAYS];
  logic [9:0] ml_meta_a [NUM_SETS][NUM_WAYS];
  logic [9:0] pm_meta [PF_MSHR];
  logic [9:0] p_meta;

  (* ramstyle = "M10K, no_rw_check" *)
  logic [LINE_W-1:0] data_mem [NUM_SETS][NUM_WAYS];

  logic [LINE_W-1:0] rd_line [NUM_WAYS];

  // --------------------------------------------------------------------------
  //  Demand request state
  // --------------------------------------------------------------------------
  logic [ADDR_W-1:0] req_addr;
  logic              req_we;
  logic [DATA_W-1:0] req_wdata;

  logic [TAG_W-1:0]  req_tag;
  logic [IDX_W-1:0]  req_idx;
  logic [WSEL_W-1:0] req_wsel;
  logic [ADDR_W-LOG2_LINE-1:0] req_line;

  assign req_tag  = req_addr[ADDR_W-1 -: TAG_W];
  assign req_idx  = req_addr[IDX_W+LOG2_LINE-1 : LOG2_LINE];
  assign req_wsel = req_addr[LOG2_LINE-1 : LOG2_WB];
  assign req_line = req_addr[ADDR_W-1 : LOG2_LINE];

  // --------------------------------------------------------------------------
  //  FSM declarations
  // --------------------------------------------------------------------------
  typedef enum logic [2:0] {
    S_IDLE   = 3'd0,
    S_LOOKUP = 3'd1,
    S_WB     = 3'd2,
    S_FETCH  = 3'd3,
    S_FILL   = 3'd4,
    S_RESP   = 3'd5
  } state_e;

  typedef enum logic [0:0] { P_IDLE = 1'd0, P_PROBE = 1'd1 } pstate_e;

  state_e  state;
  pstate_e p_state;

  logic [LINE_W-1:0] line_buf;
  logic [DATA_W-1:0] resp_word;
  logic [WAY_W-1:0]  victim_r;
  logic              d_sent;        // demand request accepted by memory

  // --------------------------------------------------------------------------
  //  Prefetch probe register
  // --------------------------------------------------------------------------
  logic [ADDR_W-1:0] p_addr;
  logic [TAG_W-1:0]  p_tag;
  logic [IDX_W-1:0]  p_idx;

  assign p_tag = p_addr[ADDR_W-1 -: TAG_W];
  assign p_idx = p_addr[IDX_W+LOG2_LINE-1 : LOG2_LINE];

  // --------------------------------------------------------------------------
  //  Prefetch MSHR file
  // --------------------------------------------------------------------------
  logic              pm_busy   [PF_MSHR];   // slot holds an in-flight prefetch
  logic              pm_filled [PF_MSHR];   // data arrived, awaiting install
  logic [ADDR_W-1:0] pm_addr   [PF_MSHR];
  logic [LINE_W-1:0] pm_line   [PF_MSHR];

  // --------------------------------------------------------------------------
  //  Tag comparison -- demand port
  // --------------------------------------------------------------------------
  logic [NUM_WAYS-1:0] way_hit, set_valid;
  logic                hit_any;
  logic [WAY_W-1:0]    hit_way;

  always_comb begin
    for (int w = 0; w < NUM_WAYS; w++) begin
      way_hit[w]   = vld_a[req_idx][w] && (tag_a[req_idx][w] == req_tag);
      set_valid[w] = vld_a[req_idx][w];
    end
    hit_any = |way_hit;
    hit_way = '0;
    for (int w = NUM_WAYS-1; w >= 0; w--)
      if (way_hit[w]) hit_way = w[WAY_W-1:0];
  end

  // --------------------------------------------------------------------------
  //  Tag comparison -- prefetch probe port (free: the tags are registers)
  // --------------------------------------------------------------------------
  logic p_hit_any;
  always_comb begin
    p_hit_any = 1'b0;
    for (int w = 0; w < NUM_WAYS; w++)
      if (vld_a[p_idx][w] && (tag_a[p_idx][w] == p_tag)) p_hit_any = 1'b1;
  end

  // --------------------------------------------------------------------------
  //  Demand miss in progress?  Used by every prefetch-side hazard check.
  // --------------------------------------------------------------------------
  logic d_miss_busy;
  assign d_miss_busy = ((state == S_LOOKUP) && !hit_any) ||
                        (state == S_WB) || (state == S_FETCH) || (state == S_FILL);

  // --------------------------------------------------------------------------
  //  MSHR selection: a free slot to allocate, and a filled slot to install
  // --------------------------------------------------------------------------
  logic              free_vld;
  logic [SLOT_W-1:0] free_sel;

  always_comb begin
    free_vld = 1'b0;
    free_sel = '0;
    for (int i = PF_MSHR-1; i >= 0; i--)
      if (!pm_busy[i]) begin
        free_vld = 1'b1;
        free_sel = i[SLOT_W-1:0];
      end
  end

  // A slot is installable unless the demand path owns its set for a different
  // line.  Excluding the same-line case is what prevents deadlock: a demand
  // miss parked waiting for a late prefetch must not block the very fill it is
  // waiting for.
  logic              fill_vld;
  logic [SLOT_W-1:0] fill_sel;

  logic [IDX_W-1:0] fv_idx;
  logic             fv_same_line, fv_blocked;

  always_comb begin
    fill_vld = 1'b0;
    fill_sel = '0;
    for (int i = PF_MSHR-1; i >= 0; i--) begin
      fv_idx       = pm_addr[i][IDX_W+LOG2_LINE-1 : LOG2_LINE];
      fv_same_line = (pm_addr[i][ADDR_W-1:LOG2_LINE] == req_line);
      fv_blocked   = (fv_idx == req_idx) && d_miss_busy && !fv_same_line;
      if (pm_filled[i] && !fv_blocked) begin
        fill_vld = 1'b1;
        fill_sel = i[SLOT_W-1:0];
      end
    end
  end

  logic [ADDR_W-1:0] f_addr;
  logic [TAG_W-1:0]  f_tag;
  logic [IDX_W-1:0]  f_idx;
  logic [LINE_W-1:0] f_line;

  assign f_addr = pm_addr[fill_sel];
  assign f_tag  = f_addr[ADDR_W-1 -: TAG_W];
  assign f_idx  = f_addr[IDX_W+LOG2_LINE-1 : LOG2_LINE];
  assign f_line = pm_line[fill_sel];

  // Fresh tag probe at install time: between allocation and data return the
  // line may have arrived by another route, in which case installing it again
  // would create a duplicate tag.
  logic                f_hit_any;
  logic [NUM_WAYS-1:0] f_set_valid;
  always_comb begin
    f_hit_any = 1'b0;
    for (int w = 0; w < NUM_WAYS; w++) begin
      f_set_valid[w] = vld_a[f_idx][w];
      if (vld_a[f_idx][w] && (tag_a[f_idx][w] == f_tag)) f_hit_any = 1'b1;
    end
  end

  // At most one in-flight prefetch per set, so two slots can never race for
  // the same victim way.
  logic pm_same_set_as_probe, pm_same_line_as_probe, pm_match_demand;
  always_comb begin
    pm_same_set_as_probe  = 1'b0;
    pm_same_line_as_probe = 1'b0;
    pm_match_demand       = 1'b0;
    for (int i = 0; i < PF_MSHR; i++) begin
      if (pm_busy[i]) begin
        if (pm_addr[i][IDX_W+LOG2_LINE-1 : LOG2_LINE] == p_idx)
          pm_same_set_as_probe = 1'b1;
        if (pm_addr[i][ADDR_W-1:LOG2_LINE] == p_addr[ADDR_W-1:LOG2_LINE])
          pm_same_line_as_probe = 1'b1;
        if (pm_addr[i][ADDR_W-1:LOG2_LINE] == req_line)
          pm_match_demand = 1'b1;
      end
    end
  end

  // --------------------------------------------------------------------------
  //  Replacement policy: demand victim query + prefetch-install victim query
  // --------------------------------------------------------------------------
  logic [WAY_W-1:0] victim_way, f_victim_way;
  logic             repl_upd_en, repl_upd_hit, repl_upd_is_pf;
  logic [IDX_W-1:0] repl_upd_set;
  logic [WAY_W-1:0] repl_upd_way;
  logic [9:0]       psel_dbg;

  logic             d_repl_upd_en, d_repl_upd_hit;
  logic [WAY_W-1:0] d_repl_upd_way;
  logic             p_repl_upd_en;
  logic [IDX_W-1:0] p_repl_upd_set;
  logic [WAY_W-1:0] p_repl_upd_way;

  // Demand owns the update port; a prefetch install updates only when the port
  // is free.  Losing the arbitration leaves the new line in the victim's slot,
  // which is exactly the insert-distant behaviour we want for speculation.
  always_comb begin
    repl_upd_en    = d_repl_upd_en || p_repl_upd_en;
    repl_upd_set   = d_repl_upd_en ? req_idx        : p_repl_upd_set;
    repl_upd_way   = d_repl_upd_en ? d_repl_upd_way : p_repl_upd_way;
    repl_upd_hit   = d_repl_upd_en ? d_repl_upd_hit : 1'b0;
    repl_upd_is_pf = !d_repl_upd_en && p_repl_upd_en;
  end

  repl_policy #(
    .NUM_SETS(NUM_SETS), .NUM_WAYS(NUM_WAYS),
    .POLICY(POLICY), .PF_INSERT_DISTANT(PF_INSERT_DISTANT)
  ) u_repl (
    .clk, .rst_n,
    .q_set    (req_idx),
    .q_valid  (set_valid),
    .q_victim (victim_way),
    .q2_set   (f_idx),
    .q2_valid (f_set_valid),
    .q2_victim(f_victim_way),
    .upd_en   (repl_upd_en),
    .upd_set  (repl_upd_set),
    .upd_way  (repl_upd_way),
    .upd_hit  (repl_upd_hit),
    .upd_is_pf(repl_upd_is_pf),
    .psel_o   (psel_dbg)
  );

  // --------------------------------------------------------------------------
  //  Handshake
  // --------------------------------------------------------------------------
  logic read_hit_now, write_hit_now, wb_refresh;

  assign read_hit_now  = (state == S_LOOKUP) && hit_any && !req_we;
  assign write_hit_now = (state == S_LOOKUP) && hit_any &&  req_we;

  assign cpu_rdy = (state == S_IDLE) || (state == S_RESP) || read_hit_now;

  logic latch_demand;
  assign latch_demand = cpu_rdy && cpu_vld;

  logic [IDX_W-1:0] new_idx;
  assign new_idx = cpu_addr[IDX_W+LOG2_LINE-1 : LOG2_LINE];

  // --------------------------------------------------------------------------
  //  Response
  // --------------------------------------------------------------------------
  logic [DATA_W-1:0] hit_word;
  assign hit_word  = rd_line[hit_way][req_wsel*DATA_W +: DATA_W];
  assign cpu_rvld  = read_hit_now || write_hit_now || (state == S_RESP);
  assign cpu_rdata = (state == S_RESP) ? resp_word : hit_word;

  // --------------------------------------------------------------------------
  //  Array write-port arbitration: demand first, then a prefetch install
  // --------------------------------------------------------------------------
  logic arrays_busy_demand, pf_install_go;
  assign arrays_busy_demand = write_hit_now || (state == S_FILL);

  // A miss is being declared this cycle and will proceed to a fetch (possibly
  // via a write-back), so refresh the data snapshot from the array.
  assign wb_refresh = (state == S_LOOKUP) && !hit_any && !pm_match_demand;
  assign pf_install_go      = fill_vld && !arrays_busy_demand;

  // --------------------------------------------------------------------------
  //  Memory request arbitration (demand priority, one request per cycle)
  // --------------------------------------------------------------------------
  logic probe_ok, d_need, p_need;

  assign probe_ok = (p_state == P_PROBE) && !p_hit_any &&
                    !((p_idx == req_idx) && d_miss_busy) &&
                    !pm_same_set_as_probe && free_vld;

  assign d_need = ((state == S_WB) || (state == S_FETCH)) && !d_sent;
  assign p_need = probe_ok;

  // Write-back data is taken from a snapshot refreshed at the miss cycle (see
  // the wb_refresh comment in the sequential block), not from the snapshot
  // captured when the request was accepted.
  logic [ADDR_W-1:0] victim_addr, req_line_addr, p_line_addr;
  assign victim_addr   = {tag_a[req_idx][victim_r], req_idx, {LOG2_LINE{1'b0}}};
  assign req_line_addr = {req_addr[ADDR_W-1:LOG2_LINE], {LOG2_LINE{1'b0}}};
  assign p_line_addr   = {p_addr  [ADDR_W-1:LOG2_LINE], {LOG2_LINE{1'b0}}};

  always_comb begin
    mem_req   = d_need || p_need;
    mem_we    = d_need && (state == S_WB);
    mem_wdata = rd_line[victim_r];
    if (d_need) begin
      mem_id   = '0;                                       // ID 0 = demand
      mem_addr = (state == S_WB) ? victim_addr : req_line_addr;
    end else begin
      mem_id   = MEM_ID_W'(free_sel) + MEM_ID_W'(1);       // 1..PF_MSHR
      mem_addr = p_line_addr;
    end
  end

  logic              d_resp_rd, d_resp_wr, p_resp;
  logic [SLOT_W-1:0] p_resp_slot;

  assign d_resp_rd   = mem_resp_vld && (mem_resp_id == '0) && !mem_resp_is_write;
  assign d_resp_wr   = mem_resp_vld && (mem_resp_id == '0) &&  mem_resp_is_write;
  assign p_resp      = mem_resp_vld && (mem_resp_id != '0);

  logic [MEM_ID_W-1:0] p_resp_id_m1;
  assign p_resp_id_m1 = mem_resp_id - MEM_ID_W'(1);
  assign p_resp_slot  = p_resp_id_m1[SLOT_W-1:0];

  // --------------------------------------------------------------------------
  //  Fill data (merge a pending store into the fetched line)
  // --------------------------------------------------------------------------
  logic [LINE_W-1:0] fill_line;
  always_comb begin
    fill_line = line_buf;
    if (req_we) fill_line[req_wsel*DATA_W +: DATA_W] = req_wdata;
  end

  // --------------------------------------------------------------------------
  //  Sequential: both FSMs, the MSHR file and every array write live in one
  //  block so that each array has exactly one driver.
  // --------------------------------------------------------------------------
  logic dem_busy;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state     <= S_IDLE;
      p_state   <= P_IDLE;
      req_addr  <= '0;  req_we    <= 1'b0;  req_wdata <= '0;
      p_addr    <= '0;  line_buf  <= '0;    resp_word <= '0;
      victim_r  <= '0;  d_sent    <= 1'b0;  dem_busy  <= 1'b0;
      acc_vld   <= 1'b0; pf_take  <= 1'b0;
      fb_useful <= 1'b0; fb_useless <= 1'b0;
      fb_useful_meta <= '0; fb_useless_meta <= '0; p_meta <= '0;
      d_repl_upd_en <= 1'b0; d_repl_upd_hit <= 1'b0; d_repl_upd_way <= '0;
      p_repl_upd_en <= 1'b0; p_repl_upd_set <= '0;   p_repl_upd_way <= '0;
      st_dem_acc <= '0; st_dem_hit <= '0; st_dem_miss <= '0;
      st_dem_lat_acc <= '0; st_writeback <= '0;
      st_pf_probe <= '0; st_pf_probe_hit <= '0; st_pf_fill <= '0;
      st_pf_useful <= '0; st_pf_useless <= '0;
      st_pf_drop_dirty <= '0; st_pf_drop_conflict <= '0;
      st_pf_drop_inflight <= '0;
      st_pf_drop_nomshr <= '0; st_pf_drop_late <= '0;
      st_pf_merge_cycles <= '0; st_pf_interf_cycles <= '0;
      for (int i = 0; i < PF_MSHR; i++) begin
        pm_busy[i]   <= 1'b0;
        pm_filled[i] <= 1'b0;
        pm_addr[i]   <= '0;
        pm_meta[i] <= '0;
      end
      for (int s = 0; s < NUM_SETS; s++) begin
        for (int w = 0; w < NUM_WAYS; w++) begin
          tag_a[s][w] <= '0;
          vld_a[s][w] <= 1'b0;
          drt_a[s][w] <= 1'b0;
          pfb_a[s][w] <= 1'b0;
          ml_meta_a[s][w] <= '0;
        end
      end
    end else begin
      // ---- one-cycle pulses default low ----------------------------------
      fb_useful     <= 1'b0;
      fb_useless    <= 1'b0;
      pf_take       <= 1'b0;
      d_repl_upd_en <= 1'b0;
      p_repl_upd_en <= 1'b0;

      // The training pulse fires exactly once per demand access, in the cycle
      // the request reaches S_LOOKUP.  Deriving it from the state would fire
      // repeatedly whenever a lookup stalls waiting for a merge.
      acc_vld <= latch_demand;

      // ---- demand occupancy, for the AMAT figure -------------------------
      if (latch_demand)  dem_busy <= 1'b1;
      else if (cpu_rvld) dem_busy <= 1'b0;
      if (dem_busy || latch_demand) st_dem_lat_acc <= st_dem_lat_acc + 1'b1;

      // ---- the price of speculation: demand blocked out of memory --------
      if (d_need && !mem_gnt) st_pf_interf_cycles <= st_pf_interf_cycles + 1'b1;

      // ======================================================================
      //  Data array: synchronous read of every way at the incoming index.
      //  A prefetch installing into the same set in this very cycle would not
      //  be visible to that read, so bypass it -- and also patch the existing
      //  snapshot when the demand path is parked in S_LOOKUP waiting for
      //  exactly that install.
      // ======================================================================
      if (latch_demand) begin
        for (int w = 0; w < NUM_WAYS; w++)
          rd_line[w] <= data_mem[new_idx][w];
        if (pf_install_go && !f_hit_any && (f_idx == new_idx))
          rd_line[f_victim_way] <= f_line;
      end else if (wb_refresh) begin
        // A miss is being declared, and the next state may be a write-back
        // whose data comes from this snapshot.  Re-read it now.
        //
        // This line fixes a real data-corruption bug.  The snapshot is taken
        // when the request is ACCEPTED, but a lookup can sit in S_LOOKUP for
        // a long time (waiting on a late prefetch), and the snapshot can be
        // patched by a prefetch install in the meantime.  Writing back a
        // stale or patched snapshot sends one line's data to another line's
        // address -- and because both lines map to the same set, the symptom
        // was a later read of line 0 returning line 256's contents.  Nothing
        // in the cache looked wrong; only the self-checking testbench caught
        // it.  Re-reading here makes the write-back depend on the array at
        // eviction time, which is the only snapshot that can be correct.
        //
        // No extra memory port is needed: a miss forces ready low, so no
        // request is being accepted in this cycle and the read port is free.
        for (int w = 0; w < NUM_WAYS; w++)
          rd_line[w] <= data_mem[req_idx][w];
      end else if (pf_install_go && !f_hit_any && (f_idx == req_idx)) begin
        rd_line[f_victim_way] <= f_line;
      end

      // ---- demand request latch ------------------------------------------
      if (latch_demand) begin
        req_addr   <= cpu_addr;
        req_we     <= cpu_we;
        req_wdata  <= cpu_wdata;
        st_dem_acc <= st_dem_acc + 1'b1;
      end

      // ======================================================================
      //  Memory request acceptance
      // ======================================================================
      if (mem_req && mem_gnt) begin
        if (d_need) begin
          d_sent <= 1'b1;
        end else begin
          pm_busy[free_sel]   <= 1'b1;
          pm_filled[free_sel] <= 1'b0;
          pm_addr[free_sel]   <= p_addr;
          pm_meta[free_sel] <= p_meta;
        end
      end

      // ======================================================================
      //  Memory responses
      // ======================================================================
      if (p_resp) begin
        pm_line[p_resp_slot]   <= mem_resp_data;
        pm_filled[p_resp_slot] <= 1'b1;
      end

      // ======================================================================
      //  Demand FSM
      // ======================================================================
      case (state)
        S_IDLE: begin
          if (latch_demand) state <= S_LOOKUP;
        end

        S_LOOKUP: begin
          if (hit_any) begin
            st_dem_hit     <= st_dem_hit + 1'b1;
            d_repl_upd_en  <= 1'b1;
            d_repl_upd_way <= hit_way;
            d_repl_upd_hit <= 1'b1;

            // A speculative line that just got used: credit it once, then
            // treat it as an ordinary resident line.
            if (pfb_a[req_idx][hit_way]) begin
              pfb_a[req_idx][hit_way] <= 1'b0;
              st_pf_useful <= st_pf_useful + 1'b1;
              fb_useful    <= 1'b1;
              fb_useful_meta <= ml_meta_a[req_idx][hit_way];
            end

            if (req_we) begin
              data_mem[req_idx][hit_way][req_wsel*DATA_W +: DATA_W] <= req_wdata;
              drt_a[req_idx][hit_way] <= 1'b1;
              state <= S_IDLE;                  // ready was low this cycle
            end else begin
              state <= latch_demand ? S_LOOKUP : S_IDLE;
            end
          end else if (pm_match_demand) begin
            // Late prefetch: this line is already on its way in.  Hold and
            // re-probe rather than duplicating the fetch; the install turns
            // this into a hit and the prefetch is credited as useful.
            st_pf_merge_cycles <= st_pf_merge_cycles + 1'b1;
            state <= S_LOOKUP;
          end else begin
            st_dem_miss <= st_dem_miss + 1'b1;
            victim_r    <= victim_way;
            d_sent      <= 1'b0;
            state <= (vld_a[req_idx][victim_way] && drt_a[req_idx][victim_way])
                     ? S_WB : S_FETCH;
          end
        end

        S_WB: begin
          if (d_resp_wr) begin
            st_writeback <= st_writeback + 1'b1;
            d_sent       <= 1'b0;
            state        <= S_FETCH;
          end
        end

        S_FETCH: begin
          if (d_resp_rd) begin
            line_buf <= mem_resp_data;
            state    <= S_FILL;
          end
        end

        S_FILL: begin
          if (vld_a[req_idx][victim_r] && pfb_a[req_idx][victim_r]) begin
            st_pf_useless <= st_pf_useless + 1'b1;
            fb_useless    <= 1'b1;
            fb_useless_meta <= ml_meta_a[req_idx][victim_r];
          end

          data_mem[req_idx][victim_r] <= fill_line;
          tag_a[req_idx][victim_r]    <= req_tag;
          vld_a[req_idx][victim_r]    <= 1'b1;
          drt_a[req_idx][victim_r]    <= req_we;
          pfb_a[req_idx][victim_r]    <= 1'b0;

          d_repl_upd_en  <= 1'b1;
          d_repl_upd_way <= victim_r;
          d_repl_upd_hit <= 1'b0;

          resp_word <= line_buf[req_wsel*DATA_W +: DATA_W];
          state     <= S_RESP;
        end

        S_RESP: begin
          state <= latch_demand ? S_LOOKUP : S_IDLE;
        end

        default: state <= S_IDLE;
      endcase

      // ======================================================================
      //  Prefetch probe stage.  One request at a time; a request that cannot
      //  be launched is dropped rather than queued, because a prediction that
      //  has to wait is a prediction that is already going stale.
      // ======================================================================
      case (p_state)
        P_IDLE: begin
          if (pf_vld) begin
            p_addr      <= pf_addr;
            p_meta <= pf_meta;
            pf_take     <= 1'b1;
            st_pf_probe <= st_pf_probe + 1'b1;
            p_state     <= P_PROBE;
          end
        end

        P_PROBE: begin
          if (p_hit_any) begin
            // Already resident -- the usual case for a prefetcher that is
            // comfortably ahead of the stream it is chasing.
            st_pf_probe_hit <= st_pf_probe_hit + 1'b1;
            p_state <= P_IDLE;
          end else if (pm_same_line_as_probe) begin
            // The prefetcher is far enough ahead that it is re-predicting a
            // line it already has in flight.  Not an error -- this is what
            // staying ahead of the stream looks like.
            st_pf_drop_inflight <= st_pf_drop_inflight + 1'b1;
            p_state <= P_IDLE;
          end else if (((p_idx == req_idx) && d_miss_busy) ||
                       pm_same_set_as_probe) begin
            st_pf_drop_conflict <= st_pf_drop_conflict + 1'b1;
            p_state <= P_IDLE;
          end else if (!free_vld) begin
            st_pf_drop_nomshr <= st_pf_drop_nomshr + 1'b1;
            p_state <= P_IDLE;
          end else if (mem_gnt && p_need) begin
            p_state <= P_IDLE;          // launched; slot allocated above
          end
          // else: memory refused this cycle -- hold and retry.
        end

        default: p_state <= P_IDLE;
      endcase

      // ======================================================================
      //  Prefetch install stage
      // ======================================================================
      if (pf_install_go) begin
        pm_busy[fill_sel]   <= 1'b0;
        pm_filled[fill_sel] <= 1'b0;

        if (f_hit_any) begin
          // Arrived by another route while this fetch was in flight.
          st_pf_drop_late <= st_pf_drop_late + 1'b1;
        end else if (vld_a[f_idx][f_victim_way] && drt_a[f_idx][f_victim_way]) begin
          // Refuse to let a guess cause a guaranteed extra DRAM write.
          st_pf_drop_dirty <= st_pf_drop_dirty + 1'b1;
        end else begin
          if (vld_a[f_idx][f_victim_way] && pfb_a[f_idx][f_victim_way]) begin
            st_pf_useless <= st_pf_useless + 1'b1;
            fb_useless    <= 1'b1;
            fb_useless_meta <= ml_meta_a[f_idx][f_victim_way];
          end

            ml_meta_a[f_idx][f_victim_way] <= pm_meta[fill_sel];
          data_mem[f_idx][f_victim_way] <= f_line;
          tag_a[f_idx][f_victim_way]    <= f_tag;
          vld_a[f_idx][f_victim_way]    <= 1'b1;
          drt_a[f_idx][f_victim_way]    <= 1'b0;
          pfb_a[f_idx][f_victim_way]    <= 1'b1;   // speculative until used

          p_repl_upd_en  <= 1'b1;                  // granted only if demand idle
          p_repl_upd_set <= f_idx;
          p_repl_upd_way <= f_victim_way;
          st_pf_fill     <= st_pf_fill + 1'b1;
        end
      end
    end
  end

  assign acc_addr = req_addr;

endmodule

`default_nettype wire
