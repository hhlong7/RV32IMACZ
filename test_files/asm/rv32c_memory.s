.eqv SSEG 0x11000040

.text
.globl main

main:
    li s0, SSEG
    li sp, 0x2400

    # Exercise the SP-based compressed forms and prove that addi16sp/addi4spn
    # compute the same addresses the 32-bit ISA would.
    c.addi16sp sp, -32
    c.addi4spn a0, sp, 16
    addi t0, sp, 16
    bne a0, t0, fail_721

    li a1, 0x12345678
    c.sw a1, 0(a0)
    c.lw a2, 0(a0)
    bne a2, a1, fail_722

    li t1, 0x0badc0de
    c.swsp t1, 0(sp)
    c.lwsp t2, 0(sp)
    bne t2, t1, fail_723

    li a2, 32
    c.srli a2, 2
    li t0, 8
    bne a2, t0, fail_724

    c.li a3, -8
    c.srai a3, 1
    li t0, -4
    bne a3, t0, fail_725

    c.andi a3, 15
    li t0, 12
    bne a3, t0, fail_726

    c.li a4, 7
    c.li a5, 3
    c.sub a4, a5
    li t0, 4
    bne a4, t0, fail_727

    c.xor a4, a5
    li t0, 7
    bne a4, t0, fail_728

    c.or a4, a5
    li t0, 7
    bne a4, t0, fail_729

    c.and a4, a5
    li t0, 3
    bne a4, t0, fail_730

    c.slli a5, 3
    li t0, 24
    bne a5, t0, fail_731

    c.lui a0, 1
    li t0, 0x1000
    bne a0, t0, fail_732

    c.addi16sp sp, 32

    li t0, 124
    sw t0, 0(s0)

pass_loop:
    j pass_loop

fail_loop:
    j fail_loop

fail_721:
    li t0, 721
    sw t0, 0(s0)
    j fail_loop

fail_722:
    li t0, 722
    sw t0, 0(s0)
    j fail_loop

fail_723:
    li t0, 723
    sw t0, 0(s0)
    j fail_loop

fail_724:
    li t0, 724
    sw t0, 0(s0)
    j fail_loop

fail_725:
    li t0, 725
    sw t0, 0(s0)
    j fail_loop

fail_726:
    li t0, 726
    sw t0, 0(s0)
    j fail_loop

fail_727:
    li t0, 727
    sw t0, 0(s0)
    j fail_loop

fail_728:
    li t0, 728
    sw t0, 0(s0)
    j fail_loop

fail_729:
    li t0, 729
    sw t0, 0(s0)
    j fail_loop

fail_730:
    li t0, 730
    sw t0, 0(s0)
    j fail_loop

fail_731:
    li t0, 731
    sw t0, 0(s0)
    j fail_loop

fail_732:
    li t0, 732
    sw t0, 0(s0)
    j fail_loop