.eqv SSEG 0x11000040

.text
.globl main

main:
    li s0, SSEG

    # Mix compressed and 32-bit instructions so the fetch path has to consume
    # a normal 32-bit instruction starting at a halfword address.
    c.li a0, 1
    addi a1, a0, 2
    c.addi a1, 1
    li t0, 4
    bne a1, t0, fail_701

    c.mv t1, a1
    c.add t1, a0
    li t0, 5
    bne t1, t0, fail_702

    # c.jal must link to PC+2, not PC+4.
    c.jal c_call_target
after_c_jal:
    la t0, after_c_jal
    bne ra, t0, fail_703
    li t1, 1
    bne s1, t1, fail_704

    # c.jalr and c.jr use the same compressed fall-through/link rule.
    la a4, c_jalr_target
    la a5, after_c_jalr
    c.jalr a4
after_c_jalr:
    bne ra, a5, fail_705
    li t2, 3
    bne s1, t2, fail_706

    c.li a2, 0
    c.beqz a2, beqz_ok
    j fail_707

beqz_ok:
    c.li a2, 5
    c.bnez a2, bnez_ok
    j fail_708

bnez_ok:
    c.j control_done
    j fail_709

control_done:
    li t0, 123
    sw t0, 0(s0)

pass_loop:
    j pass_loop

c_call_target:
    c.li s1, 1
    c.j after_c_jal

c_jalr_target:
    c.addi s1, 2
    c.jr a5

fail_loop:
    j fail_loop

fail_701:
    li t0, 701
    sw t0, 0(s0)
    j fail_loop

fail_702:
    li t0, 702
    sw t0, 0(s0)
    j fail_loop

fail_703:
    li t0, 703
    sw t0, 0(s0)
    j fail_loop

fail_704:
    li t0, 704
    sw t0, 0(s0)
    j fail_loop

fail_705:
    li t0, 705
    sw t0, 0(s0)
    j fail_loop

fail_706:
    li t0, 706
    sw t0, 0(s0)
    j fail_loop

fail_707:
    li t0, 707
    sw t0, 0(s0)
    j fail_loop

fail_708:
    li t0, 708
    sw t0, 0(s0)
    j fail_loop

fail_709:
    li t0, 709
    sw t0, 0(s0)
    j fail_loop