.eqv SSEG 0x11000040

.data
buf:
    .space 16

.text
.globl main

main:
    li s0, SSEG
    la s1, buf

    sw x0, 0(s1)
    sw x0, 4(s1)
    fence.i

    # Wrong-path store after a taken branch must never enqueue.
    csrrs t0, 0xB0C, x0
    li t1, 0x12345678
    beq x0, x0, branch_taken
    sw t1, 0(s1)

branch_taken:
    csrrs t2, 0xB0C, x0
    sub t2, t2, t0
    bne t2, x0, fail_601
    fence.i
    lw t3, 0(s1)
    bne t3, x0, fail_602

    # Trap redirect must also kill the younger store.
    la t4, trap_handler
    csrrw x0, 0x305, t4           # mtvec = trap_handler
    csrrs t0, 0xB0C, x0
    li t1, 0xCAFEBABE
    ecall
    sw t1, 4(s1)
after_trap:
    csrrs t2, 0xB0C, x0
    sub t2, t2, t0
    bne t2, x0, fail_603
    fence.i
    lw t3, 4(s1)
    bne t3, x0, fail_604

pass:
    li t0, 120
    sw t0, 0(s0)

pass_loop:
    j pass_loop

trap_handler:
    csrrs t5, 0x341, x0           # mepc
    addi t5, t5, 8                # skip both ecall and the younger store
    csrrw x0, 0x341, t5
    mret

fail:
    li t0, -1
    sw t0, 0(s0)

fail_loop:
    j fail_loop

fail_601:
    li t0, 601
    sw t0, 0(s0)
    j fail_loop

fail_602:
    li t0, 602
    sw t0, 0(s0)
    j fail_loop

fail_603:
    li t0, 603
    sw t0, 0(s0)
    j fail_loop

fail_604:
    li t0, 604
    sw t0, 0(s0)
    j fail_loop
