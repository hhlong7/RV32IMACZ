.eqv SSEG 0x11000040

.text
.globl main

main:
    li s0, SSEG

    la t0, trap_handler
    csrrw x0, 0x305, t0
    csrrw x0, 0x300, x0
    csrrsi x0, 0x300, 8

    csrrs s3, 0xB09, x0
    li s2, 0

    la s1, ecall_site
ecall_site:
    ecall
after_ecall:
    li t0, 1
    bne s2, t0, fail_681

    la s1, ebreak_site
ebreak_site:
    ebreak
after_ebreak:
    li t0, 2
    bne s2, t0, fail_682

    la s1, illegal_site
illegal_site:
    .word 0xffffffff
after_illegal:
    li t0, 3
    bne s2, t0, fail_683

    csrrs t1, 0x300, x0
    andi t1, t1, 8
    li t2, 8
    bne t1, t2, fail_684

    csrrs t3, 0xB09, x0
    sub t3, t3, s3
    li t4, 3
    bne t3, t4, fail_685

pass:
    li t0, 117
    sw t0, 0(s0)

pass_loop:
    j pass_loop

trap_handler:
    csrrs t0, 0x342, x0
    csrrs t1, 0x341, x0
    csrrs t2, 0x343, x0
    csrrs t3, 0x300, x0

    bne t1, s1, fail_686

    andi t4, t3, 8
    bne t4, x0, fail_687
    li t5, 0x80
    and t4, t3, t5
    bne t4, t5, fail_688

    li t4, 11
    beq t0, t4, handle_ecall
    li t4, 3
    beq t0, t4, handle_ebreak
    li t4, 2
    beq t0, t4, handle_illegal
    j fail_689

handle_ecall:
    bne t2, x0, fail_690
    li s2, 1
    addi t1, t1, 4
    csrrw x0, 0x341, t1
    mret

handle_ebreak:
    bne t2, x0, fail_691
    li s2, 2
    addi t1, t1, 4
    csrrw x0, 0x341, t1
    mret

handle_illegal:
    li t4, -1
    bne t2, t4, fail_692
    li s2, 3
    addi t1, t1, 4
    csrrw x0, 0x341, t1
    mret

fail:
    li t0, -1
    sw t0, 0(s0)

fail_loop:
    j fail_loop

fail_681:
    li t0, 681
    sw t0, 0(s0)
    j fail_loop

fail_682:
    li t0, 682
    sw t0, 0(s0)
    j fail_loop

fail_683:
    li t0, 683
    sw t0, 0(s0)
    j fail_loop

fail_684:
    li t0, 684
    sw t0, 0(s0)
    j fail_loop

fail_685:
    li t0, 685
    sw t0, 0(s0)
    j fail_loop

fail_686:
    li t0, 686
    sw t0, 0(s0)
    j fail_loop

fail_687:
    li t0, 687
    sw t0, 0(s0)
    j fail_loop

fail_688:
    li t0, 688
    sw t0, 0(s0)
    j fail_loop

fail_689:
    li t0, 689
    sw t0, 0(s0)
    j fail_loop

fail_690:
    li t0, 690
    sw t0, 0(s0)
    j fail_loop

fail_691:
    li t0, 691
    sw t0, 0(s0)
    j fail_loop

fail_692:
    li t0, 692
    sw t0, 0(s0)
    j fail_loop
