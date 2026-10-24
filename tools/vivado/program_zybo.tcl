# Load build/zybo/zybo_top.bit (from build_zybo.tcl) into the Zybo Z7-20 over
# its USB-JTAG port (the PROG/UART micro-USB connector, J12). Set the
# boot-mode jumper JP5 to JTAG and power the board first.
#
# From the Vivado Tcl Console, after cd to the repository:
#   source tools/vivado/program_zybo.tcl
#
# The design lives in FPGA configuration memory, so it is lost at power-off;
# run this again after power-cycling the board.

set root [file normalize [file join [file dirname [info script]] .. ..]]
set bit [file join $root build zybo zybo_top.bit]
if {![file exists $bit]} { error "$bit not found; run tools/vivado/build_zybo.tcl first" }

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
# The Zynq's JTAG chain also holds the ARM debug port; pick the FPGA.
set device [lindex [get_hw_devices xc7z020*] 0]
if {$device eq ""} { error "No xc7z020 found on the JTAG chain (is the board on and the cable in J12?)" }
current_hw_device $device
set_property PROGRAM.FILE $bit $device
program_hw_devices $device
refresh_hw_device $device
puts "Programmed $device with $bit"
