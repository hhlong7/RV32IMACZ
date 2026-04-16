.eqv SSEG 0x11000040

.text
.globl main

main:
    li s0, SSEG
    li s1, 0

    beq x0, x0, branch_ok
    j fail_631

branch_ok:
    li t0, 5
    li t1, 6
    bne t0, t1, bne_ok
    j fail_632

bne_ok:
    blt t0, t1, blt_ok
    j fail_633

blt_ok:
    li t2, -1
    bltu t1, t2, bltu_ok
    j fail_634

bltu_ok:
    bgeu t2, t1, bgeu_ok
    j fail_635

bgeu_ok:
    jal t3, jal_target
after_jal:
    la t4, after_jal
    bne t3, t4, fail_636
    li t5, 1
    bne s1, t5, fail_637

    la a0, jalr_target
    la a1, jalr_return
    jalr a2, 0(a0)
jalr_return:
    bne a2, a1, fail_638
    li t6, 3
    bne s1, t6, fail_639

pass:
    li t0, 112
    sw t0, 0(s0)

pass_loop:
    j pass_loop

jal_target:
    li s1, 1
    jal x0, after_jal

jalr_target:
    addi s1, s1, 2
    jalr x0, 0(a1)

fail:
    li t0, -1
    sw t0, 0(s0)

fail_loop:
    j fail_loop

fail_631:
    li t0, 631
    sw t0, 0(s0)
    j fail_loop

fail_632:
    li t0, 632
    sw t0, 0(s0)
    j fail_loop

fail_633:
    li t0, 633
    sw t0, 0(s0)
    j fail_loop

fail_634:
    li t0, 634
    sw t0, 0(s0)
    j fail_loop

fail_635:
    li t0, 635
    sw t0, 0(s0)
    j fail_loop

fail_636:
    li t0, 636
    sw t0, 0(s0)
    j fail_loop

fail_637:
    li t0, 637
    sw t0, 0(s0)
    j fail_loop

fail_638:
    li t0, 638
    sw t0, 0(s0)
    j fail_loop

fail_639:
    li t0, 639
    sw t0, 0(s0)
    j fail_loop
