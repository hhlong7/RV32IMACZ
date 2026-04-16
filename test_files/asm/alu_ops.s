.eqv SSEG 0x11000040

.text
.globl main

main:
    li s0, SSEG

    li t0, 7
    li t1, -3
    add t2, t0, t1
    li t3, 4
    bne t2, t3, fail_611

    sub t2, t0, t1
    li t3, 10
    bne t2, t3, fail_612

    xor t2, t0, t1
    li t3, -6
    bne t2, t3, fail_613

    and t2, t0, t1
    li t3, 5
    bne t2, t3, fail_614

    or t2, t0, t1
    li t3, -1
    bne t2, t3, fail_615

    li t0, 1
    li t1, 5
    sll t2, t0, t1
    li t3, 32
    bne t2, t3, fail_616

    li t0, -16
    li t1, 2
    sra t2, t0, t1
    li t3, -4
    bne t2, t3, fail_617

    li t0, 0x40
    li t1, 3
    srl t2, t0, t1
    li t3, 8
    bne t2, t3, fail_618

    li t0, -1
    li t1, 1
    slt t2, t0, t1
    li t3, 1
    bne t2, t3, fail_619

    sltu t2, t1, t0
    bne t2, t3, fail_620

    addi t2, t1, 15
    li t3, 16
    bne t2, t3, fail_621

    andi t2, t2, 7
    li t3, 0
    bne t2, t3, fail_622

    ori t2, t2, 9
    li t3, 9
    bne t2, t3, fail_623

    xori t2, t2, 12
    li t3, 5
    bne t2, t3, fail_624

    slti t2, t2, 6
    li t3, 1
    bne t2, t3, fail_625

    li t0, -1
    sltiu t2, t0, 1
    li t3, 0
    bne t2, t3, fail_626

pass:
    li t0, 111
    sw t0, 0(s0)

pass_loop:
    j pass_loop

fail:
    li t0, -1
    sw t0, 0(s0)

fail_loop:
    j fail_loop

fail_611:
    li t0, 611
    sw t0, 0(s0)
    j fail_loop

fail_612:
    li t0, 612
    sw t0, 0(s0)
    j fail_loop

fail_613:
    li t0, 613
    sw t0, 0(s0)
    j fail_loop

fail_614:
    li t0, 614
    sw t0, 0(s0)
    j fail_loop

fail_615:
    li t0, 615
    sw t0, 0(s0)
    j fail_loop

fail_616:
    li t0, 616
    sw t0, 0(s0)
    j fail_loop

fail_617:
    li t0, 617
    sw t0, 0(s0)
    j fail_loop

fail_618:
    li t0, 618
    sw t0, 0(s0)
    j fail_loop

fail_619:
    li t0, 619
    sw t0, 0(s0)
    j fail_loop

fail_620:
    li t0, 620
    sw t0, 0(s0)
    j fail_loop

fail_621:
    li t0, 621
    sw t0, 0(s0)
    j fail_loop

fail_622:
    li t0, 622
    sw t0, 0(s0)
    j fail_loop

fail_623:
    li t0, 623
    sw t0, 0(s0)
    j fail_loop

fail_624:
    li t0, 624
    sw t0, 0(s0)
    j fail_loop

fail_625:
    li t0, 625
    sw t0, 0(s0)
    j fail_loop

fail_626:
    li t0, 626
    sw t0, 0(s0)
    j fail_loop
