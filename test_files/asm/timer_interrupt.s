.eqv SSEG 0x11000040
.eqv PASS_CODE 126
.eqv FAIL_MCAUSE 960
.eqv MTIMECMP_LO 0x02004000
.eqv MTIMECMP_HI 0x02004004
.eqv MTIME_LO 0x0200BFF8

.text
.globl main

main:
    li s0, SSEG
    li s1, 0

    la t0, trap_handler
    csrrw x0, 0x305, t0

    csrrw x0, 0x304, x0
    csrrw x0, 0x300, x0

    li t0, MTIMECMP_LO
    li t1, -1
    sw t1, 0(t0)
    li t0, MTIMECMP_HI
    sw t1, 0(t0)

    li t0, MTIME_LO
    lw t1, 0(t0)
    addi t1, t1, 24

    li t0, MTIMECMP_HI
    sw x0, 0(t0)
    li t0, MTIMECMP_LO
    sw t1, 0(t0)

    li t0, 0x80
    csrrs x0, 0x304, t0
    li t0, 0x8
    csrrs x0, 0x300, t0

wait_for_tick:
    beq s1, x0, wait_for_tick

    li t0, PASS_CODE
    sw t0, 0(s0)

done:
    j done

trap_handler:
    csrrs t0, 0x342, x0
    li t1, 0x80000007
    bne t0, t1, fail_mcause

    addi s1, s1, 1
    csrrw x0, 0x304, x0
    mret

fail_mcause:
    li t0, FAIL_MCAUSE
    sw t0, 0(s0)

fail_loop:
    j fail_loop