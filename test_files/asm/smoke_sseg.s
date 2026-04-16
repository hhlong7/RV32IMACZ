.eqv SSEG 0x11000040

.text
.globl main

main:
    li t0, SSEG
    li t1, 5
    sw t1, 0(t0)

loop:
    j loop
