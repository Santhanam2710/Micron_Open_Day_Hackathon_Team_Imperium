# ============================================================================
#  build.tcl -- headless Quartus build + report extraction
# ----------------------------------------------------------------------------
#     cd quartus && quartus_sh -t build.tcl
#
#  Produces output_files/ai_cache.fit.rpt (area) and ai_cache.sta.rpt (timing),
#  and prints the three numbers the report needs: ALMs, block-RAM bits, and Fmax.
# ============================================================================
load_package flow
project_new ai_cache -overwrite -revision ai_cache
source_tcl_script_quiet ""

# Re-apply assignments from the qsf
if {[file exists ai_cache.qsf]} {
    # project_new already read it; nothing further required
}

execute_module -tool map                        ;# Analysis & Synthesis
execute_module -tool fit                        ;# Fitter (place & route)
execute_module -tool sta                        ;# TimeQuest
execute_module -tool asm                        ;# Assembler

puts "\n==================== SUMMARY ===================="
set fit output_files/ai_cache.fit.rpt
if {[file exists $fit]} {
    set f [open $fit r]
    while {[gets $f line] >= 0} {
        if {[string match "*Logic utilization*"  $line] ||
            [string match "*ALMs needed*"        $line] ||
            [string match "*Total block memory bits*" $line] ||
            [string match "*Total RAM Blocks*"   $line] ||
            [string match "*Total registers*"    $line]} {
            puts [string trim $line]
        }
    }
    close $f
}
set sta output_files/ai_cache.sta.rpt
if {[file exists $sta]} {
    set f [open $sta r]
    set hit 0
    while {[gets $f line] >= 0} {
        if {[string match "*Slow 1100mV 85C Model Fmax Summary*" $line]} { set hit 1 }
        if {$hit && [string match "*MHz*" $line]} { puts [string trim $line]; set hit 0 }
    }
    close $f
}
puts "================================================\n"
project_close
