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
# Reports land in out/vivado/<part>/.

set part [expr {[llength $argv] > 0 ? [lindex $argv 0] : "xc7a200tsbg484-1"}]
set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here .. ..]]
set out  [file join $root out vivado $part]
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

puts "Reports written to $out"
