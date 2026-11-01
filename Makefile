# ============================================================================
#  AI-Aware Cache & Prefetch Engine -- convenience targets
#  See README.md for the full guide.
# ============================================================================
.PHONY: all traces sim run sweep quick analyze lint synth clean help

SIM ?= ./sim_tb
TRACE ?= traces/mixed.trace
JOBS ?= 8

help:
	@echo "make traces   generate the AI-kernel memory traces (L1)"
	@echo "make sim      build the simulator with Verilator"
	@echo "make run      run one trace                 (TRACE=traces/cnn.trace)"
	@echo "make quick    headline ablation only        (fast)"
	@echo "make sweep    full ablation + design-space  (JOBS=8)"
	@echo "make analyze  tables, figures, summary.md"
	@echo "make all      traces -> sim -> sweep -> analyze"
	@echo "make lint     lint the synthesisable hierarchy only"
	@echo "make synth    headless Quartus build (needs quartus_sh on PATH)"
	@echo "make clean    remove build artefacts"

all: traces sim sweep analyze

traces:
	python3 scripts/gen_traces.py -o traces

sim:
	sim/verilate.sh -o sim_tb

run: sim
	$(SIM) +trace=$(TRACE) +tag=run

quick:
	python3 scripts/run_sweep.py --quick --jobs $(JOBS)

sweep:
	python3 scripts/run_sweep.py --jobs $(JOBS)

analyze:
	python3 scripts/analyze.py

lint:
	verilator --lint-only -Wall -Wno-fatal \
	  -Wno-WIDTH -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
	  -Wno-DECLFILENAME -Wno-VARHIDDEN -Wno-SYNCASYNCNET -Wno-TIMESCALEMOD \
	  -Wno-BLKSEQ --unroll-count 8192 --unroll-stmts 400000 \
	  --top-module synth_top \
	  rtl/cache_pkg.sv rtl/repl_policy.sv rtl/pf_nextline.sv rtl/pf_stride.sv \
	  rtl/pf_delta_corr.sv rtl/phase_detect.sv rtl/pf_throttle.sv \
	  rtl/pf_arbiter.sv rtl/pf_perceptron.sv rtl/pf_engine.sv rtl/cache_controller.sv \
	  rtl/ai_cache_top.sv rtl/synth_top.sv

synth:
	cd quartus && quartus_sh -t build.tcl

clean:
	rm -rf obj_* sim_* results/buildlogs
