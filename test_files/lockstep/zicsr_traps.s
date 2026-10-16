# Zicsr and machine-mode traps: CSR read/modify/write forms on every
# software-visible machine CSR, synchronous exceptions (ecall, ebreak,
# c.ebreak, illegal encodings, illegal CSR accesses), mepc/mcause/mtval
# contents, MRET, and traps raised from awkward pipeline positions.
#
# Only spec-unambiguous values are compared: WARL fields are written with
# legal values, and counters/timers (which legitimately differ between a
# cycle-accurate core and an ISA simulator) are not read.
.include "harness.inc"

LOCKSTEP_START
    la t0, trap_handler
    csrw mtvec, t0

    # --- CSR instruction forms on mscratch -------------------------------
    li a3, 0x0ff0f00f
    csrrw a4, mscratch, a3
    csrrs a5, mscratch, a3
    li a6, 0x00f0000f
    csrrc a7, mscratch, a6
    csrrwi a4, mscratch, 31
    csrrsi a5, mscratch, 0x10
    csrrci a6, mscratch, 1
    csrrs a7, mscratch, x0    # read only (rs1=x0: no write)
    csrrc a7, mscratch, x0
    csrrsi a7, mscratch, 0
    csrrw x0, mscratch, a3    # write only (rd=x0)
    csrr a4, mscratch
    # Back-to-back read-after-write on the same CSR.
    csrw mscratch, a6
    csrr a5, mscratch
    csrs mscratch, a3
    csrr a5, mscratch
    # CSR result forwarded straight into an ALU op and a store.
    csrr a6, mscratch
    add a7, a6, a6
    la s0, scratch
    csrr a6, mscratch
    sw a6, 0(s0)

    # --- Machine CSRs with legal values ----------------------------------
    csrr a0, misa
    csrr a0, mvendorid
    csrr a0, mhartid
    li a1, 0x12345674
    csrw mepc, a1
    csrr a0, mepc
    li a1, 0x12345676         # bit 1 must stay writable with RVC
    csrw mepc, a1
    csrr a0, mepc
    li a1, 0x8000000b
    csrw mcause, a1
    csrr a0, mcause
    li a1, 0xdeadbeef
    csrw mtval, a1
    csrr a0, mtval
    li a1, 0x880              # MTIE | MEIE
    csrw mie, a1
    csrr a0, mie
    csrw mie, x0
    li a1, 0x80               # MPIE only; MIE stays clear
    csrw mstatus, a1
    csrr a0, mstatus          # MPP reads as M in an M-only hart
    csrw mstatus, x0
    csrr a0, mstatus

    # WFI is a legal no-op here: Spike wakes because its CLINT timer is
    # pending in mip and enabled in mie (with mstatus.MIE clear, no trap).
    li a1, 0x80
    csrw mie, a1
    wfi
    csrw mie, x0

    # --- Synchronous exceptions ------------------------------------------
    # The handler records mcause/mepc/mtval in a0/a1/a2 and resumes after
    # the trapping instruction.
    ecall
    ebreak
    c.ebreak
    .word 0x0000000b          # custom-0 opcode
    .word 0x02001033          # R-type with an unused funct7
    .word 0x00004073          # SYSTEM funct3=100 is reserved
    .word 0x7c002573          # csrr a0, 0x7c0: unimplemented CSR
    .word 0xc0001073          # csrw cycle, x0: read-only CSR
    .word 0xf1101073          # csrw mvendorid, x0: read-only CSR
    .word 0x00007003          # load funct3=111 (reserved)
    .word 0x00006003          # load funct3=110 (reserved in RV32)
    .word 0x00003023          # store funct3=011 (reserved in RV32)
    .word 0x00002063          # branch funct3=010 (reserved)
    .word 0x00001067          # jalr funct3=001 (reserved)
    .word 0x0000200f          # MISC-MEM funct3=010 (reserved)
    .word 0x0000302f          # AMO with funct3=011 (RV64 only)
    .word 0x1000202f | (5 << 20)  # lr.w with rs2 != 0 (reserved)
    .word 0x02000013 | (1 << 12)  # slli with imm[5]=1 (reserved in RV32)
    .half 0x0000              # c.unimp: all-zero halfword
    .half 0x4002              # c.lwsp with rd=x0 (reserved)

    # Traps at a halfword-aligned PC: mepc needs bit 1.
    .balign 4
    c.nop
    ecall
    c.nop
    .word 0x0000000b

    # Traps immediately behind memory traffic, a taken branch, and a CSR write.
    sw a3, 4(s0)
    ecall
    lw a4, 4(s0)
    ecall
    lw a4, 4(s0)
    add a5, a4, a4
    ebreak
    beq x0, x0, 1f
    ecall                     # wrong-path: must not trap
1:  csrw mscratch, a5
    ecall
    addi a6, a6, 1
    ecall
    addi a7, a7, 1            # the instruction after a trap still runs once

    # MRET to an explicit target restores MIE from MPIE and sets MPIE.
    la t0, 2f
    csrw mepc, t0
    li t1, 0x80
    csrw mstatus, t1
    mret
    addi a0, a0, 1            # skipped
2:  csrr a0, mstatus
    csrw mstatus, x0
LOCKSTEP_PASS

    .balign 4
trap_handler:
    csrr a0, mcause
    csrr a1, mepc
    csrr a2, mtval
    # Resume after the trapping instruction: 2 bytes if compressed.
    lhu t0, 0(a1)
    andi t0, t0, 3
    addi a1, a1, 2
    li t1, 3
    bne t0, t1, 1f
    addi a1, a1, 2
1:  csrw mepc, a1
    mret

LOCKSTEP_FOOTER

    .data
    .balign 16
scratch:
    .fill 16, 4, 0
