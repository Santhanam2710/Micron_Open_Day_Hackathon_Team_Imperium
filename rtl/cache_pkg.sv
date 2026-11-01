// ============================================================================
//  cache_pkg.sv -- Shared constants and types for the AI-Aware Cache project
// ----------------------------------------------------------------------------
//  Kept deliberately small so every RTL file remains readable on its own and
//  so the design still elaborates on tools with partial SystemVerilog support.
// ============================================================================
package cache_pkg;

  // ---- Workload phase encoding ---------------------------------------------
  // STREAM : dominant line-delta of +1  (contiguous sweep, e.g. GEMM weights)
  // STRIDE : dominant line-delta != +1  (constant-stride, e.g. CNN windows)
  // IRREG  : no dominant delta          (e.g. embedding-table gather)
  // WARMUP : detector has not yet closed its first observation window
  localparam logic [1:0] PH_STREAM = 2'd0;
  localparam logic [1:0] PH_STRIDE = 2'd1;
  localparam logic [1:0] PH_IRREG  = 2'd2;
  localparam logic [1:0] PH_WARMUP = 2'd3;

  // ---- Replacement policy selector ----------------------------------------
  localparam int POL_LRU   = 0;  // true LRU (exact, age-matrix based)
  localparam int POL_SRRIP = 1;  // static RRIP, insert at "long" re-reference
  localparam int POL_DRRIP = 2;  // SRRIP vs BRRIP chosen by set-duelling

  // ---- Prefetch source tags (used only for statistics) --------------------
  localparam logic [1:0] SRC_NONE     = 2'd0;
  localparam logic [1:0] SRC_NEXTLINE = 2'd1;
  localparam logic [1:0] SRC_STRIDE   = 2'd2;
  localparam logic [1:0] SRC_DELTA    = 2'd3;

endpackage
