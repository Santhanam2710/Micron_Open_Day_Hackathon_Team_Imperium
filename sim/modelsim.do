# ============================================================================
#  modelsim.do -- run the testbench under ModelSim/Questa (the simulator that
#                 ships with Quartus Prime)
# ----------------------------------------------------------------------------
#  From the project root:
#     vsim -c -do sim/modelsim.do
#
#  To change configuration, edit the -g overrides in the vsim line below; they
#  are the same parameter names scripts/run_sweep.py passes to Verilator, so
#  the ModelSim flow reproduces any row of results/sweep.csv.
#
#  Note on editions: ModelSim-Intel FPGA Starter Edition is line-limited and
#  single-threaded.  It runs this design, but a full 100 k-access trace takes
#  minutes rather than seconds.  Pass +maxacc=20000 for a quick functional
#  check, and use Verilator (sim/verilate.sh) for the measurement runs.
# ============================================================================
if {[file exists work]} { vdel -all }
vlib work

vlog -sv -work work rtl/cache_pkg.sv
vlog -sv -work work rtl/repl_policy.sv
vlog -sv -work work rtl/pf_nextline.sv
vlog -sv -work work rtl/pf_stride.sv
vlog -sv -work work rtl/pf_delta_corr.sv
vlog -sv -work work rtl/phase_detect.sv
vlog -sv -work work rtl/pf_throttle.sv
vlog -sv -work work rtl/pf_arbiter.sv
vlog -sv -work work rtl/pf_perceptron.sv
vlog -sv -work work rtl/pf_engine.sv
vlog -sv -work work rtl/cache_controller.sv
vlog -sv -work work rtl/dram_model.sv
vlog -sv -work work rtl/ai_cache_top.sv
vlog -sv -work work tb/tb_top.sv

# Full design.  Flip -gEN_THROTTLE / -gEN_PHASE / -gEN_* for the ablation.
vsim -c work.tb_top \
     -gEN_NEXTLINE=1 -gEN_STRIDE=1 -gEN_DELTA=1 \
     -gEN_THROTTLE=1 -gEN_PHASE=1 \
     +trace=traces/stream.trace +tag=modelsim +maxacc=20000

run -all
quit -f
