// ============================================================================
//  tb_top.sv -- Self-checking testbench with memory-trace playback
// ----------------------------------------------------------------------------
//  Every parameter of the design is exposed here so that one source tree can
//  build every point of the ablation study and the design-space sweep.  They
//  are overridden on the command line as -GEN_THROTTLE=0 under Verilator, or
//  as -gEN_THROTTLE=0 at vsim time under ModelSim.
//
//  SELF-CHECKING IS NOT OPTIONAL
//  A cache that reports a wonderful hit rate while returning wrong data is
//  worth nothing, and a prefetcher bug shows up as "suspiciously good" numbers
//  far more often than as a crash.  So every read is checked against a
//  reference model: untouched memory holds its own word index, and written
//  words are tracked in a shadow array.  The run prints MISMATCHES, and any
//  non-zero value there invalidates the whole result.  Quote that number in
//  the report -- it is the evidence that the measurements mean something.
//
//  TRACE FORMAT (one access per line, '#' comments allowed)
//      <rw> <addr_hex> <phase_label>
//      rw    : 0 = read, 1 = write
//      addr  : byte address, hex, no 0x prefix
//      label : ground-truth phase, 0 = stream, 1 = stride, 2 = irregular
//  The label is never shown to the DUT.  It exists so that the hardware phase
//  detector's output can be scored against the truth the generator knows.
//
//  PLUSARGS
//      +trace=<path>     trace to play (required)
//      +stats=<path>     write the STAT block to a file as well as stdout
//      +phaselog=<path>  write "truth,predicted" per access for the confusion
//                        matrix that validates Innovation 3
//      +maxacc=<n>       stop after n accesses
//      +tag=<string>     label echoed into the STAT block
// ============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_top #(
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
  parameter int POLICY            = 2,
  parameter bit PF_INSERT_DISTANT = 1'b1,
  // ---- Innovation 1
  parameter bit EN_NEXTLINE       = 1'b1,
  parameter bit EN_STRIDE         = 1'b1,
  parameter bit EN_DELTA          = 1'b1,
  // ---- Innovation 2
  parameter bit EN_THROTTLE       = 1'b1,
  parameter int DEGREE_INIT       = 2,
  parameter int DEGREE_MAX        = 8,
  parameter int THR_WINDOW        = 256,
  // ---- Innovation 3
  parameter bit EN_PHASE          = 1'b1,
  parameter int PHASE_WINDOW      = 64,
  // ---- Prefetcher sizing
  parameter int ST_TABLE          = 16,
  parameter int ST_REGION_LOG2    = 16,
  parameter int DC_TABLE          = 128,
  parameter int DC_HIST           = 6,
  parameter int PF_QUEUE_DEPTH    = 16,
  parameter int PF_FILTER_DEPTH   = 32,
  parameter int PF_MSHR           = 16,
  parameter int MEM_ID_W          = 5,
  // ---- Memory
  parameter int DRAM_LATENCY      = 100,
  parameter int DRAM_OUTSTANDING  = 32,
  parameter int DRAM_BURST_CYCLES = 4,
  parameter int MEM_LINES         = 65536,     // 4 MiB footprint
  // ---- Reference model
  parameter int REF_WORDS         = 1048576    // 4 MiB / 4 B
);

  localparam int LINE_W = LINE_BYTES * 8;

  // ==========================================================================
  //  Clock and reset
  // ==========================================================================
  logic clk = 1'b0;
  logic rst_n = 1'b0;

  always #5 clk = ~clk;          // 100 MHz

  // ==========================================================================
  //  DUT interface
  // ==========================================================================
  logic              cpu_vld, cpu_we;
  logic [ADDR_W-1:0] cpu_addr;
  logic [DATA_W-1:0] cpu_wdata;
  logic              cpu_rdy, cpu_rvld;
  logic [DATA_W-1:0] cpu_rdata;

  logic                mem_req, mem_we, mem_gnt;
  logic                mem_resp_vld, mem_resp_is_write;
  logic [MEM_ID_W-1:0] mem_id, mem_resp_id;
  logic [ADDR_W-1:0]   mem_addr;
  logic [LINE_W-1:0]   mem_wdata, mem_resp_data;

  logic [31:0] st_cycles;
  logic [31:0] st_dem_acc, st_dem_hit, st_dem_miss, st_dem_lat_acc, st_writeback;
  logic [31:0] st_pf_probe, st_pf_probe_hit, st_pf_fill, st_pf_useful, st_pf_useless;
  logic [31:0] st_pf_drop_dirty, st_pf_drop_conflict;
  logic [31:0] st_pf_drop_nomshr, st_pf_drop_late, st_pf_drop_inflight;
  logic [31:0] st_pf_merge_cycles, st_pf_interf_cycles;
  logic [31:0] st_win_nl, st_win_st, st_win_dc;
  logic [31:0] st_gated_lowconf, st_gated_phase, st_gated_throttle;
  logic [31:0] st_enq, st_drop_dup, st_drop_qfull, st_drop_busy;
  logic [31:0] st_thr_down, st_thr_up, st_thr_suppress_win;
  logic [31:0] st_thr_degree_acc, st_thr_windows;
  logic [31:0] st_ph_stream, st_ph_stride, st_ph_irreg, st_ph_transitions;
  logic [15:0] st_dc_alloc, st_dc_confirm, st_st_retrain;
  logic [1:0]  phase_cur;
  logic [3:0]  degree_cur;

  logic [31:0] dram_reads, dram_writes, dram_bus_cycles, dram_stall_cycles;

  // ==========================================================================
  //  DUT
  // ==========================================================================
  ai_cache_top #(
    .EN_PERCEPTRON(EN_PERCEPTRON), .ML_MARGIN(ML_MARGIN),
    .ML_EXPLORE_LOG2(ML_EXPLORE_LOG2),

    .ADDR_W(ADDR_W), .DATA_W(DATA_W), .LINE_BYTES(LINE_BYTES),
    .NUM_SETS(NUM_SETS), .NUM_WAYS(NUM_WAYS),
    .POLICY(POLICY), .PF_INSERT_DISTANT(PF_INSERT_DISTANT),
    .EN_NEXTLINE(EN_NEXTLINE), .EN_STRIDE(EN_STRIDE), .EN_DELTA(EN_DELTA),
    .EN_THROTTLE(EN_THROTTLE), .DEGREE_INIT(DEGREE_INIT),
    .DEGREE_MAX(DEGREE_MAX), .THR_WINDOW(THR_WINDOW),
    .EN_PHASE(EN_PHASE), .PHASE_WINDOW(PHASE_WINDOW),
    .ST_TABLE(ST_TABLE), .ST_REGION_LOG2(ST_REGION_LOG2),
    .DC_TABLE(DC_TABLE), .DC_HIST(DC_HIST),
    .PF_QUEUE_DEPTH(PF_QUEUE_DEPTH), .PF_FILTER_DEPTH(PF_FILTER_DEPTH),
    .PF_MSHR(PF_MSHR), .MEM_ID_W(MEM_ID_W)
  ) dut (
    .clk, .rst_n,
    .cpu_vld, .cpu_we, .cpu_addr, .cpu_wdata,
    .cpu_rdy, .cpu_rvld, .cpu_rdata,
    .mem_req, .mem_we, .mem_id, .mem_addr, .mem_wdata,
    .mem_gnt, .mem_resp_vld, .mem_resp_id,
    .mem_resp_is_write, .mem_resp_data,
    .st_cycles,
    .st_dem_acc, .st_dem_hit, .st_dem_miss, .st_dem_lat_acc, .st_writeback,
    .st_pf_probe, .st_pf_probe_hit, .st_pf_fill, .st_pf_useful, .st_pf_useless,
    .st_pf_drop_dirty, .st_pf_drop_conflict, .st_pf_drop_inflight,
    .st_pf_drop_nomshr, .st_pf_drop_late,
    .st_pf_merge_cycles, .st_pf_interf_cycles,
    .st_win_nl, .st_win_st, .st_win_dc,
    .st_gated_lowconf, .st_gated_phase, .st_gated_throttle,
    .st_enq, .st_drop_dup, .st_drop_qfull, .st_drop_busy,
    .st_thr_down, .st_thr_up, .st_thr_suppress_win,
    .st_thr_degree_acc, .st_thr_windows,
    .st_ph_stream, .st_ph_stride, .st_ph_irreg, .st_ph_transitions,
    .st_dc_alloc, .st_dc_confirm, .st_st_retrain,
    .phase_cur, .degree_cur
  );

  dram_model #(
    .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .ID_W(MEM_ID_W),
    .LATENCY(DRAM_LATENCY), .MAX_OUTSTANDING(DRAM_OUTSTANDING),
    .BURST_CYCLES(DRAM_BURST_CYCLES), .MEM_LINES(MEM_LINES)
  ) u_dram (
    .clk, .rst_n,
    .req(mem_req), .req_we(mem_we), .req_id(mem_id),
    .req_addr(mem_addr), .req_wdata(mem_wdata), .gnt(mem_gnt),
    .resp_vld(mem_resp_vld), .resp_id(mem_resp_id),
    .resp_is_write(mem_resp_is_write), .resp_data(mem_resp_data),
    .n_reads(dram_reads), .n_writes(dram_writes),
    .n_bus_cycles(dram_bus_cycles), .n_stall_cycles(dram_stall_cycles)
  );

  // ==========================================================================
  //  Reference model.  Untouched memory holds its own word index, so only
  //  written words need shadowing.
  // ==========================================================================
  logic [31:0] ref_data [REF_WORDS];
  logic        ref_wr   [REF_WORDS];

  function automatic logic [31:0] expected_word (input logic [ADDR_W-1:0] a);
    int wi;
    begin
      wi = int'(a >> 2);
      if (ref_wr[wi]) expected_word = ref_data[wi];
      else            expected_word = a >> 2;
    end
  endfunction

  // ==========================================================================
  //  Trace reader
  // ==========================================================================
  int    trace_fd;
  string trace_path, stats_path, phase_path, run_tag;
  int    stats_fd, phase_fd;
  int    max_acc;

  logic              tr_vld;
  logic              tr_we;
  logic [ADDR_W-1:0] tr_addr;
  int                tr_lbl;

  int unsigned n_issued, n_retired, n_mismatch, n_oob;
  int unsigned phase_hit, phase_tot;
  int unsigned end_cycles;
  bit          draining;

  task automatic fetch_next();
    string ln;
    int    code, rw, lbl;
    logic [31:0] a;
    begin
      tr_vld = 1'b0;
      if ((max_acc != 0) && (n_issued >= unsigned'(max_acc))) return;
      while ($fgets(ln, trace_fd) > 0) begin
        if (ln.len() == 0)       continue;
        if (ln[0] == "#")        continue;
        code = $sscanf(ln, "%d %h %d", rw, a, lbl);
        if (code >= 2) begin
          tr_we   = (rw != 0);
          tr_addr = a;
          tr_lbl  = (code >= 3) ? lbl : 0;
          tr_vld  = 1'b1;
          return;
        end
      end
    end
  endtask

  // ==========================================================================
  //  In-flight scoreboard.  The cache keeps at most one request in flight and
  //  responds strictly in order, so a 4-deep ring is ample headroom.
  // ==========================================================================
  localparam int SB_DEPTH = 4;
  logic [ADDR_W-1:0] sb_addr [SB_DEPTH];
  logic              sb_we   [SB_DEPTH];
  logic [DATA_W-1:0] sb_wd   [SB_DEPTH];
  int                sb_lbl  [SB_DEPTH];
  int unsigned       sb_head, sb_tail;

  // ==========================================================================
  //  Driver + checker.  Combinational DUT outputs are sampled 1 ns after each
  //  rising edge, which is after the registered state has settled and well
  //  before the next edge.
  // ==========================================================================
  always @(posedge clk) begin
    #1;
    if (rst_n && !draining) begin

      // ---- 1. retire any response produced in this cycle -----------------
      if (cpu_rvld) begin
        automatic logic [ADDR_W-1:0] a = sb_addr[sb_head % SB_DEPTH];
        automatic logic              w = sb_we  [sb_head % SB_DEPTH];
        automatic logic [DATA_W-1:0] d = sb_wd  [sb_head % SB_DEPTH];
        automatic int                l = sb_lbl [sb_head % SB_DEPTH];
        automatic int                wi = int'(a >> 2);

        if (w) begin
          if (wi < REF_WORDS) begin
            ref_data[wi] = d;
            ref_wr[wi]   = 1'b1;
          end
        end else begin
          if (cpu_rdata !== expected_word(a)) begin
            n_mismatch = n_mismatch + 1;
            if (n_mismatch <= 10)
              $display("[MISMATCH] addr=%08h got=%08h exp=%08h (access %0d)",
                       a, cpu_rdata, expected_word(a), n_retired);
          end
        end

        // Score the hardware phase detector against the generator's label.
        phase_tot = phase_tot + 1;
        if (int'(phase_cur) == l) phase_hit = phase_hit + 1;
        if (phase_fd != 0) $fdisplay(phase_fd, "%0d,%0d", l, int'(phase_cur));

        sb_head   = sb_head + 1;
        n_retired = n_retired + 1;
      end

      // ---- 2. issue the next access if the cache can take one -------------
      if (cpu_rdy && tr_vld) begin
        if (int'(tr_addr >> 2) >= REF_WORDS) begin
          n_oob = n_oob + 1;      // trace stepped outside the modelled window
        end
        cpu_vld   = 1'b1;
        cpu_we    = tr_we;
        cpu_addr  = tr_addr;
        cpu_wdata = tr_addr ^ 32'hA5A5_0000;   // deterministic store payload

        sb_addr[sb_tail % SB_DEPTH] = tr_addr;
        sb_we  [sb_tail % SB_DEPTH] = tr_we;
        sb_wd  [sb_tail % SB_DEPTH] = tr_addr ^ 32'hA5A5_0000;
        sb_lbl [sb_tail % SB_DEPTH] = tr_lbl;
        sb_tail  = sb_tail + 1;
        n_issued = n_issued + 1;

        fetch_next();
      end else if (!cpu_rdy) begin
        // hold the current request asserted until it is accepted
      end else begin
        cpu_vld = 1'b0;           // trace exhausted
      end
    end
  end

  // ==========================================================================
  //  Write-back integrity checker
  // --------------------------------------------------------------------------
  //  A corrupt write-back does not fail immediately -- it quietly poisons
  //  memory and surfaces much later as an unexplained read mismatch, possibly
  //  for a completely different address.  Checking each write-back against
  //  the reference model at the moment it is issued turns that into an
  //  immediate, localised failure, which is the difference between a bug that
  //  takes ten minutes to find and one that takes a day.
  // ==========================================================================
  int unsigned n_wb_bad, n_wb_checked;

  always @(posedge clk) begin
    #1;
    if (rst_n && mem_req && mem_we && mem_gnt) begin
      automatic logic [ADDR_W-1:0] base = mem_addr;
      n_wb_checked = n_wb_checked + 1;
      for (int w = 0; w < LINE_BYTES/4; w++) begin
        automatic logic [ADDR_W-1:0] wa = base + ADDR_W'(w*4);
        automatic logic [31:0] got = mem_wdata[w*32 +: 32];
        if (got !== expected_word(wa)) begin
          n_wb_bad = n_wb_bad + 1;
          if (n_wb_bad <= 5)
            $display("[WB-CORRUPT] line=%08h word%0d addr=%08h got=%08h exp=%08h",
                     base, w, wa, got, expected_word(wa));
        end
      end
    end
  end

  // ==========================================================================
  //  Statistics reporting
  // ==========================================================================
  task automatic emit(input string k, input longint v);
    begin
      $display("STAT %s %0d", k, v);
      if (stats_fd != 0) $fdisplay(stats_fd, "%s %0d", k, v);
    end
  endtask

  task automatic emit_s(input string k, input string v);
    begin
      $display("STAT %s %s", k, v);
      if (stats_fd != 0) $fdisplay(stats_fd, "%s %s", k, v);
    end
  endtask

  task automatic report();
    begin
      $display("");
      $display("================ RUN COMPLETE ================");
      emit_s("tag",              run_tag);
      emit_s("trace",            trace_path);
      // ---- configuration echo (so a result file is self-describing) ------
      emit("cfg_cache_bytes",    NUM_SETS * NUM_WAYS * LINE_BYTES);
      emit("cfg_sets",           NUM_SETS);
      emit("cfg_ways",           NUM_WAYS);
      emit("cfg_line_bytes",     LINE_BYTES);
      emit("cfg_policy",         POLICY);
      emit("cfg_en_nextline",    EN_NEXTLINE);
      emit("cfg_en_stride",      EN_STRIDE);
      emit("cfg_en_delta",       EN_DELTA);
      emit("cfg_en_throttle",    EN_THROTTLE);
      emit("cfg_en_phase",       EN_PHASE);
      emit("cfg_pf_insert_dist", PF_INSERT_DISTANT);
      emit("cfg_degree_init",    DEGREE_INIT);
      emit("cfg_degree_max",     DEGREE_MAX);
      emit("cfg_dram_latency",   DRAM_LATENCY);
      // ---- correctness ---------------------------------------------------
      emit("mismatches",         n_mismatch);
      emit("wb_corrupt_words",   n_wb_bad);
      emit("wb_lines_checked",   n_wb_checked);
      emit("oob_accesses",       n_oob);
      emit("issued",             n_issued);
      emit("retired",            n_retired);
      // ---- timing --------------------------------------------------------
      emit("cycles",             end_cycles);
      emit("dem_lat_acc",        st_dem_lat_acc);
      // ---- cache ---------------------------------------------------------
      emit("dem_acc",            st_dem_acc);
      emit("dem_hit",            st_dem_hit);
      emit("dem_miss",           st_dem_miss);
      emit("writebacks",         st_writeback);
      // ---- prefetch service ----------------------------------------------
      emit("pf_probe",           st_pf_probe);
      emit("pf_probe_hit",       st_pf_probe_hit);
      emit("pf_fill",            st_pf_fill);
      emit("pf_useful",          st_pf_useful);
      emit("pf_useless",         st_pf_useless);
      emit("pf_drop_dirty",      st_pf_drop_dirty);
      emit("pf_drop_conflict",   st_pf_drop_conflict);
      emit("pf_drop_inflight",   st_pf_drop_inflight);
      emit("pf_drop_nomshr",     st_pf_drop_nomshr);
      emit("pf_drop_late",       st_pf_drop_late);
      emit("pf_merge_cycles",    st_pf_merge_cycles);
      emit("pf_interf_cycles",   st_pf_interf_cycles);
      // ---- Innovation 1: arbiter -----------------------------------------
      emit("win_nextline",       st_win_nl);
      emit("win_stride",         st_win_st);
      emit("win_delta",          st_win_dc);
      emit("gated_lowconf",      st_gated_lowconf);
      emit("gated_phase",        st_gated_phase);
      emit("gated_throttle",     st_gated_throttle);
      emit("pf_enq",             st_enq);
      emit("pf_drop_dup",        st_drop_dup);
      emit("pf_drop_qfull",      st_drop_qfull);
      emit("pf_drop_busy",       st_drop_busy);
      emit("dc_alloc",           st_dc_alloc);
      emit("dc_confirm",         st_dc_confirm);
      emit("st_retrain",         st_st_retrain);
      // ---- Innovation 2: throttle ----------------------------------------
      emit("thr_down",           st_thr_down);
      emit("thr_up",             st_thr_up);
      emit("thr_suppress_win",   st_thr_suppress_win);
      emit("thr_degree_acc",     st_thr_degree_acc);
      emit("thr_windows",        st_thr_windows);
      emit("degree_final",       degree_cur);
      emit("ml_candidates", dut.u_pf.u_ml.candidates);
      emit("ml_rejected", dut.u_pf.u_ml.rejected);
      emit("ml_explored", dut.u_pf.u_ml.explored);
      emit("ml_positive", dut.u_pf.u_ml.positive);
      emit("ml_negative", dut.u_pf.u_ml.negative);
      emit("ml_updates", dut.u_pf.u_ml.updates);
      emit("cfg_perceptron", EN_PERCEPTRON);
      // ---- Innovation 3: phase detector ----------------------------------
      emit("ph_stream",          st_ph_stream);
      emit("ph_stride",          st_ph_stride);
      emit("ph_irreg",           st_ph_irreg);
      emit("ph_transitions",     st_ph_transitions);
      emit("phase_correct",      phase_hit);
      emit("phase_total",        phase_tot);
      // ---- DRAM ----------------------------------------------------------
      emit("dram_reads",         dram_reads);
      emit("dram_writes",        dram_writes);
      emit("dram_bus_cycles",    dram_bus_cycles);
      emit("dram_stall_cycles",  dram_stall_cycles);
      emit("cfg_pf_mshr",        PF_MSHR);
      emit("cfg_dram_outstanding", DRAM_OUTSTANDING);
      emit("cfg_dram_burst",     DRAM_BURST_CYCLES);
      $display("==============================================");
      $display("");
    end
  endtask

  // ==========================================================================
  //  Main sequence
  // ==========================================================================
  int unsigned watchdog;

  initial begin
    // ---- defaults ---------------------------------------------------------
    cpu_vld = 1'b0; cpu_we = 1'b0; cpu_addr = '0; cpu_wdata = '0;
    n_issued = 0; n_retired = 0; n_mismatch = 0; n_oob = 0;
    phase_hit = 0; phase_tot = 0; end_cycles = 0;
    n_wb_bad = 0; n_wb_checked = 0;
    sb_head = 0; sb_tail = 0;
    stats_fd = 0; phase_fd = 0; draining = 1'b0;
    trace_path = ""; stats_path = ""; phase_path = ""; run_tag = "run";
    max_acc = 0;

    for (int i = 0; i < REF_WORDS; i++) ref_wr[i] = 1'b0;

    // ---- plusargs ---------------------------------------------------------
    if (!$value$plusargs("trace=%s", trace_path)) begin
      $display("FATAL: +trace=<path> is required");
      $finish;
    end
    void'($value$plusargs("stats=%s",    stats_path));
    void'($value$plusargs("phaselog=%s", phase_path));
    void'($value$plusargs("tag=%s",      run_tag));
    void'($value$plusargs("maxacc=%d",   max_acc));

    trace_fd = $fopen(trace_path, "r");
    if (trace_fd == 0) begin
      $display("FATAL: cannot open trace '%s'", trace_path);
      $finish;
    end
    if (stats_path != "") stats_fd = $fopen(stats_path, "w");
    if (phase_path != "") begin
      phase_fd = $fopen(phase_path, "w");
      if (phase_fd != 0) $fdisplay(phase_fd, "truth,pred");
    end

    // ---- reset ------------------------------------------------------------
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);
    fetch_next();

    // ---- run until every issued access has retired ------------------------
    watchdog = 0;
    forever begin
      @(posedge clk);
      watchdog = watchdog + 1;
      if (!tr_vld && (n_retired == n_issued) && (n_issued > 0)) break;
      if (watchdog > 32'd400_000_000) begin
        $display("FATAL: watchdog expired -- issued=%0d retired=%0d state stuck",
                 n_issued, n_retired);
        n_mismatch = n_mismatch + 1;
        break;
      end
    end

    draining   = 1'b1;
    cpu_vld    = 1'b0;
    end_cycles = st_cycles;
    repeat (20) @(posedge clk);

    report();

    if (trace_fd != 0) $fclose(trace_fd);
    if (stats_fd != 0) $fclose(stats_fd);
    if (phase_fd != 0) $fclose(phase_fd);

    if (n_wb_bad != 0)
      $display(">>> FAIL: %0d corrupt words written back to memory", n_wb_bad);
    if ((n_mismatch != 0) || (n_wb_bad != 0))
      $display(">>> FAIL: %0d read mismatches, %0d write-back corruptions",
               n_mismatch, n_wb_bad);
    else
      $display(">>> PASS: all %0d reads returned correct data", n_retired);

    $finish;
  end

endmodule

`default_nettype wire
