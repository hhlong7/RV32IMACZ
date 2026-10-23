# Core-only (out-of-context) Vivado synthesis of OTTER_MCU, for LUT/FF/BRAM
# counts and timing without a board. The simulation memory models are
# replaced by register-only stand-ins (see memory_stubs.sv); empty black
# boxes would stop place and route (DRC INBB-3).
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
# and route; summary.txt always holds the latest one. The full reports are written to
# reports/vivado/<part>/, which is tracked by git, so pushing shares them.

if {![info exists part]} { set part "xc7z020clg400-1" }
if {![info exists impl]} { set impl 1 }
foreach arg [expr {[info exists argv] ? $argv : {}}] {
    if {[regexp {^part=(.+)$} $arg -> v]} { set part $v } \
    elseif {[regexp {^impl=(.+)$} $arg -> v]} { set impl $v } \
    elseif {[regexp {^xc7} $arg]} { set part $arg }
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

# Hierarchy of a timing pin, at most two levels deep, without the register
# and pin names: OTTER_LSU/STORE_BUFFER/head_q_reg[0]/C -> OTTER_LSU/STORE_BUFFER.
proc module_of {pin} {
    set parts [lrange [split $pin "/"] 0 end-2]
    if {[llength $parts] == 0} { return "(core top)" }
    return [join [lrange $parts 0 1] "/"]
}

# The worst path for each (start module, end module) pair among the N worst
# endpoints. One slow block (say a cache) fills the plain top-10 list with
# copies of a single path; this table shows every distinct block that fails.
# <file>_detail.txt has the full cell-by-cell report of the first 40 groups.
proc report_path_groups {file n} {
    set seen [dict create]
    set rows {}
    set group_paths {}
    foreach p [get_timing_paths -setup -max_paths $n -nworst 1 -quiet] {
        set s [get_property STARTPOINT_PIN $p]
        set e [get_property ENDPOINT_PIN $p]
        set key "[module_of $s] -> [module_of $e]"
        if {[dict exists $seen $key]} { continue }
        dict set seen $key 1
        lappend rows [format "%8.3f  %3s  %-60s  %s -> %s" [get_property SLACK $p] \
                          [get_property LOGIC_LEVELS $p] $key $s $e]
        lappend group_paths $p
    }
    # Cell-by-cell detail of each group's worst path, worst first.
    set detail [file rootname $file]_detail.txt
    file delete -force $detail
    foreach p [lrange $group_paths 0 39] {
        report_timing -of_objects $p -file $detail -append
    }
    set fh [open $file w]
    puts $fh "Worst setup path per (start module -> end module), from the $n worst endpoints"
    puts $fh "   slack  lvl  modules                                                       start pin -> end pin"
    puts $fh [join $rows "\n"]
    close $fh
    return [lrange $rows 0 9]
}

# Resource totals, worst slack, and the per-module worst paths; written to
# summary.txt and the console after each stage, so a run stopped early still
# leaves current numbers.
proc write_summary {part stage out} {
    set period [get_property PERIOD [get_clocks clk]]
    set worst [get_timing_paths -setup -max_paths 1 -nworst 1 -quiet]
    set summary {}
    lappend summary "==================== OTTER_MCU summary ($part, $stage) ===================="
    # Totals straight from the utilization report (cell-type names differ
    # between Vivado versions, the report rows do not).
    set util [report_utilization -return_string]
    foreach {label row} {"LUTs (total)" "Slice LUTs" "  LUT as Logic" "LUT as Logic" "  LUT as Memory" "LUT as Memory"
                         "Flip-flops" "Slice Registers" "DSP48 slices" "DSPs" "Block RAM tiles" "Block RAM Tile"} {
        set used "?"
        regexp "\\|\\s*${row}\\*?\\s*\\|\\s*(\\d+)" $util -> used
        lappend summary [format "%-17s %8s" $label $used]
    }
    if {[llength $worst] > 0} {
        set wns [get_property SLACK $worst]
        lappend summary [format "Clock target      %8.3f ns (%.1f MHz)" $period [expr {1000.0 / $period}]]
        lappend summary [format "Worst setup slack %8.3f ns  -> %s" $wns [expr {$wns >= 0 ? "MET" : "FAILED"}]]
        lappend summary [format "Estimated Fmax    %8.1f MHz (%s)" \
                             [expr {1000.0 / ($period - $wns)}] $stage]
        lappend summary "Worst path per module pair (slack ns, logic levels, modules); all in path_groups.txt:"
        foreach row [report_path_groups [file join $out path_groups.txt] 5000] {
            lappend summary "  [string range $row 0 80]"
        }
    }
    lappend summary "Full reports: $out"
    set fh [open [file join $out summary.txt] w]
    puts $fh [join $summary "\n"]
    close $fh
    puts [join $summary "\n"]
}

synth_design -top OTTER_MCU -part $part -mode out_of_context
report_timing_summary -max_paths 10 -file [file join $out timing_summary_synth.txt]
write_summary $part "after synthesis" $out

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
    write_summary $part "after place and route" $out
} else {
    report_utilization -file [file join $out utilization.txt]
    report_utilization -hierarchical -hierarchical_depth 2 -file [file join $out utilization_hier.txt]
}
