# Recreate the Vivado project for the OTTER core from the repository, then
# open the elaborated design. Vivado projects are machine-specific (absolute
# paths, run caches), so the project itself is not committed: this script
# rebuilds it on any machine after a pull.
#
# From the repository root (GUI opens with the project and the elaborated
# design):
#   vivado -source tools/vivado/create_project.tcl
# Or from the Vivado Tcl Console:
#   cd C:/path/to/RV32IMACZ
#   source tools/vivado/create_project.tcl
#
# Options (after -tclargs on the command line, or set before sourcing):
#   part=<part>       FPGA part (default xc7z020clg400-1, Zybo Z7-20)
#   memories=stub     core only; the simulation memory models are
#                     register-only stand-ins, so synthesis and
#                     implementation run (default)
#   memories=real     the real simulation memory models, for viewing the
#                     full elaborated design (synthesis will fail on them:
#                     they model external RAM and cannot be built from BRAM)
#   elaborate=0       create the project without opening the elaborated design
#
# The project lands in vivado/otter_core/ (ignored by git). Running the
# script again rebuilds it from scratch.

if {![info exists part]}      { set part "xc7z020clg400-1" }
if {![info exists memories]}  { set memories "stub" }
if {![info exists elaborate]} { set elaborate 1 }
foreach arg [expr {[info exists argv] ? $argv : {}}] {
    if {[regexp {^part=(.+)$} $arg -> v]}      { set part $v }
    if {[regexp {^memories=(.+)$} $arg -> v]}  { set memories $v }
    if {[regexp {^elaborate=(.+)$} $arg -> v]} { set elaborate $v }
}
if {$memories ni {stub real}} { error "memories must be stub or real, got '$memories'" }

set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here .. ..]]
set proj_dir [file join $root vivado otter_core]

if {[llength [get_projects -quiet]] > 0} { close_project }
create_project otter_core $proj_dir -part $part -force
set_property target_language Verilog [current_project]

# Design sources: every file in rtl.f (packages first, as listed there).
set sources {}
set fh [open [file join $root rtl.f] r]
foreach line [split [read $fh] "\n"] {
    set f [string trim $line]
    if {$f eq "" || [string index $f 0] eq "#"} { continue }
    if {$memories eq "stub" && $f in {otter_memory_v1_07.sv imem.sv}} { continue }
    lappend sources [file join $root $f]
}
close $fh
if {$memories eq "stub"} {
    lappend sources [file join $here memory_stubs.sv]
}
add_files -norecurse -fileset sources_1 $sources
set_property file_type SystemVerilog [get_files -of_objects [get_filesets sources_1]]
# The simulation memories load the program image at elaboration.
if {$memories eq "real" && [file exists [file join $root Test_All.mem]]} {
    add_files -norecurse -fileset sources_1 [file join $root Test_All.mem]
}

# Automatic compile order puts the packages (otter_defs_pkg, fpu_pkg,
# ooo_pkg) ahead of the modules that import them.
set_property top OTTER_MCU [get_filesets sources_1]
update_compile_order -fileset sources_1

# Core-only (out-of-context) constraints and synthesis: no board pins yet.
add_files -norecurse -fileset constrs_1 [file join $here core_ooc.xdc]
set_property USED_IN {synthesis out_of_context} [get_files core_ooc.xdc]
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} \
    -value {-mode out_of_context} -objects [get_runs synth_1]

# Testbench for Vivado's simulator (xsim). It loads Test_All.mem from the
# simulation directory; copy a program image there before running.
add_files -norecurse -fileset sim_1 [file join $root tb_core.sv]
set_property file_type SystemVerilog [get_files tb_core.sv]
set_property top tb_core [get_filesets sim_1]

puts "Project created: [file join $proj_dir otter_core.xpr] (part $part, memories $memories)"

if {$elaborate} {
    # Same as Flow Navigator > RTL Analysis > Open Elaborated Design.
    synth_design -rtl -rtl_skip_mlo -name rtl_1
    if {[catch {start_gui}]} { }
}
