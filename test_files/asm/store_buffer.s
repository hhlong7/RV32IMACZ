.eqv SSEG 0x11000040

.data
buf:
    .space 64

.text
.globl main

main:
    li s0, SSEG
    la t0, buf

    # Back-to-back stores should enqueue into the store buffer. With depth=4,
    # the fifth store forces a full-buffer stall before draining resumes.
    li t1, 0x11111111
    li t2, 0x22222222
    li t3, 0x33333333
    li t4, 0x44444444
    li t5, 0x55555555
    sw t1, 0(t0)
    sw t2, 4(t0)
    sw t3, 8(t0)
    sw t4, 12(t0)
    sw t5, 16(t0)

    # Matching load should forward from the youngest older store.
    lw t6, 16(t0)
    li t3, 0x55555555
    bne t6, t3, fail_501

    # Untouched location should still read back zero.
    lw t6, 20(t0)
    bne t6, x0, fail_502

    csrrs t4, 0xB0C, x0           # store-buffer enqueue counter
    li t5, 5
    blt t4, t5, fail_503

    csrrs t4, 0xB0D, x0           # full-buffer stall cycles
    beq t4, x0, fail_504

    csrrs t4, 0xB0E, x0           # store-to-load forwards
    beq t4, x0, fail_505

    # fence.i must wait until the remaining buffered stores drain.
    csrrs s1, 0xB11, x0           # fence wait cycles baseline
    li t1, 0x66666666
    li t2, 0x77777777
    sw t1, 28(t0)
    sw t2, 32(t0)
    fence.i
    csrrs t4, 0xB11, x0
    sub t4, t4, s1
    beq t4, x0, fail_506

    lw t6, 28(t0)
    li t3, 0x66666666
    bne t6, t3, fail_507
    lw t6, 32(t0)
    li t3, 0x77777777
    bne t6, t3, fail_508

    # Unsafe partial overlap must not forward. The load waits until the byte
    # store drains, then reads the committed value from memory/cache.
    sw x0, 24(t0)
    fence.i
    li t1, 0xAA
    sb t1, 24(t0)
    lw t6, 24(t0)
    li t3, 0xAA
    bne t6, t3, fail_509

    csrrs t4, 0xB0F, x0           # unresolved-store conflict stall cycles
    beq t4, x0, fail_510

pass:
    li t0, 108
    sw t0, 0(s0)

pass_loop:
    j pass_loop

fail:
    li t0, -1
    sw t0, 0(s0)

fail_loop:
    j fail_loop

fail_501:
    li t0, 501
    sw t0, 0(s0)
    j fail_loop

fail_502:
    li t0, 502
    sw t0, 0(s0)
    j fail_loop

fail_503:
    li t0, 503
    sw t0, 0(s0)
    j fail_loop

fail_504:
    li t0, 504
    sw t0, 0(s0)
    j fail_loop

fail_505:
    li t0, 505
    sw t0, 0(s0)
    j fail_loop

fail_506:
    li t0, 506
    sw t0, 0(s0)
    j fail_loop

fail_507:
    li t0, 507
    sw t0, 0(s0)
    j fail_loop

fail_508:
    li t0, 508
    sw t0, 0(s0)
    j fail_loop

fail_509:
    li t0, 509
    sw t0, 0(s0)
    j fail_loop

fail_510:
    li t0, 510
    sw t0, 0(s0)
    j fail_loop
