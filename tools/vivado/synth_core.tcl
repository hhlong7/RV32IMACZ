# Core-only (out-of-context) Vivado synthesis of OTTER_MCU, for LUT/FF/BRAM
# counts and timing without a board. The simulation memory models are
# replaced by black-box stubs (see memory_stubs.sv).
#
# From the repository root:
#   vivado -mode batch -source tools/vivado/synth_core.tcl
#   vivado -mode batch -source tools/vivado/synth_core.tcl -tclargs xc7a100tcsg324-1
#
# Default part: Artix-7 200T (Nexys Video). Other common parts:
#   xc7a100tcsg324-1   Artix-7 100T (Nexys A7-100T, Arty A7-100T)
#   xc7a35tcpg236-1    Artix-7 35T  (Basys 3)
# Or from the Vivado Tcl Console: cd to the repository, then
#   source tools/vivado/synth_core.tcl
#
# The console ends with a summary (resources, worst slack, estimated
# maximum clock, worst paths). The full reports are written to
# reports/vivado/<part>/, which is tracked by git, so pushing shares them.

if {[info exists argv] && [llength $argv] > 0} {
    set part [lindex $argv 0]
} elseif {![info exists part]} {
    set part "xc7a200tsbg484-1"
}
set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here .. ..]]
set out  [file join $root reports vivado $part]
file mkdir $out

# Every RTL file in rtl.f except the two memory models, then the stubs.
set sources {}
set fh [open [file join $root rtl.f] r]
foreach line [split [read $fh] "\n"] {
    set f [string trim $line]
    if {$f eq "" || [string index $f 0] eq "#"} { continue }
    if {$f in {otter_memory_v1_07.sv imem.sv}} { continue }
    lappend sources [file join $root $f]
}
close $fh
lappend sources [file join $here memory_stubs.sv]

read_verilog -sv $sources
read_xdc -mode out_of_context [file join $here core_ooc.xdc]

synth_design -top OTTER_MCU -part $part -mode out_of_context

report_utilization -file [file join $out utilization.txt]
report_utilization -hierarchical -hierarchical_depth 2 -file [file join $out utilization_hier.txt]
report_timing_summary -max_paths 10 -file [file join $out timing_summary.txt]
report_timing -max_paths 20 -sort_by group -file [file join $out timing_paths.txt]

# ---- Console summary --------------------------------------------------------
proc count_cells {pattern} {
    if {[catch {llength [get_cells -hierarchical -quiet -filter "PRIMITIVE_TYPE =~ $pattern"]} n]} { return "?" }
    return $n
}
set period [get_property PERIOD [get_clocks clk]]
set worst [get_timing_paths -setup -max_paths 1 -nworst 1 -quiet]
set summary {}
lappend summary "==================== OTTER_MCU synthesis summary ($part) ===================="
lappend summary [format "LUTs (logic)      %8s" [count_cells CLB.LUT.*]]
lappend summary [format "LUTs as memory    %8s" [count_cells CLB.LUTRAM.*]]
lappend summary [format "Flip-flops        %8s" [count_cells REGISTER.*]]
lappend summary [format "DSP48 slices      %8s" [count_cells MULT.dsp.*]]
lappend summary [format "Block RAM tiles   %8s" [count_cells BLOCKRAM.*]]
if {[llength $worst] > 0} {
    set wns [get_property SLACK $worst]
    lappend summary [format "Clock target      %8.3f ns (%.1f MHz)" $period [expr {1000.0 / $period}]]
    lappend summary [format "Worst setup slack %8.3f ns  -> %s" $wns [expr {$wns >= 0 ? "MET" : "FAILED"}]]
    lappend summary [format "Estimated Fmax    %8.1f MHz (synthesis estimate, before placement)" \
                         [expr {1000.0 / ($period - $wns)}]]
    lappend summary "Worst paths (slack ns, logic levels, start -> end):"
    foreach p [get_timing_paths -setup -max_paths 5 -nworst 1 -quiet] {
        lappend summary [format "  %8.3f  %3s  %s -> %s" [get_property SLACK $p] \
                             [get_property LOGIC_LEVELS $p] \
                             [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p]]
    }
}
lappend summary "Full reports: $out"
set fh [open [file join $out summary.txt] w]
puts $fh [join $summary "\n"]
close $fh
puts [join $summary "\n"]
