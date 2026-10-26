# Shared by synth_core.tcl, build_zybo.tcl, and create_project.tcl.

set otter_root [file normalize [file join [file dirname [info script]] .. ..]]

# Start from a clean slate: in non-project mode Vivado keeps every file read
# and the last design in memory across `source` runs in the same session, so
# a later run would otherwise also compile the earlier run's files. Only
# close what is open: Vivado reports "No open project" as an error even
# inside catch, and that stops a sourced script.
proc otter_reset_session {} {
    if {[llength [get_projects -quiet]] > 0} { close_project }
    if {[llength [current_design -quiet]] > 0} { close_design }
}

# A memory image given as a full path, a path relative to the current
# directory or to the repository, or a bare file name in board/zybo.
proc otter_find_program {program} {
    global otter_root
    foreach candidate [list $program [file join $otter_root $program] \
                           [file join $otter_root board zybo $program]] {
        if {[file isfile $candidate]} { return [file normalize $candidate] }
    }
    error "Program image '$program' not found (tried it as given, under $otter_root, and in board/zybo)."
}

# Every RTL file in rtl.f, in order (packages first), as absolute paths.
proc otter_sources {} {
    global otter_root
    set sources {}
    set fh [open [file join $otter_root rtl.f] r]
    foreach line [split [read $fh] "\n"] {
        set f [string trim $line]
        if {$f eq "" || [string index $f 0] eq "#"} { continue }
        lappend sources [file join $otter_root $f]
    }
    close $fh
    return $sources
}

# The memories load their contents at synthesis: Memory reads Test_All.mem,
# and imem reads Test_All.mem.bank0.mem .. bank7.mem, bank b holding the words whose
# address bits [4:2] are b (imem.sv). Writes all nine files for `program`
# (a .mem image, one 32-bit hex word per line) into `dir`; returns them.
proc otter_prepare_mem {program dir} {
    file mkdir $dir
    set fh [open $program r]
    set words {}
    foreach line [split [read $fh] "\n"] {
        set w [string trim $line]
        if {$w eq "" || [string match "//*" $w]} { continue }
        lappend words $w
    }
    close $fh
    if {[llength $words] > 16384} { error "$program has [llength $words] words; the memory holds 16384" }
    while {[llength $words] < 16384} { lappend words 00000000 }

    set files [list [file join $dir Test_All.mem]]
    set fh [open [lindex $files 0] w]
    puts $fh [join $words "\n"]
    close $fh
    for {set b 0} {$b < 8} {incr b} {
        set bank {}
        for {set i $b} {$i < 16384} {incr i 8} { lappend bank [lindex $words $i] }
        set f [file join $dir Test_All.mem.bank$b.mem]
        set fh [open $f w]
        puts $fh [join $bank "\n"]
        close $fh
        lappend files $f
    }
    return $files
}

# Hierarchy of a timing pin, at most two levels deep, without the register
# and pin names: OTTER_LSU/STORE_BUFFER/head_q_reg[0]/C -> OTTER_LSU/STORE_BUFFER.
proc module_of {pin} {
    set parts [lrange [split $pin "/"] 0 end-2]
    if {[llength $parts] == 0} { return "(top)" }
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
# leaves current numbers. The clock is the worst path's (the board design's
# core clock comes out of an MMCM).
proc write_summary {title stage out} {
    set worst [get_timing_paths -setup -max_paths 1 -nworst 1 -quiet]
    set summary {}
    lappend summary "==================== $title ($stage) ===================="
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
        set period [get_property PERIOD [get_property ENDPOINT_CLOCK $worst]]
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
