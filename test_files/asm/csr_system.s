.eqv SSEG 0x11000040

.text
.globl main

main:
    li s0, SSEG

    la t0, trap_handler
    csrrw x0, 0x305, t0

    li t0, 0x12345678
    csrrw t1, 0x340, t0
    bne t1, x0, fail_201
    csrrs t2, 0x340, x0
    bne t2, t0, fail_202

    li t0, 3
    csrrs t3, 0x300, t0
    bne t3, x0, fail_203
    csrrs t4, 0x300, x0
    li t5, 3
    bne t4, t5, fail_204
    csrrci t6, 0x300, 1
    bne t6, t5, fail_205
    csrrs t4, 0x300, x0
    li t5, 2
    bne t4, t5, fail_206

    la s1, ecall_site
    li s2, 0
ecall_site:
    ecall
after_ecall:
    li t0, 1
    bne s2, t0, fail_207

    la s1, ebreak_site
ebreak_site:
    ebreak
after_ebreak:
    li t0, 2
    bne s2, t0, fail_208

pass:
    li t0, 102
    sw t0, 0(s0)

pass_loop:
    j pass_loop

trap_handler:
    csrrs t0, 0x342, x0
    csrrs t1, 0x341, x0
    bne t1, s1, fail_209

    li t2, 11
    beq t0, t2, handle_ecall
    li t2, 3
    beq t0, t2, handle_ebreak
    j fail_210

handle_ecall:
    li s2, 1
    addi t1, t1, 4
    csrrw x0, 0x341, t1
    mret

handle_ebreak:
    li s2, 2
    addi t1, t1, 4
    csrrw x0, 0x341, t1
    mret

fail:
    li t0, -1
    sw t0, 0(s0)

fail_loop:
    j fail_loop

fail_201:
    li t0, 201
    sw t0, 0(s0)
    j fail_loop

fail_202:
    li t0, 202
    sw t0, 0(s0)
    j fail_loop

fail_203:
    li t0, 203
    sw t0, 0(s0)
    j fail_loop

fail_204:
    li t0, 204
    sw t0, 0(s0)
    j fail_loop

fail_205:
    li t0, 205
    sw t0, 0(s0)
    j fail_loop

fail_206:
    li t0, 206
    sw t0, 0(s0)
    j fail_loop

fail_207:
    li t0, 207
    sw t0, 0(s0)
    j fail_loop

fail_208:
    li t0, 208
    sw t0, 0(s0)
    j fail_loop

fail_209:
    li t0, 209
    sw t0, 0(s0)
    j fail_loop

fail_210:
    li t0, 210
    sw t0, 0(s0)
    j fail_loop
