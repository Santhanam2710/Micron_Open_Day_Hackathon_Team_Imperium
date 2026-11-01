// ============================================================================
//  ai_cache_top.sv -- AI-Aware Cache + Multi-Modal Adaptive Prefetcher
// ----------------------------------------------------------------------------
//  This is the synthesisable boundary of the submission.  It contains the
//  cache controller, the replacement policy, the three prefetch engines, the
//  phase detector, the throttle and the arbiter.  Main memory is OUTSIDE this
//  module: the memory port is brought out so that simulation can attach a
//  latency model and Quartus can report the area of the design itself rather
//  than of a fake DRAM.
//
//  Every architectural choice that the report claims to have explored is a
//  parameter here, and every parameter is overridable from the command line.
//  That is what makes the ablation study in scripts/run_sweep.py possible: the
//  same source tree builds the baseline, each individual innovation, and the
//  full design, so the comparison is between identical RTL with one knob moved
//  rather than between hand-edited variants.
//
//  FEATURE FLAGS AND WHICH CLAIM EACH ONE ISOLATES
//    EN_NEXTLINE / EN_STRIDE / EN_DELTA .. Innovation 1 -- does combining
//        three engines beat the best single engine?  Turn them on one at a
//        time, then all together.
//    EN_THROTTLE ......................... Innovation 2 -- does closed-loop
//        aggressiveness control cut pollution and DRAM traffic?
//    EN_PHASE ............................ Innovation 3 -- does classifying
//        the workload phase and gating engines help, especially on irregular
//        traffic?
//    POLICY .............................. L2 replacement study: LRU vs SRRIP
//        vs set-duelling DRRIP.
//    CACHE geometry ...................... L2 design-space exploration.
// ============================================================================
`default_nettype none

module ai_cache_top #(
  // ---- Cache geometry
  parameter bit EN_PERCEPTRON = 1'b0,
  parameter int ML_MARGIN = 16,
  parameter int ML_EXPLORE_LOG2 = 5,
  parameter int ADDR_W            = 32,
  parameter int DATA_W            = 32,
  parameter int LINE_BYTES        = 64,
  parameter int NUM_SETS          = 64,
  parameter int NUM_WAYS          = 4,
  // ---- Replacement
  parameter int POLICY            = 2,       // 0=LRU 1=SRRIP 2=DRRIP
  parameter bit PF_INSERT_DISTANT = 1'b1,    // part of Innovation 2
  // ---- Innovation 1: engines present
  parameter bit EN_NEXTLINE       = 1'b1,
  parameter bit EN_STRIDE         = 1'b1,
  parameter bit EN_DELTA          = 1'b1,
  // ---- Innovation 2: throttle
  parameter bit EN_THROTTLE       = 1'b1,
  parameter int DEGREE_INIT       = 2,
  parameter int DEGREE_MAX        = 8,
  parameter int THR_WINDOW        = 256,
  // ---- Innovation 3: phase detector
  parameter bit EN_PHASE          = 1'b1,
  parameter int PHASE_WINDOW      = 64,
  // ---- Prefetcher structure sizing
  parameter int ST_TABLE          = 16,
  parameter int ST_REGION_LOG2    = 16,
  parameter int DC_TABLE          = 128,
  parameter int DC_HIST           = 6,
  parameter int PF_QUEUE_DEPTH    = 16,
  parameter int PF_FILTER_DEPTH   = 32,
  // ---- Non-blocking prefetch depth (timeliness; see cache_controller header)
  parameter int PF_MSHR           = 16,
  parameter int MEM_ID_W          = 5
)(
  input  wire                     clk,
  input  wire                     rst_n,

  // ---- Workload port
  input  wire                     cpu_vld,
  input  wire                     cpu_we,
  input  wire  [ADDR_W-1:0]       cpu_addr,
  input  wire  [DATA_W-1:0]       cpu_wdata,
  output logic                    cpu_rdy,
  output logic                    cpu_rvld,
  output logic [DATA_W-1:0]       cpu_rdata,

  // ---- Memory port (to DRAM controller).  ID-tagged so that a demand miss
  //      and several prefetches can be outstanding at once.
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

  // ---- Statistics -------------------------------------------------------
  output logic [31:0] st_cycles,
  // cache
  output logic [31:0] st_dem_acc,
  output logic [31:0] st_dem_hit,
  output logic [31:0] st_dem_miss,
  output logic [31:0] st_dem_lat_acc,
  output logic [31:0] st_writeback,
  // prefetch service
  output logic [31:0] st_pf_probe,
  output logic [31:0] st_pf_probe_hit,
  output logic [31:0] st_pf_fill,
  output logic [31:0] st_pf_useful,
  output logic [31:0] st_pf_useless,
  output logic [31:0] st_pf_drop_dirty,
  output logic [31:0] st_pf_drop_conflict,
  output logic [31:0] st_pf_drop_inflight,
  output logic [31:0] st_pf_drop_nomshr,
  output logic [31:0] st_pf_drop_late,
  output logic [31:0] st_pf_merge_cycles,
  output logic [31:0] st_pf_interf_cycles,
  // arbiter (Innovation 1)
  output logic [31:0] st_win_nl,
  output logic [31:0] st_win_st,
  output logic [31:0] st_win_dc,
  output logic [31:0] st_gated_lowconf,
  output logic [31:0] st_gated_phase,
  output logic [31:0] st_gated_throttle,
  // request pipeline
  output logic [31:0] st_enq,
  output logic [31:0] st_drop_dup,
  output logic [31:0] st_drop_qfull,
  output logic [31:0] st_drop_busy,
  // throttle (Innovation 2)
  output logic [31:0] st_thr_down,
  output logic [31:0] st_thr_up,
  output logic [31:0] st_thr_suppress_win,
  output logic [31:0] st_thr_degree_acc,
  output logic [31:0] st_thr_windows,
  // phase detector (Innovation 3)
  output logic [31:0] st_ph_stream,
  output logic [31:0] st_ph_stride,
  output logic [31:0] st_ph_irreg,
  output logic [31:0] st_ph_transitions,
  // engine internals
  output logic [15:0] st_dc_alloc,
  output logic [15:0] st_dc_confirm,
  output logic [15:0] st_st_retrain,
  // live state, for the phase-accuracy trace
  output logic [1:0]  phase_cur,
  output logic [3:0]  degree_cur
);

  // --------------------------------------------------------------------------
  //  Cache <-> prefetcher wiring
  // --------------------------------------------------------------------------
  logic              acc_vld;
  logic [ADDR_W-1:0] acc_addr;
  logic              fb_useful, fb_useless;
  logic [9:0] pf_meta, fb_useful_meta, fb_useless_meta;
  logic              pf_vld, pf_take;
  logic [ADDR_W-1:0] pf_addr;

  cache_controller #(
    .ADDR_W(ADDR_W), .DATA_W(DATA_W), .LINE_BYTES(LINE_BYTES),
    .NUM_SETS(NUM_SETS), .NUM_WAYS(NUM_WAYS),
    .POLICY(POLICY), .PF_INSERT_DISTANT(PF_INSERT_DISTANT),
    .PF_MSHR(PF_MSHR), .MEM_ID_W(MEM_ID_W)
  ) u_cache (
    .clk, .rst_n,
    .cpu_vld, .cpu_we, .cpu_addr, .cpu_wdata,
    .cpu_rdy, .cpu_rvld, .cpu_rdata,
    .pf_vld, .pf_addr, .pf_take, .pf_meta,
    .acc_vld, .acc_addr,
    .fb_useful, .fb_useless, .fb_useful_meta, .fb_useless_meta,
    .mem_req, .mem_we, .mem_id, .mem_addr, .mem_wdata,
    .mem_gnt, .mem_resp_vld, .mem_resp_id,
    .mem_resp_is_write, .mem_resp_data,
    .st_dem_acc, .st_dem_hit, .st_dem_miss, .st_dem_lat_acc,
    .st_pf_probe, .st_pf_probe_hit, .st_pf_fill,
    .st_pf_useful, .st_pf_useless,
    .st_pf_drop_dirty, .st_pf_drop_conflict, .st_pf_drop_inflight,
    .st_pf_drop_nomshr, .st_pf_drop_late,
    .st_pf_merge_cycles, .st_pf_interf_cycles,
    .st_writeback
  );

  pf_engine #(
    .EN_PERCEPTRON(EN_PERCEPTRON), .ML_MARGIN(ML_MARGIN),
    .ML_EXPLORE_LOG2(ML_EXPLORE_LOG2),

    .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES),
    .EN_NEXTLINE(EN_NEXTLINE), .EN_STRIDE(EN_STRIDE), .EN_DELTA(EN_DELTA),
    .EN_THROTTLE(EN_THROTTLE), .DEGREE_INIT(DEGREE_INIT),
    .DEGREE_MAX(DEGREE_MAX), .THR_WINDOW(THR_WINDOW),
    .EN_PHASE(EN_PHASE), .PHASE_WINDOW(PHASE_WINDOW),
    .ST_TABLE(ST_TABLE), .ST_REGION_LOG2(ST_REGION_LOG2),
    .DC_TABLE(DC_TABLE), .DC_HIST(DC_HIST),
    .QUEUE_DEPTH(PF_QUEUE_DEPTH), .FILTER_DEPTH(PF_FILTER_DEPTH)
  ) u_pf (
    .clk, .rst_n,
    .acc_vld, .acc_addr,
    .fb_useful, .fb_useless, .fb_useful_meta, .fb_useless_meta,
    .pf_vld, .pf_addr, .pf_take, .pf_meta,
    .st_win_nl, .st_win_st, .st_win_dc,
    .st_gated_lowconf, .st_gated_phase, .st_gated_throttle,
    .st_enq, .st_drop_dup, .st_drop_qfull, .st_drop_busy,
    .st_thr_down, .st_thr_up, .st_thr_suppress_win,
    .st_thr_degree_acc, .st_thr_windows,
    .st_ph_stream, .st_ph_stride, .st_ph_irreg, .st_ph_transitions,
    .st_dc_alloc, .st_dc_confirm, .st_st_retrain,
    .phase_cur, .degree_cur
  );

  // --------------------------------------------------------------------------
  //  Global cycle counter
  // --------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) st_cycles <= '0;
    else        st_cycles <= st_cycles + 1'b1;
  end

endmodule

`default_nettype wire
