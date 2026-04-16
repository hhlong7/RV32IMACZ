.eqv SSEG 0x11000040

.text
.globl main

main:
    li s0, SSEG

    li t0, 0x12345678
    csrrw t1, 0x340, t0
    bne t1, x0, fail_671
    csrrs t2, 0x340, x0
    bne t2, t0, fail_672

    csrrw x0, 0x300, x0
    csrrsi t3, 0x300, 8
    bne t3, x0, fail_673
    csrrs t4, 0x300, x0
    li t5, 8
    bne t4, t5, fail_674
    csrrci t6, 0x300, 8
    bne t6, t5, fail_675
    csrrs t4, 0x300, x0
    bne t4, x0, fail_676

    li t0, 7
    csrrw x0, 0xB0B, t0
    csrrs t1, 0xB0B, x0
    bne t1, t0, fail_677

    csrrs t2, 0x301, x0
    li t3, 0x40001100
    bne t2, t3, fail_678

    csrrs t4, 0xC00, x0
    csrrs t5, 0xC00, x0
    bltu t5, t4, fail_679

    csrrs t4, 0xC01, x0
    csrrs t5, 0xC01, x0
    bgeu t5, t4, pass
    j fail_680

fail_679:
    li t0, 679
    sw t0, 0(s0)
    j fail_loop

fail_680:
    li t0, 680
    sw t0, 0(s0)
    j fail_loop

pass:
    li t0, 116
    sw t0, 0(s0)

pass_loop:
    j pass_loop

fail:
    li t0, -1
    sw t0, 0(s0)

fail_loop:
    j fail_loop

fail_671:
    li t0, 671
    sw t0, 0(s0)
    j fail_loop

fail_672:
    li t0, 672
    sw t0, 0(s0)
    j fail_loop

fail_673:
    li t0, 673
    sw t0, 0(s0)
    j fail_loop

fail_674:
    li t0, 674
    sw t0, 0(s0)
    j fail_loop

fail_675:
    li t0, 675
    sw t0, 0(s0)
    j fail_loop

fail_676:
    li t0, 676
    sw t0, 0(s0)
    j fail_loop

fail_677:
    li t0, 677
    sw t0, 0(s0)
    j fail_loop

fail_678:
    li t0, 678
    sw t0, 0(s0)
    j fail_loop
