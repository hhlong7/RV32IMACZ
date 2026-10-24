# Core-only (out-of-context) Vivado synthesis of OTTER_MCU with its block-RAM
# memories, for LUT/FF/BRAM counts and timing against the 50 MHz goal
# without board pins. For the board itself (bitstream), use build_zybo.tcl.
#
# From the repository root:
#   vivado -mode batch -source tools/vivado/synth_core.tcl
#   vivado -mode batch -source tools/vivado/synth_core.tcl -tclargs part=xc7a200tsbg484-1 impl=0
#
# Options (key=value after -tclargs, or set as variables before sourcing):
#   part=<part>   FPGA part (default xc7z020clg400-1); a bare part name works too
#   impl=1        also place and route (default), so timing includes real wire
#                 delays; impl=0 stops after synthesis (faster, optimistic)
#
# Default part: Zynq-7020 (Zybo Z7-20; the core goes in the programmable
# logic). Other parts:
#   xc7a200tsbg484-1   Artix-7 200T (Nexys Video), the earlier target
#   xc7a100tcsg324-1   Artix-7 100T (Nexys A7-100T, Arty A7-100T)
# Or from the Vivado Tcl Console: cd to the repository, then
#   source tools/vivado/synth_core.tcl
#
# The console prints a summary (resources, worst slack, estimated maximum
# clock, worst path per module pair) after synthesis and again after place
# and route; summary.txt always holds the latest one. The full reports are
# written to reports/vivado/<part>/, which is tracked by git, so pushing
# shares them.

if {![info exists part]} { set part "xc7z020clg400-1" }
if {![info exists impl]} { set impl 1 }
foreach arg [expr {[info exists argv] ? $argv : {}}] {
    if {[regexp {^part=(.+)$} $arg -> v]} { set part $v } \
    elseif {[regexp {^impl=(.+)$} $arg -> v]} { set impl $v } \
    elseif {[regexp {^xc7} $arg]} { set part $arg }
}
set here [file dirname [file normalize [info script]]]
source [file join $here otter_common.tcl]
set root $otter_root
set out  [file join $root reports vivado $part]
file mkdir $out

# Memory contents do not affect timing; the board demo fills them.
set memdir [file join $root build core_mem]
set memfiles [otter_prepare_mem [file join $root board zybo zybo_hello.mem] $memdir]
cd $memdir

read_verilog -sv [otter_sources]
read_mem $memfiles
read_xdc -mode out_of_context [file join $here core_ooc.xdc]

synth_design -top OTTER_MCU -part $part -mode out_of_context -verilog_define SYNTHESIS
report_timing_summary -max_paths 10 -file [file join $out timing_summary_synth.txt]
write_summary "OTTER_MCU summary, $part" "after synthesis" $out

if {$impl} {
    # Out-of-context place and route: real placement and wire delays.
    opt_design
    place_design
    phys_opt_design
    route_design

    report_utilization -file [file join $out utilization.txt]
    report_utilization -hierarchical -hierarchical_depth 2 -file [file join $out utilization_hier.txt]
    report_timing_summary -max_paths 10 -file [file join $out timing_summary.txt]
    report_timing -max_paths 20 -sort_by group -file [file join $out timing_paths.txt]
    write_summary "OTTER_MCU summary, $part" "after place and route" $out
} else {
    report_utilization -file [file join $out utilization.txt]
    report_utilization -hierarchical -hierarchical_depth 2 -file [file join $out utilization_hier.txt]
}
cd $root
