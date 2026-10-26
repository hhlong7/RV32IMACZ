# Laptop-side commands for the JTAG host bridge (board/host_bridge.sv): load
# and run programs on the OTTER core and use its console over the board's
# USB-JTAG cable. Needs a bitstream built with the bridge (build_zybo.tcl,
# default host=1) and loaded with program_zybo.tcl.
#
# In the Vivado Tcl Console, from the repository:
#   source tools/vivado/host.tcl
#   otter_connect                      find the board and check the bridge
#   otter_load coremark.mem            hold the core, load a program, verify it
#   otter_run                          start it (console attached)
#   otter_console                      show what it prints (stops after 3 s of
#                                      quiet; otter_console 60 waits up to 60 s)
#   otter_send "hello"                 type to the program (otter_send -line
#                                      "text" adds Enter)
#   otter_cycles                       cycles since the program started
#   otter_sseg                         the program's seven-segment value
#                                      (pass/fail code of the test programs)
#   otter_stop                         hold the core in reset
#   otter_read 0x2000 8                read memory words (only while stopped)
#   otter_status                       running? console waiting?
#
# Program images are .mem files (one 32-bit hex word per line), given by full
# path, by path in the repository, or by name in board/zybo.

# Register access (not named read/write: inside this namespace those would
# hide Tcl's own read, which otter::read_mem uses).
namespace eval otter {
    variable axi ""
    variable root [file normalize [file join [file dirname [info script]] .. ..]]
    variable CONTROL     0x000
    variable STATUS      0x004
    variable LOAD_ADDR   0x008
    variable LOAD_DATA   0x00C
    variable CONSOLE_OUT 0x010
    variable CONSOLE_IN  0x014
    variable CYCLES_LO   0x018
    variable CYCLES_HI   0x01C
    variable SSEG        0x020
    variable ID          0x024
    variable ID_VALUE    0x4F545452
}

proc otter::wr {offset value} {
    variable axi
    create_hw_axi_txn -quiet -force otter_wr $axi -type write \
        -address [format %08X $offset] -data [format %08X [expr {$value & 0xFFFFFFFF}]]
    run_hw_axi -quiet [get_hw_axi_txns otter_wr]
}

proc otter::rd {offset} {
    variable axi
    create_hw_axi_txn -quiet -force otter_rd $axi -type read -address [format %08X $offset]
    run_hw_axi -quiet [get_hw_axi_txns otter_rd]
    scan [get_property DATA [get_hw_axi_txns otter_rd]] %x value
    # scan gives words with bit 31 set as negative numbers; keep them unsigned.
    return [expr {$value & 0xFFFFFFFF}]
}

proc otter::need {} {
    variable axi
    if {$axi eq ""} { error "Not connected: run otter_connect first." }
}

# Find the bridge: open the Hardware Manager and the board if needed, then
# check the bridge's ID register.
proc otter_connect {} {
    catch {open_hw_manager}
    if {[llength [get_hw_servers -quiet]] == 0} { connect_hw_server -allow_non_jtag }
    catch {open_hw_target}
    set device [lindex [get_hw_devices -quiet xc7z020*] 0]
    if {$device eq ""} { error "No xc7z020 on the JTAG chain (board on? cable in J12?)" }
    current_hw_device $device
    refresh_hw_device -quiet $device
    set axis [get_hw_axis -quiet]
    if {[llength $axis] == 0} {
        error "No JTAG-to-AXI master found. Program a bitstream built with the host bridge\
               (build_zybo.tcl with host=1, then program_zybo.tcl)."
    }
    set ::otter::axi [lindex $axis 0]
    reset_hw_axi -quiet $::otter::axi
    set id [otter::rd $::otter::ID]
    if {$id != $::otter::ID_VALUE} {
        error [format "Bridge ID reads 0x%08X, expected 0x%08X" $id $::otter::ID_VALUE]
    }
    puts "Connected to the OTTER host bridge ($::otter::axi)."
    otter_status
}

proc otter_status {} {
    otter::need
    set s [otter::rd $::otter::STATUS]
    set c [otter::rd $::otter::CONTROL]
    puts [format "core %s, console %s%s" \
        [expr {$s & 1 ? "running" : "held in reset"}] \
        [expr {$c & 2 ? "attached" : "not attached"}] \
        [expr {$s & 2 ? ", output waiting" : ""}]]
}

# Read a .mem image: one hex word per line, // comments allowed.
proc otter::read_mem {path} {
    set fh [open $path r]
    set words {}
    foreach line [split [read $fh] "\n"] {
        set w [string trim [lindex [split $line "/"] 0]]
        if {$w eq ""} { continue }
        if {[string index $w 0] eq "@"} { error "$path: address records (@...) are not supported" }
        lappend words [expr {"0x$w" & 0xFFFFFFFF}]
    }
    close $fh
    return $words
}

proc otter::find_program {name} {
    variable root
    foreach candidate [list $name [file join $root $name] [file join $root board zybo $name]] {
        if {[file isfile $candidate]} { return [file normalize $candidate] }
    }
    error "Program image '$name' not found (tried it as given, under $root, and in board/zybo)."
}

# Hold the core, write the image up to its last nonzero word (the startup
# code clears .bss), and read it back to verify.
proc otter_load {name} {
    otter::need
    set path [otter::find_program $name]
    set words [otter::read_mem $path]
    if {[llength $words] > 16384} { error "$path has [llength $words] words; the memory holds 16384" }
    set last -1
    for {set i 0} {$i < [llength $words]} {incr i} {
        if {[lindex $words $i] != 0} { set last $i }
    }
    if {$last < 0} { error "$path is all zeros" }

    set t0 [clock milliseconds]
    otter::wr $::otter::CONTROL 3           ;# hold, console attached
    otter_drain_console
    otter::wr $::otter::LOAD_ADDR 0
    for {set i 0} {$i <= $last} {incr i} {
        otter::wr $::otter::LOAD_DATA [lindex $words $i]
        if {$i % 512 == 511} { puts -nonewline "."; flush stdout }
    }
    otter::wr $::otter::LOAD_ADDR 0
    set bad 0
    for {set i 0} {$i <= $last} {incr i} {
        set got [otter::rd $::otter::LOAD_DATA]
        if {$got != [lindex $words $i]} {
            if {$bad < 5} {
                puts [format "\nword %d (0x%04X): read 0x%08X, loaded 0x%08X" $i [expr {4 * $i}] \
                         $got [lindex $words $i]]
            }
            incr bad
        }
    }
    if {$bad} { error "$bad words did not read back correctly" }
    set ms [expr {[clock milliseconds] - $t0}]
    puts [format "\nLoaded and verified %d words (%d bytes) from %s in %.1f s. Start it with otter_run." \
             [expr {$last + 1}] [expr {4 * ($last + 1)}] [file tail $path] [expr {$ms / 1000.0}]]
}

proc otter_run {} {
    otter::need
    otter::wr $::otter::CONTROL 2           ;# release, console attached
    puts "Running. otter_console shows its output."
}

proc otter_stop {} {
    otter::need
    otter::wr $::otter::CONTROL 3
    puts "Core held in reset."
}

# Leave the program running on its own: output the laptop does not read is
# dropped instead of making the program wait.
proc otter_detach {} {
    otter::need
    set c [otter::rd $::otter::CONTROL]
    otter::wr $::otter::CONTROL [expr {$c & 1}]
    puts "Console detached."
}

# Up to three bytes per read; returns what arrived.
proc otter::console_read {} {
    set w [otter::rd $::otter::CONSOLE_OUT]
    set n [expr {($w >> 24) & 0xFF}]
    set text ""
    for {set i 0} {$i < $n} {incr i} {
        set b [expr {($w >> (8 * $i)) & 0xFF}]
        if {$b != 13} { append text [format %c $b] }
    }
    return $text
}

proc otter_drain_console {} {
    otter::need
    while {[otter::console_read] ne ""} {}
}

# Print the program's output as it arrives; stop after `quiet` seconds with
# nothing new (3 by default), or `limit` seconds in all (default 10 x quiet).
proc otter_console {{quiet 3} {limit ""}} {
    otter::need
    if {$limit eq ""} { set limit [expr {10 * $quiet}] }
    set start [clock milliseconds]
    set last $start
    while {1} {
        set text [otter::console_read]
        set now [clock milliseconds]
        if {$text ne ""} {
            puts -nonewline $text
            flush stdout
            set last $now
        } elseif {$now - $last > 1000 * $quiet || $now - $start > 1000 * $limit} {
            break
        } else {
            after 20
        }
    }
    puts ""
}

proc otter_send {args} {
    otter::need
    set line 0
    if {[lindex $args 0] eq "-line"} { set line 1; set args [lrange $args 1 end] }
    set text [join $args " "]
    if {$line} { append text "\r" }
    foreach ch [split $text ""] {
        otter::wr $::otter::CONSOLE_IN [scan $ch %c]
    }
}

proc otter_cycles {} {
    otter::need
    set lo [otter::rd $::otter::CYCLES_LO]
    set hi [otter::rd $::otter::CYCLES_HI]
    set cycles [expr {($hi << 32) | $lo}]
    puts "$cycles cycles since the core was last released from reset"
    return $cycles
}

proc otter_sseg {} {
    otter::need
    set v [otter::rd $::otter::SSEG]
    puts [format "seven-segment register: %d (0x%04X)" $v $v]
    return $v
}

proc otter_read {addr {count 1}} {
    otter::need
    if {[otter::rd $::otter::STATUS] & 1} { error "Stop the core first (otter_stop)." }
    otter::wr $::otter::LOAD_ADDR $addr
    set words {}
    for {set i 0} {$i < $count} {incr i} {
        set w [otter::rd $::otter::LOAD_DATA]
        puts [format "0x%08X: 0x%08X" [expr {$addr + 4 * $i}] $w]
        lappend words $w
    }
    return $words
}

puts "OTTER host commands loaded. Start with: otter_connect"
