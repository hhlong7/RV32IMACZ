# Build the Zybo Z7-20 bitstream: the OTTER core with block-RAM memories,
# a 35.7 MHz clock, LEDs, switches, buttons, and a UART on Pmod JE
# (board/zybo/zybo_top.sv, board/zybo/zybo.xdc).
#
# From the Vivado Tcl Console, after cd to the repository:
#   source tools/vivado/build_zybo.tcl
# Or from a shell in the repository:
#   vivado -mode batch -source tools/vivado/build_zybo.tcl
#   vivado -mode batch -source tools/vivado/build_zybo.tcl -tclargs program=path/to/image.mem
#
# Options (key=value after -tclargs, or set as variables before sourcing):
#   program=<file>   memory image to load (default board/zybo/zybo_hello.mem,
#                    built from software/zybo_hello); a full path, a path in
#                    the repository, or a name in board/zybo (coremark.mem)
#   impl=0           stop after synthesis (resources and estimated timing,
#                    no bitstream); default impl=1 builds the bitstream
#   host=0           leave out the JTAG host bridge (exactly the design that
#                    first ran CoreMark on the board); default host=1, which
#                    lets tools/vivado/host.tcl load and run programs
#
# For example, synthesis only, from the Tcl Console:
#   set impl 0
#   source tools/vivado/build_zybo.tcl
#
# Writes build/zybo/zybo_top.bit (not tracked by git) and the reports to
# reports/vivado/zybo/ (tracked). Then load the bitstream onto the board with
#   source tools/vivado/program_zybo.tcl

set here [file dirname [file normalize [info script]]]
source [file join $here otter_common.tcl]
set root $otter_root

if {![info exists program]} { set program [file join $root board zybo zybo_hello.mem] }
if {![info exists impl]} { set impl 1 }
if {![info exists host]} { set host 1 }
foreach arg [expr {[info exists argv] ? $argv : {}}] {
    if {[regexp {^program=(.+)$} $arg -> v]} { set program [file normalize $v] }
    if {[regexp {^impl=(.+)$} $arg -> v]} { set impl $v }
    if {[regexp {^host=(.+)$} $arg -> v]} { set host $v }
}
set program [otter_find_program $program]
puts "Program image: $program"
otter_reset_session
set part xc7z020clg400-1
set build [file join $root build zybo]
set out [file join $root reports vivado zybo]
file mkdir $build $out

set memfiles [otter_prepare_mem $program $build]
cd $build

set_part $part
if {$host} {
    otter_create_jtag_axi [file join $build ip]
}
read_verilog -sv [concat [otter_sources] [otter_board_sources]]
read_mem $memfiles
read_xdc [file join $root board zybo zybo.xdc]

puts "Host bridge: [expr {$host ? {included (JTAG)} : {left out}}]"
synth_design -top zybo_top -part $part -verilog_define SYNTHESIS -generic HOST=$host
write_summary "Zybo Z7-20 build" "after synthesis" $out

if {!$impl} {
    report_utilization -file [file join $out utilization_synth.txt]
    report_utilization -hierarchical -hierarchical_depth 3 -file [file join $out utilization_hier_synth.txt]
    report_timing_summary -max_paths 10 -file [file join $out timing_summary_synth.txt]
    cd $root
    puts "Synthesis done (impl=0). Reports: $out"
    return
}

opt_design
place_design
phys_opt_design
route_design

report_utilization -file [file join $out utilization.txt]
report_utilization -hierarchical -hierarchical_depth 3 -file [file join $out utilization_hier.txt]
report_timing_summary -max_paths 10 -file [file join $out timing_summary.txt]
report_clock_utilization -file [file join $out clock_utilization.txt]
write_summary "Zybo Z7-20 build" "after place and route" $out

write_bitstream -force [file join $build zybo_top.bit]
# The JTAG-to-AXI master is a debug core; the Hardware Manager reads this
# file to find it (program_zybo.tcl loads it).
file delete -force [file join $build zybo_top.ltx]
if {$host} {
    write_debug_probes -force [file join $build zybo_top.ltx]
}
cd $root

set wns [get_property SLACK [get_timing_paths -setup -max_paths 1 -nworst 1]]
if {$wns < 0} {
    puts "WARNING: timing is not met (worst slack $wns ns). The bitstream may not work reliably."
} else {
    puts "Timing met (worst slack $wns ns)."
}
puts "Bitstream: [file join $build zybo_top.bit]"
puts "Program the board with: source tools/vivado/program_zybo.tcl"
