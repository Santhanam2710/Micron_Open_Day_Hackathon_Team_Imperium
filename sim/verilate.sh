#!/usr/bin/env bash
# ============================================================================
#  verilate.sh -- build the simulation binary with Verilator
# ----------------------------------------------------------------------------
#  Usage:
#     sim/verilate.sh [-o <binary>] [-d <objdir>] [-- -GPARAM=value ...]
#
#  Examples:
#     sim/verilate.sh                                   # full design
#     sim/verilate.sh -o sim_base -- -GEN_NEXTLINE=0 \
#                                    -GEN_STRIDE=0 -GEN_DELTA=0
#
#  Any -G overrides are applied to tb_top, which forwards every parameter down
#  into the DUT.  That is what lets the ablation study build each configuration
#  from identical RTL instead of from hand-edited copies.
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="sim_tb"
MDIR=""
EXTRA=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) OUT="$2"; shift 2 ;;
    -d) MDIR="$2"; shift 2 ;;
    --) shift; EXTRA=("$@"); break ;;
    *)  echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$MDIR" ]] && MDIR="obj_${OUT}"

# Package first, then leaf modules, then the hierarchy, then the testbench.
SRCS=(
  rtl/cache_pkg.sv
  rtl/repl_policy.sv
  rtl/pf_nextline.sv
  rtl/pf_stride.sv
  rtl/pf_delta_corr.sv
  rtl/phase_detect.sv
  rtl/pf_throttle.sv
  rtl/pf_arbiter.sv
  rtl/pf_perceptron.sv
  rtl/pf_engine.sv
  rtl/cache_controller.sv
  rtl/dram_model.sv
  rtl/ai_cache_top.sv
  tb/tb_top.sv
)

# Width warnings are waived rather than fixed with casts everywhere: the design
# mixes parameterised widths deliberately and the arithmetic is checked by the
# self-checking testbench, which is a stronger guarantee than a lint pass.
WAIVERS=(
  -Wall
  -Wno-WIDTH
  -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM
  -Wno-DECLFILENAME -Wno-VARHIDDEN
  -Wno-SYNCASYNCNET
  # RTL files carry no `timescale on purpose: timing belongs to the testbench,
  # and a stray timescale in a synthesisable file is a portability hazard.
  -Wno-TIMESCALEMOD
  # Blocking assignments in the testbench's clock generator and driver are
  # intentional -- that is how a procedural testbench is written.
  -Wno-BLKSEQ
)

verilator --binary --timing -j "${BUILD_JOBS:-4}" \
  --top-module tb_top \
  "${WAIVERS[@]}" \
  -O3 --x-assign fast --x-initial fast \
  --unroll-count 8192 --unroll-stmts 400000 \
  --Mdir "$MDIR" -o "../$OUT" \
  "${EXTRA[@]}" \
  "${SRCS[@]}"

echo "built: $ROOT/$OUT"
