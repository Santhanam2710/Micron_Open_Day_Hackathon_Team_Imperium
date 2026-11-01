# ============================================================================
#  ai_cache.sdc -- Timing constraints
# ----------------------------------------------------------------------------
#  100 MHz is the target.  Raise the period first if the design does not close
#  timing, then read the failing path in TimeQuest before changing RTL: the
#  expected critical path is tag comparison -> hit mux -> response, and the
#  pipelining note in docs/README explains how to split it.
# ============================================================================
create_clock -name clk -period 10.000 [get_ports clk]
derive_clock_uncertainty

# Reset is synchronously released and is not a timing path worth analysing.
set_false_path -from [get_ports rst_n]

# Boundary registers inside synth_top absorb the I/O timing, so pad delays are
# not part of the reported internal critical path.
set_input_delay  -clock clk -max 2.0 [all_inputs]  -add_delay
set_input_delay  -clock clk -min 0.5 [all_inputs]  -add_delay
set_output_delay -clock clk -max 2.0 [all_outputs] -add_delay
set_output_delay -clock clk -min 0.5 [all_outputs] -add_delay
