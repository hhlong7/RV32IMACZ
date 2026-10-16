# Shared prologue/epilogue for lockstep programs (assembled with GNU as, no
# C preprocessor). A lockstep test does not need to check its own results:
# tools/lockstep.py compares every retired instruction and every memory write
# against Spike. Tests only need to end with LOCKSTEP_PASS.

.equ SSEG_ADDR,      0x11000040
.equ LOCKSTEP_PASS_CODE, 1337
.equ LOCKSTEP_FAIL_CODE, 2989

# GNU as compresses eligible instructions automatically when C is enabled.
# Wrap an instruction in I32 to force the 32-bit encoding; use explicit c.*
# mnemonics for compressed forms.
.macro I32 ins:vararg
    .option push
    .option norvc
    \ins
    .option pop
.endm

# Clears every register (Spike's boot ROM leaves t0/a0/a1 dirty) and installs
# a default trap handler that reports an unexpected trap as a failure.
.macro LOCKSTEP_START
    .section .text.init, "ax"
    .globl _start
_start:
    .irp r, 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    li x\r, 0
    .endr
    la t0, lockstep_unexpected_trap
    csrw mtvec, t0
    li t0, 0
.endm

# Signals the RTL testbench through the seven-segment MMIO register, then
# stops Spike through HTIF tohost.
.macro LOCKSTEP_PASS
    li t0, SSEG_ADDR
    li t1, LOCKSTEP_PASS_CODE
    sw t1, 0(t0)
    j lockstep_exit
.endm

.macro LOCKSTEP_FOOTER
    .balign 4
lockstep_unexpected_trap:
    li t0, SSEG_ADDR
    li t1, LOCKSTEP_FAIL_CODE
    sw t1, 0(t0)
lockstep_exit:
    la t0, tohost
    li t1, 1
    sw t1, 0(t0)
1:  j 1b

    .section .tohost, "aw", @progbits
    .balign 8
    .globl tohost
tohost: .dword 0
    .globl fromhost
fromhost: .dword 0
.endm
