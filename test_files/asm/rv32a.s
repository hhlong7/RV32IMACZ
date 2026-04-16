.eqv SSEG 0x11000040

.data
    .align 2
slot0:
    .word 5
slot1:
    .word 0x11223344
slot2:
    .word 0x80000005
slot3:
    .word 0x7ffffffe
slot4:
    .word 0x0000ffff
slot5:
    .word 0xffffffff
slot6:
    .word 9
slot7:
    .word 0

.text
.globl main

main:
    li s0, SSEG
    la s1, slot0

    # LR/SC succeeds across an unrelated store, and a real fence decodes and
    # drains before we continue the ordered atomic sequence.
    addi t0, s1, 0
    lr.w.aq t1, (t0)
    li t2, 5
    bne t1, t2, fail_1220

    addi t3, s1, 28
    li t4, 0x89abcdef
    sw t4, 0(t3)
    fence

    li t2, 0x12345678
    sc.w.rl t5, t2, (t0)
    bne t5, x0, fail_1221
    lw t6, 0(t0)
    bne t6, t2, fail_1222
    lw a0, 0(t3)
    bne a0, t4, fail_1223

    # A second SC without a fresh reservation must fail and leave memory alone.
    li t2, 0xdeadbeef
    sc.w t5, t2, (t0)
    li t6, 1
    bne t5, t6, fail_1224
    li t6, 0x12345678
    lw a0, 0(t0)
    bne a0, t6, fail_1225

    # A same-word store between LR and SC clears the reservation.
    addi t0, s1, 4
    lr.w t1, (t0)
    li t2, 0x11223344
    bne t1, t2, fail_1226
    li t2, 0x55667788
    sw t2, 0(t0)
    li t4, 0xcafebabe
    sc.w t5, t4, (t0)
    li t6, 1
    bne t5, t6, fail_1227
    lw a0, 0(t0)
    bne a0, t2, fail_1228

    # Basic AMO arithmetic and logical ops all return the old word.
    addi t0, s1, 24
    li t2, 4
    amoadd.w.aqrl t3, t2, (t0)
    li t6, 9
    bne t3, t6, fail_1229
    li t6, 13
    lw a0, 0(t0)
    bne a0, t6, fail_1230

    li t2, 0xaaaa5555
    amoswap.w t3, t2, (t0)
    li t6, 13
    bne t3, t6, fail_1231
    lw a0, 0(t0)
    bne a0, t2, fail_1232

    li t2, 0x00ff00ff
    amoxor.w t3, t2, (t0)
    li t6, 0xaaaa5555
    bne t3, t6, fail_1233
    li t6, 0xaa5555aa
    lw a0, 0(t0)
    bne a0, t6, fail_1234

    li t2, 0x0f0f0f0f
    amoand.w t3, t2, (t0)
    li t6, 0xaa5555aa
    bne t3, t6, fail_1235
    li t6, 0x0a05050a
    lw a0, 0(t0)
    bne a0, t6, fail_1236

    li t2, 0x0000f000
    amoor.w t3, t2, (t0)
    li t6, 0x0a05050a
    bne t3, t6, fail_1237
    li t6, 0x0a05f50a
    lw a0, 0(t0)
    bne a0, t6, fail_1238

    # Signed and unsigned min/max variants use the right comparator.
    addi t0, s1, 8
    li t2, 7
    amomin.w t3, t2, (t0)
    li t6, 0x80000005
    bne t3, t6, fail_1239
    lw a0, 0(t0)
    bne a0, t6, fail_1240

    addi t0, s1, 12
    li t2, -1
    amomax.w t3, t2, (t0)
    li t6, 0x7ffffffe
    bne t3, t6, fail_1241
    lw a0, 0(t0)
    bne a0, t6, fail_1242

    addi t0, s1, 16
    li t2, -1
    amominu.w t3, t2, (t0)
    li t6, 0x0000ffff
    bne t3, t6, fail_1243
    lw a0, 0(t0)
    bne a0, t6, fail_1244

    addi t0, s1, 20
    li t2, 1
    amomaxu.w t3, t2, (t0)
    li t6, -1
    bne t3, t6, fail_1245
    lw a0, 0(t0)
    bne a0, t6, fail_1246

pass:
    li t0, 122
    sw t0, 0(s0)

pass_loop:
    j pass_loop

fail_1220:
    li t0, 1220
    sw t0, 0(s0)
fail_loop_1220:
    j fail_loop_1220

fail_1221:
    li t0, 1221
    sw t0, 0(s0)
fail_loop_1221:
    j fail_loop_1221

fail_1222:
    li t0, 1222
    sw t0, 0(s0)
fail_loop_1222:
    j fail_loop_1222

fail_1223:
    li t0, 1223
    sw t0, 0(s0)
fail_loop_1223:
    j fail_loop_1223

fail_1224:
    li t0, 1224
    sw t0, 0(s0)
fail_loop_1224:
    j fail_loop_1224

fail_1225:
    li t0, 1225
    sw t0, 0(s0)
fail_loop_1225:
    j fail_loop_1225

fail_1226:
    li t0, 1226
    sw t0, 0(s0)
fail_loop_1226:
    j fail_loop_1226

fail_1227:
    li t0, 1227
    sw t0, 0(s0)
fail_loop_1227:
    j fail_loop_1227

fail_1228:
    li t0, 1228
    sw t0, 0(s0)
fail_loop_1228:
    j fail_loop_1228

fail_1229:
    li t0, 1229
    sw t0, 0(s0)
fail_loop_1229:
    j fail_loop_1229

fail_1230:
    li t0, 1230
    sw t0, 0(s0)
fail_loop_1230:
    j fail_loop_1230

fail_1231:
    li t0, 1231
    sw t0, 0(s0)
fail_loop_1231:
    j fail_loop_1231

fail_1232:
    li t0, 1232
    sw t0, 0(s0)
fail_loop_1232:
    j fail_loop_1232

fail_1233:
    li t0, 1233
    sw t0, 0(s0)
fail_loop_1233:
    j fail_loop_1233

fail_1234:
    li t0, 1234
    sw t0, 0(s0)
fail_loop_1234:
    j fail_loop_1234

fail_1235:
    li t0, 1235
    sw t0, 0(s0)
fail_loop_1235:
    j fail_loop_1235

fail_1236:
    li t0, 1236
    sw t0, 0(s0)
fail_loop_1236:
    j fail_loop_1236

fail_1237:
    li t0, 1237
    sw t0, 0(s0)
fail_loop_1237:
    j fail_loop_1237

fail_1238:
    li t0, 1238
    sw t0, 0(s0)
fail_loop_1238:
    j fail_loop_1238

fail_1239:
    li t0, 1239
    sw t0, 0(s0)
fail_loop_1239:
    j fail_loop_1239

fail_1240:
    li t0, 1240
    sw t0, 0(s0)
fail_loop_1240:
    j fail_loop_1240

fail_1241:
    li t0, 1241
    sw t0, 0(s0)
fail_loop_1241:
    j fail_loop_1241

fail_1242:
    li t0, 1242
    sw t0, 0(s0)
fail_loop_1242:
    j fail_loop_1242

fail_1243:
    li t0, 1243
    sw t0, 0(s0)
fail_loop_1243:
    j fail_loop_1243

fail_1244:
    li t0, 1244
    sw t0, 0(s0)
fail_loop_1244:
    j fail_loop_1244

fail_1245:
    li t0, 1245
    sw t0, 0(s0)
fail_loop_1245:
    j fail_loop_1245

fail_1246:
    li t0, 1246
    sw t0, 0(s0)
fail_loop_1246:
    j fail_loop_1246
