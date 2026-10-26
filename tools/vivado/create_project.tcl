# Create the Vivado project for the OTTER core from the repository, then
# open the elaborated design. Vivado projects are machine-specific (absolute
# paths, run caches), so the project itself is not committed: this script
# builds it on any machine after a pull.
#
# Run it once. After that, open vivado/otter_core/otter_core.xpr (File >
# Project > Open, or the Recent Projects list) and use the Flow Navigator:
# Run Synthesis, Run Implementation, Generate Bitstream, then Open Hardware
# Manager > Program Device. Vivado keeps every run's results in the project,
# and re-runs only what an edited file affects. Run this script again only to
# start a fresh project (it replaces the old one) or to change the program.
#
# From the repository root (GUI opens with the project and the elaborated
# design):
#   vivado -source tools/vivado/create_project.tcl
# Or from the Vivado Tcl Console:
#   cd C:/path/to/RV32IMACZ
#   source tools/vivado/create_project.tcl
#
# Options (after -tclargs on the command line, or set before sourcing):
#   core=0            the Zybo Z7-20 board design, top zybo_top with its pin
#                     constraints: Run Synthesis / Implementation / Generate
#                     Bitstream work from the GUI (default)
#   core=1            the core alone, top OTTER_MCU, out-of-context at 50 MHz
#   program=<file>    memory image: a full path, a path in the repository, or
#                     a name in board/zybo such as coremark.mem (default
#                     zybo_hello.mem, the echo demo)
#   elaborate=0       create the project without opening the elaborated design
#
# The project lands in vivado/otter_core/ (ignored by git). Running the
# script again rebuilds it from scratch.

if {![info exists core]}      { set core 0 }
if {![info exists elaborate]} { set elaborate 1 }
foreach arg [expr {[info exists argv] ? $argv : {}}] {
    if {[regexp {^core=(.+)$} $arg -> v]}      { set core $v }
    if {[regexp {^program=(.+)$} $arg -> v]}   { set program $v }
    if {[regexp {^elaborate=(.+)$} $arg -> v]} { set elaborate $v }
}

set here [file dirname [file normalize [info script]]]
source [file join $here otter_common.tcl]
set root $otter_root
if {![info exists program]} { set program [file join $root board zybo zybo_hello.mem] }
set program [otter_find_program $program]
puts "Program image: $program"
set part xc7z020clg400-1
set proj_dir [file join $root vivado otter_core]

otter_reset_session
create_project otter_core $proj_dir -part $part -force
set_property target_language Verilog [current_project]

# Design sources: every file in rtl.f (packages first, as listed there), and
# the board top for the board design.
set sources [otter_sources]
if {!$core} {
    lappend sources [file join $root board uart.sv] [file join $root board zybo zybo_top.sv]
}
add_files -norecurse -fileset sources_1 $sources
set_property file_type SystemVerilog [get_files -of_objects [get_filesets sources_1]]
set_property verilog_define SYNTHESIS [get_filesets sources_1]

# Memory images (imem.sv and otter_memory_v1_07.sv read them at synthesis).
set memfiles [otter_prepare_mem $program [file join $proj_dir mem]]
add_files -norecurse -fileset sources_1 $memfiles
set_property file_type {Memory File} [get_files $memfiles]

if {$core} {
    set_property top OTTER_MCU [get_filesets sources_1]
    add_files -norecurse -fileset constrs_1 [file join $here core_ooc.xdc]
    set_property USED_IN {synthesis out_of_context} [get_files core_ooc.xdc]
    set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} \
        -value {-mode out_of_context} -objects [get_runs synth_1]
} else {
    set_property top zybo_top [get_filesets sources_1]
    add_files -norecurse -fileset constrs_1 [file join $root board zybo zybo.xdc]
    # Same steps as build_zybo.tcl, which met timing at 35.7 MHz with
    # physical optimization after placement.
    set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
}
update_compile_order -fileset sources_1

# Testbenches for Vivado's simulator (xsim): tb_core (core alone) and
# tb_zybo (board). Both load Test_All.mem from the simulation directory.
add_files -norecurse -fileset sim_1 [list [file join $root tb_core.sv] \
    [file join $root board zybo tb_zybo.sv]]
set_property file_type SystemVerilog [get_files -of_objects [get_filesets sim_1] *.sv]
set_property top [expr {$core ? "tb_core" : "tb_zybo"}] [get_filesets sim_1]

puts "Project created: [file join $proj_dir otter_core.xpr] (part $part, top [get_property top [get_filesets sources_1]])"
puts "Next time, open that .xpr instead of running this script again."

if {$elaborate} {
    # Same as Flow Navigator > RTL Analysis > Open Elaborated Design.
    synth_design -rtl -rtl_skip_mlo -name rtl_1
    if {[catch {start_gui}]} { }
}
