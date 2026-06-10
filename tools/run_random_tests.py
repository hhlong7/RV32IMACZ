#!/usr/bin/env python3
"""Generate and run deterministic randomized self-checking RV32IM tests."""

from __future__ import annotations

import os
import pathlib
import random
from collections import Counter
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
SIM = pathlib.Path("/tmp/otter_random_sim")
STOREBUF_SIM = pathlib.Path("/tmp/otter_storebuf_random_sim")
PASS_BASE = 600
FAIL_BASE = 900
SEEDS = [3, 11, 29, 47]
OPS_PER_TEST = 80
FRONTEND_PASS_BASE = 700
FRONTEND_FAIL_BASE = 1400
FRONTEND_SEEDS = [5, 17, 31, 59]
FRONTEND_OPS_PER_TEST = 24
DUAL_ISSUE_PASS_BASE = 800
DUAL_ISSUE_FAIL_BASE = 1800
DUAL_ISSUE_SEEDS = [7, 19, 43, 61]
DUAL_ISSUE_BLOCKS = 28
ATOMIC_PASS_BASE = 900
ATOMIC_FAIL_BASE = 2600
ATOMIC_SEEDS = [13, 37, 71, 89]
ATOMIC_OPS_PER_TEST = 20
ATOMIC_SCRATCH_WORDS = 8
LOG_DIR_ENV = os.environ.get("VERIF_LOG_DIR", "").strip()
LOG_DIR = pathlib.Path(LOG_DIR_ENV) if LOG_DIR_ENV else None

SIM_SOURCES = [
    "otter_defs_pkg.sv",
    "ALU.sv",
    "AtomicController.sv",
    "AtomicDecode.sv",
    "BAG.sv",
    "BCG.sv",
    "BranchPredictor.sv",
    "BranchGenerator.sv",
    "CSR_FILE.sv",
    "CU_DCDR.sv",
    "DualIssueInOrder.sv",
    "FrontendPacketBuilder.sv",
    "FourMux.sv",
    "Hazard.sv",
    "ImmediateGenerator.sv",
    "OTTER_MMIO.sv",
    "PC.sv",
    "PC_MUX.sv",
    "PC_REG.sv",
    "REG_FILE.sv",
    "RVCExpander.sv",
    "StoreBuffer.sv",
    "ThreeMux.sv",
    "TwoMux.sv",
    "cache.sv",
    "cachefsm.sv",
    "datacache.sv",
    "datacachefsm.sv",
    "imem.sv",
    "l2cache.sv",
    "otter_memory_v1_07.sv",
    "otter_mcu_pipeline_template_v2.sv",
    "tb_core.sv",
]

STOREBUF_SOURCES = [
    "StoreBuffer.sv",
    "tb_store_buffer.sv",
]

REGS = [
    ("t1", 6),
    ("t2", 7),
    ("t3", 28),
    ("t4", 29),
    ("t5", 30),
    ("t6", 31),
    ("a0", 10),
    ("a1", 11),
    ("a2", 12),
    ("a3", 13),
    ("a4", 14),
    ("a5", 15),
    ("s2", 18),
    ("s3", 19),
]
TMP_REG = "a6"
CHK_REG = "a7"
SCRATCH_BASE = "s1"
SSEG_REG = "s0"
REG_NUM = {
    "zero": 0,
    "ra": 1,
    "sp": 2,
    "gp": 3,
    "tp": 4,
    "t0": 5,
    "t1": 6,
    "t2": 7,
    "s0": 8,
    "fp": 8,
    "s1": 9,
    "a0": 10,
    "a1": 11,
    "a2": 12,
    "a3": 13,
    "a4": 14,
    "a5": 15,
    "a6": 16,
    "a7": 17,
    "s2": 18,
    "s3": 19,
    "s4": 20,
    "s5": 21,
    "s6": 22,
    "s7": 23,
    "s8": 24,
    "s9": 25,
    "s10": 26,
    "s11": 27,
    "t3": 28,
    "t4": 29,
    "t5": 30,
    "t6": 31,
}


def u32(value: int) -> int:
    return value & 0xFFFF_FFFF


def s32(value: int) -> int:
    value &= 0xFFFF_FFFF
    return value if value < 0x8000_0000 else value - 0x1_0000_0000


def riscv_div(a: int, b: int) -> int:
    sa = s32(a)
    sb = s32(b)
    if sb == 0:
        return 0xFFFF_FFFF
    if sa == -0x8000_0000 and sb == -1:
        return 0x8000_0000
    return u32(int(sa / sb))


def riscv_divu(a: int, b: int) -> int:
    if b == 0:
        return 0xFFFF_FFFF
    return u32((a & 0xFFFF_FFFF) // (b & 0xFFFF_FFFF))


def riscv_rem(a: int, b: int) -> int:
    sa = s32(a)
    sb = s32(b)
    if sb == 0:
        return u32(sa)
    if sa == -0x8000_0000 and sb == -1:
        return 0
    return u32(sa - int(sa / sb) * sb)


def riscv_remu(a: int, b: int) -> int:
    if b == 0:
        return u32(a)
    return u32((a & 0xFFFF_FFFF) % (b & 0xFFFF_FFFF))


def amo_result(op: str, old: int, operand: int) -> int:
    if op == "amoswap.w":
        return u32(operand)
    if op == "amoadd.w":
        return u32(old + operand)
    if op == "amoxor.w":
        return u32(old ^ operand)
    if op == "amoand.w":
        return u32(old & operand)
    if op == "amoor.w":
        return u32(old | operand)
    if op == "amomin.w":
        return old if s32(old) < s32(operand) else u32(operand)
    if op == "amomax.w":
        return old if s32(old) > s32(operand) else u32(operand)
    if op == "amominu.w":
        return old if u32(old) < u32(operand) else u32(operand)
    if op == "amomaxu.w":
        return old if u32(old) > u32(operand) else u32(operand)
    raise ValueError(f"unknown AMO op: {op}")


def emit_check(lines: list[str], reg: str, expected: int, fail_code: int) -> None:
    lines.append(f"    li {CHK_REG}, {s32(expected)}")
    lines.append(f"    bne {reg}, {CHK_REG}, fail_{fail_code}")


def encode_addi(rd: str, rs1: str, imm: int) -> int:
    imm12 = imm & 0xFFF
    return (imm12 << 20) | (REG_NUM[rs1] << 15) | (REG_NUM[rd] << 7) | 0x13


def build_program(seed: int, pass_code: int, fail_base: int, cov: Counter[str] | None = None) -> str:
    rng = random.Random(seed)
    reg_state = {idx: 0 for _, idx in REGS}
    scratch = [0] * 16
    lines = [
        ".eqv SSEG 0x11000040",
        "",
        ".data",
        "    .align 2",
        "scratch:",
        "    .space 64",
        "",
        ".text",
        ".globl main",
        "",
        "main:",
        f"    li {SSEG_REG}, SSEG",
        f"    la {SCRATCH_BASE}, scratch",
    ]

    fail_code = fail_base

    def choose_reg() -> tuple[str, int]:
        return rng.choice(REGS)

    for _ in range(OPS_PER_TEST):
        kind = rng.choice(["load_imm", "alu", "alui", "muldiv", "storeload", "branch"])
        if cov is not None:
            cov[f"base_{kind}"] += 1

        if kind == "load_imm":
            rd_name, rd_idx = choose_reg()
            imm = rng.randrange(-2048, 2048)
            reg_state[rd_idx] = u32(imm)
            lines.append(f"    li {rd_name}, {imm}")
            emit_check(lines, rd_name, reg_state[rd_idx], fail_code)
            fail_code += 1
            continue

        if kind == "alu":
            rd_name, rd_idx = choose_reg()
            rs1_name, rs1_idx = choose_reg()
            rs2_name, rs2_idx = choose_reg()
            op = rng.choice(["add", "sub", "xor", "or", "and", "sll", "srl", "sra", "slt", "sltu"])
            a = reg_state[rs1_idx]
            b = reg_state[rs2_idx]
            if op == "add":
                result = u32(a + b)
            elif op == "sub":
                result = u32(a - b)
            elif op == "xor":
                result = u32(a ^ b)
            elif op == "or":
                result = u32(a | b)
            elif op == "and":
                result = u32(a & b)
            elif op == "sll":
                result = u32(a << (b & 0x1F))
            elif op == "srl":
                result = u32((a & 0xFFFF_FFFF) >> (b & 0x1F))
            elif op == "sra":
                result = u32(s32(a) >> (b & 0x1F))
            elif op == "slt":
                result = 1 if s32(a) < s32(b) else 0
            else:
                result = 1 if (a & 0xFFFF_FFFF) < (b & 0xFFFF_FFFF) else 0
            reg_state[rd_idx] = u32(result)
            lines.append(f"    {op} {rd_name}, {rs1_name}, {rs2_name}")
            emit_check(lines, rd_name, reg_state[rd_idx], fail_code)
            fail_code += 1
            continue

        if kind == "alui":
            rd_name, rd_idx = choose_reg()
            rs1_name, rs1_idx = choose_reg()
            op = rng.choice(["addi", "xori", "ori", "andi", "slli", "srli", "srai"])
            if op in {"slli", "srli", "srai"}:
                imm = rng.randrange(0, 32)
            else:
                imm = rng.randrange(-2048, 2048)
            a = reg_state[rs1_idx]
            if op == "addi":
                result = u32(a + imm)
            elif op == "xori":
                result = u32(a ^ imm)
            elif op == "ori":
                result = u32(a | imm)
            elif op == "andi":
                result = u32(a & imm)
            elif op == "slli":
                result = u32(a << imm)
            elif op == "srli":
                result = u32((a & 0xFFFF_FFFF) >> imm)
            else:
                result = u32(s32(a) >> imm)
            reg_state[rd_idx] = u32(result)
            lines.append(f"    {op} {rd_name}, {rs1_name}, {imm}")
            emit_check(lines, rd_name, reg_state[rd_idx], fail_code)
            fail_code += 1
            continue

        if kind == "muldiv":
            rd_name, rd_idx = choose_reg()
            rs1_name, rs1_idx = choose_reg()
            rs2_name, rs2_idx = choose_reg()
            op = rng.choice(["mul", "div", "divu", "rem", "remu"])
            a = reg_state[rs1_idx]
            b = reg_state[rs2_idx]
            if op == "mul":
                result = u32(s32(a) * s32(b))
            elif op == "div":
                result = riscv_div(a, b)
            elif op == "divu":
                result = riscv_divu(a, b)
            elif op == "rem":
                result = riscv_rem(a, b)
            else:
                result = riscv_remu(a, b)
            reg_state[rd_idx] = u32(result)
            lines.append(f"    {op} {rd_name}, {rs1_name}, {rs2_name}")
            emit_check(lines, rd_name, reg_state[rd_idx], fail_code)
            fail_code += 1
            continue

        if kind == "storeload":
            rs_name, rs_idx = choose_reg()
            rd_name, rd_idx = choose_reg()
            slot = rng.randrange(0, len(scratch))
            offset = slot * 4
            scratch[slot] = reg_state[rs_idx]
            reg_state[rd_idx] = scratch[slot]
            lines.append(f"    sw {rs_name}, {offset}({SCRATCH_BASE})")
            lines.append(f"    lw {rd_name}, {offset}({SCRATCH_BASE})")
            emit_check(lines, rd_name, reg_state[rd_idx], fail_code)
            fail_code += 1
            continue

        rs1_name, rs1_idx = choose_reg()
        rs2_name, rs2_idx = choose_reg()
        lhs = reg_state[rs1_idx]
        rhs = reg_state[rs2_idx]
        br = rng.choice(["beq", "bne", "blt", "bge", "bltu", "bgeu"])
        if br == "beq":
            taken = lhs == rhs
        elif br == "bne":
            taken = lhs != rhs
        elif br == "blt":
            taken = s32(lhs) < s32(rhs)
        elif br == "bge":
            taken = s32(lhs) >= s32(rhs)
        elif br == "bltu":
            taken = (lhs & 0xFFFF_FFFF) < (rhs & 0xFFFF_FFFF)
        else:
            taken = (lhs & 0xFFFF_FFFF) >= (rhs & 0xFFFF_FFFF)
        if taken:
            lines.append(f"    {br} {rs1_name}, {rs2_name}, branch_ok_{fail_code}")
            lines.append(f"    j fail_{fail_code}")
            lines.append(f"branch_ok_{fail_code}:")
        else:
            lines.append(f"    {br} {rs1_name}, {rs2_name}, fail_{fail_code}")
        fail_code += 1

    lines.extend(
        [
            "",
            "pass:",
            f"    li t0, {pass_code}",
            f"    sw t0, 0({SSEG_REG})",
            "",
            "pass_loop:",
            "    j pass_loop",
            "",
        ]
    )

    for code in range(fail_base, fail_code):
        lines.extend(
            [
                f"fail_{code}:",
                f"    li t0, {code}",
                f"    sw t0, 0({SSEG_REG})",
                "fail_loop:",
                "    j fail_loop",
                "",
            ]
        )

    return "\n".join(lines)


def build_frontend_program(seed: int, pass_code: int, fail_base: int, cov: Counter[str] | None = None) -> str:
    rng = random.Random(seed)
    call_acc = 0
    patch_acc = 0
    lines = [
        ".eqv SSEG 0x11000040",
        "",
        ".text",
        ".globl main",
        "",
        "main:",
        f"    li {SSEG_REG}, SSEG",
        "    li s2, 0",
        "    li s3, 0",
        "    li s4, 0",
    ]

    fail_code = fail_base

    def maybe_align() -> None:
        # Periodically force target labels onto new cache lines so the random
        # control-flow stream exercises IF1/IF2 refill and predictor recovery.
        if rng.random() < 0.4:
            lines.append("    .align 5")

    for idx in range(FRONTEND_OPS_PER_TEST):
        kind = rng.choice(["branch", "jump", "call", "patch"])
        if cov is not None:
            cov[f"frontend_{kind}"] += 1

        if kind == "branch":
            lhs = rng.randrange(-32, 32)
            rhs = rng.randrange(-32, 32)
            br = rng.choice(["beq", "bne", "blt", "bge", "bltu", "bgeu"])
            lhs_u = u32(lhs)
            rhs_u = u32(rhs)
            if br == "beq":
                taken = lhs_u == rhs_u
            elif br == "bne":
                taken = lhs_u != rhs_u
            elif br == "blt":
                taken = s32(lhs_u) < s32(rhs_u)
            elif br == "bge":
                taken = s32(lhs_u) >= s32(rhs_u)
            elif br == "bltu":
                taken = lhs_u < rhs_u
            else:
                taken = lhs_u >= rhs_u

            lines.extend(
                [
                    f"    li t1, {lhs}",
                    f"    li t2, {rhs}",
                    "    li s4, 0",
                    f"    {br} t1, t2, frontend_branch_taken_{idx}",
                    "    li s4, 1",
                    f"    j frontend_branch_done_{idx}",
                ]
            )
            maybe_align()
            lines.extend(
                [
                    f"frontend_branch_taken_{idx}:",
                    "    li s4, 2",
                    f"frontend_branch_done_{idx}:",
                    f"    li t3, {2 if taken else 1}",
                    f"    bne s4, t3, fail_{fail_code}",
                ]
            )
            fail_code += 1
            continue

        if kind == "jump":
            marker = rng.randrange(1, 64)
            lines.extend(
                [
                    "    li s4, 0",
                    f"    jal x0, frontend_jump_target_{idx}",
                    f"    j fail_{fail_code}",
                ]
            )
            maybe_align()
            lines.extend(
                [
                    f"frontend_jump_target_{idx}:",
                    f"    li s4, {marker}",
                    f"    li t3, {marker}",
                    f"    bne s4, t3, fail_{fail_code}",
                ]
            )
            fail_code += 1
            continue

        if kind == "call":
            outer = rng.randrange(1, 8)
            nested = rng.random() < 0.5
            inner = rng.randrange(1, 8) if nested else 0
            call_acc += outer + inner
            lines.extend(
                [
                    f"    jal ra, frontend_call_outer_{idx}",
                    f"    j frontend_call_done_{idx}",
                ]
            )
            maybe_align()
            lines.extend(
                [
                    f"frontend_call_inner_{idx}:",
                    f"    addi s2, s2, {inner}",
                    "    jalr x0, 0(ra)",
                    f"frontend_call_outer_{idx}:",
                    f"    addi s2, s2, {outer}",
                ]
            )
            if nested:
                lines.extend(
                    [
                        # Save the outer return address across the nested call
                        # so the software expectation matches normal call/return
                        # stack behavior even without spilling to memory.
                        "    addi t4, ra, 0",
                        f"    jal ra, frontend_call_inner_{idx}",
                        "    addi ra, t4, 0",
                    ]
                )
            lines.extend(
                [
                    "    jalr x0, 0(ra)",
                    f"frontend_call_done_{idx}:",
                    f"    li t3, {call_acc}",
                    f"    bne s2, t3, fail_{fail_code}",
                ]
            )
            fail_code += 1
            continue

        patch_step = rng.randrange(1, 8)
        patch_acc += patch_step
        patch_insn = encode_addi("s3", "s3", patch_step)
        lines.extend(
            [
                f"    li t0, {s32(patch_insn)}",
                f"    la t1, frontend_patch_slot_{idx}",
                "    sw t0, 0(t1)",
                "    fence.i",
            ]
        )
        # Keep the patch slot immediately after fence.i so the randomized test
        # checks self-modifying-code visibility at the exact refetch point.
        lines.extend(
            [
                f"frontend_patch_slot_{idx}:",
                "    nop",
                f"    li t2, {patch_acc}",
                f"    bne s3, t2, fail_{fail_code}",
            ]
        )
        fail_code += 1

    lines.extend(
        [
            "",
            "pass:",
            f"    li t0, {pass_code}",
            f"    sw t0, 0({SSEG_REG})",
            "",
            "pass_loop:",
            "    j pass_loop",
            "",
        ]
    )

    for code in range(fail_base, fail_code):
        lines.extend(
            [
                f"fail_{code}:",
                f"    li t0, {code}",
                f"    sw t0, 0({SSEG_REG})",
                "fail_loop:",
                "    j fail_loop",
                "",
            ]
        )

    return "\n".join(lines)


def build_dual_issue_program(seed: int, pass_code: int, fail_base: int, cov: Counter[str] | None = None) -> str:
    rng = random.Random(seed)
    reg_state = {idx: 0 for _, idx in REGS}
    control_acc = 0
    lines = [
        ".eqv SSEG 0x11000040",
        "",
        ".text",
        ".globl main",
        "",
        "main:",
        f"    li {SSEG_REG}, SSEG",
        "    li s6, 0",
    ]

    fail_code = fail_base

    def choose_reg() -> tuple[str, int]:
        return rng.choice(REGS)

    def build_pairable_instr() -> dict[str, object]:
        kind = rng.choice(["alu", "alui"])
        rd_name, rd_idx = choose_reg()

        if kind == "alu":
            rs1_name, rs1_idx = choose_reg()
            rs2_name, rs2_idx = choose_reg()
            op = rng.choice(["add", "sub", "xor", "or", "and", "sll", "srl", "sra", "slt", "sltu"])
            a = reg_state[rs1_idx]
            b = reg_state[rs2_idx]
            if op == "add":
                result = u32(a + b)
            elif op == "sub":
                result = u32(a - b)
            elif op == "xor":
                result = u32(a ^ b)
            elif op == "or":
                result = u32(a | b)
            elif op == "and":
                result = u32(a & b)
            elif op == "sll":
                result = u32(a << (b & 0x1F))
            elif op == "srl":
                result = u32((a & 0xFFFF_FFFF) >> (b & 0x1F))
            elif op == "sra":
                result = u32(s32(a) >> (b & 0x1F))
            elif op == "slt":
                result = 1 if s32(a) < s32(b) else 0
            else:
                result = 1 if (a & 0xFFFF_FFFF) < (b & 0xFFFF_FFFF) else 0
            return {
                "asm": f"    {op} {rd_name}, {rs1_name}, {rs2_name}",
                "rd_name": rd_name,
                "rd_idx": rd_idx,
                "rs": {rs1_idx, rs2_idx},
                "result": u32(result),
            }

        rs1_name, rs1_idx = choose_reg()
        op = rng.choice(["addi", "xori", "ori", "andi", "slli", "srli", "srai"])
        if op in {"slli", "srli", "srai"}:
            imm = rng.randrange(0, 32)
        else:
            imm = rng.randrange(-2048, 2048)
        a = reg_state[rs1_idx]
        if op == "addi":
            result = u32(a + imm)
        elif op == "xori":
            result = u32(a ^ imm)
        elif op == "ori":
            result = u32(a | imm)
        elif op == "andi":
            result = u32(a & imm)
        elif op == "slli":
            result = u32(a << imm)
        elif op == "srli":
            result = u32((a & 0xFFFF_FFFF) >> imm)
        else:
            result = u32(s32(a) >> imm)
        return {
            "asm": f"    {op} {rd_name}, {rs1_name}, {imm}",
            "rd_name": rd_name,
            "rd_idx": rd_idx,
            "rs": {rs1_idx},
            "result": u32(result),
        }

    for idx in range(DUAL_ISSUE_BLOCKS):
        if cov is not None:
            cov["dual_pair_blocks"] += 1
        pair: list[dict[str, object]] = []
        while len(pair) < 2:
            cand = build_pairable_instr()
            if not pair:
                pair.append(cand)
                continue
            prev = pair[0]
            prev_rd = int(prev["rd_idx"])
            cand_rd = int(cand["rd_idx"])
            prev_rs = set(prev["rs"])
            cand_rs = set(cand["rs"])
            # Force a genuinely pairable bundle: independent sources and
            # distinct destinations, so failures point at issue logic instead
            # of a deliberately dependent test case.
            if cand_rd == prev_rd:
                continue
            if prev_rd in cand_rs or cand_rd in prev_rs:
                continue
            pair.append(cand)

        for instr in pair:
            reg_state[int(instr["rd_idx"])] = int(instr["result"])
            lines.append(instr["asm"])

        for instr in pair:
            emit_check(lines, str(instr["rd_name"]), int(instr["result"]), fail_code)
            fail_code += 1

        # Mix in younger control traffic after arithmetic pairs. This catches
        # bugs where a non-pairable instruction is buffered in slot 1 and later
        # slides up to become the oldest instruction.
        if rng.random() < 0.45:
            if cov is not None:
                cov["dual_control_blocks"] += 1
            step = rng.randrange(1, 8)
            control_acc += step
            lines.extend(
                [
                    f"    addi s6, s6, {step}",
                    f"    jal x0, dual_ctrl_ok_{idx}",
                    f"    j fail_{fail_code}",
                    f"dual_ctrl_ok_{idx}:",
                    f"    li t0, {control_acc}",
                    f"    bne s6, t0, fail_{fail_code}",
                ]
            )
            fail_code += 1

    lines.extend(
        [
            "",
            "pass:",
            f"    li t0, {pass_code}",
            f"    sw t0, 0({SSEG_REG})",
            "",
            "pass_loop:",
            "    j pass_loop",
            "",
        ]
    )

    for code in range(fail_base, fail_code):
        lines.extend(
            [
                f"fail_{code}:",
                f"    li t0, {code}",
                f"    sw t0, 0({SSEG_REG})",
                "fail_loop:",
                "    j fail_loop",
                "",
            ]
        )

    return "\n".join(lines)


def build_atomic_program(seed: int, pass_code: int, fail_base: int, cov: Counter[str] | None = None) -> str:
    rng = random.Random(seed)
    scratch = [u32(rng.getrandbits(32)) for _ in range(ATOMIC_SCRATCH_WORDS)]
    lines = [
        ".eqv SSEG 0x11000040",
        "",
        ".data",
        "    .align 2",
        "scratch:",
        *[f"    .word 0x{value:08x}" for value in scratch],
        "",
        ".text",
        ".globl main",
        "",
        "main:",
        f"    li {SSEG_REG}, SSEG",
        f"    la {SCRATCH_BASE}, scratch",
    ]

    fail_code = fail_base
    amo_ops = [
        "amoadd.w",
        "amoswap.w",
        "amoxor.w",
        "amoand.w",
        "amoor.w",
        "amomin.w",
        "amomax.w",
        "amominu.w",
        "amomaxu.w",
    ]
    suffixes = ["", ".aq", ".rl", ".aqrl"]

    for _ in range(ATOMIC_OPS_PER_TEST):
        kind = rng.choice(["amo", "lrsc_success", "lrsc_fail", "fence"])
        if cov is not None:
            cov[f"atomic_{kind}"] += 1
        slot = rng.randrange(0, len(scratch))
        offset = slot * 4

        if kind == "amo":
            op = rng.choice(amo_ops) + rng.choice(suffixes)
            operand = u32(rng.getrandbits(32))
            old = scratch[slot]
            scratch[slot] = amo_result(op.split(".", 2)[0] + ".w", old, operand)
            lines.append(f"    addi t0, {SCRATCH_BASE}, {offset}")
            lines.append(f"    li t1, {s32(operand)}")
            lines.append(f"    {op} t2, t1, (t0)")
            emit_check(lines, "t2", old, fail_code)
            fail_code += 1
            lines.append("    lw t3, 0(t0)")
            emit_check(lines, "t3", scratch[slot], fail_code)
            fail_code += 1
            continue

        if kind == "lrsc_success":
            other_slot = (slot + rng.randrange(1, len(scratch))) % len(scratch)
            other_offset = other_slot * 4
            old = scratch[slot]
            new_value = u32(rng.getrandbits(32))
            lines.append(f"    addi t0, {SCRATCH_BASE}, {offset}")
            lines.append("    lr.w.aq t2, (t0)")
            emit_check(lines, "t2", old, fail_code)
            fail_code += 1

            if rng.random() < 0.5:
                other_value = u32(rng.getrandbits(32))
                scratch[other_slot] = other_value
                lines.append(f"    addi t4, {SCRATCH_BASE}, {other_offset}")
                lines.append(f"    li t5, {s32(other_value)}")
                lines.append("    sw t5, 0(t4)")
                lines.append("    fence")
                lines.append("    lw t6, 0(t4)")
                emit_check(lines, "t6", other_value, fail_code)
                fail_code += 1

            lines.append(f"    li t1, {s32(new_value)}")
            lines.append("    sc.w.rl t3, t1, (t0)")
            emit_check(lines, "t3", 0, fail_code)
            fail_code += 1
            scratch[slot] = new_value
            lines.append("    lw t6, 0(t0)")
            emit_check(lines, "t6", new_value, fail_code)
            fail_code += 1
            continue

        if kind == "lrsc_fail":
            old = scratch[slot]
            intervening = u32(rng.getrandbits(32))
            final_attempt = u32(rng.getrandbits(32))
            lines.append(f"    addi t0, {SCRATCH_BASE}, {offset}")
            lines.append("    lr.w t2, (t0)")
            emit_check(lines, "t2", old, fail_code)
            fail_code += 1
            lines.append(f"    li t1, {s32(intervening)}")
            lines.append("    sw t1, 0(t0)")
            scratch[slot] = intervening
            lines.append(f"    li t4, {s32(final_attempt)}")
            lines.append("    sc.w t3, t4, (t0)")
            emit_check(lines, "t3", 1, fail_code)
            fail_code += 1
            lines.append("    lw t6, 0(t0)")
            emit_check(lines, "t6", intervening, fail_code)
            fail_code += 1
            continue

        # Exercise the stronger fence path on ordinary posted stores too.
        other_slot = (slot + rng.randrange(1, len(scratch))) % len(scratch)
        other_offset = other_slot * 4
        first = u32(rng.getrandbits(32))
        second = u32(rng.getrandbits(32))
        scratch[slot] = first
        scratch[other_slot] = second
        lines.append(f"    addi t0, {SCRATCH_BASE}, {offset}")
        lines.append(f"    addi t4, {SCRATCH_BASE}, {other_offset}")
        lines.append(f"    li t1, {s32(first)}")
        lines.append(f"    li t5, {s32(second)}")
        lines.append("    sw t1, 0(t0)")
        lines.append("    sw t5, 0(t4)")
        lines.append("    fence")
        lines.append("    lw t2, 0(t0)")
        emit_check(lines, "t2", first, fail_code)
        fail_code += 1
        lines.append("    lw t3, 0(t4)")
        emit_check(lines, "t3", second, fail_code)
        fail_code += 1

    lines.extend(
        [
            "",
            "pass:",
            f"    li t0, {pass_code}",
            f"    sw t0, 0({SSEG_REG})",
            "",
            "pass_loop:",
            "    j pass_loop",
            "",
        ]
    )

    for code in range(fail_base, fail_code):
        lines.extend(
            [
                f"fail_{code}:",
                f"    li t0, {code}",
                f"    sw t0, 0({SSEG_REG})",
                "fail_loop:",
                "    j fail_loop",
                "",
            ]
        )

    return "\n".join(lines)


def run(cmd: list[str], cwd: pathlib.Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, cwd=cwd, text=True, capture_output=True, check=False)


def extract_tb_line(sim_out: str, prefix: str) -> str:
    return next((line for line in sim_out.splitlines() if line.startswith(prefix)), "")


def emit_sim_summary(tag: str, seed: int, pass_code: int, sim_out: str) -> None:
    final_line = extract_tb_line(sim_out, "TB FINAL")
    stats_line = extract_tb_line(sim_out, "TB STATS")
    lsu_line = extract_tb_line(sim_out, "TB LSU")
    atom_line = extract_tb_line(sim_out, "TB ATOM")
    cov_line = extract_tb_line(sim_out, "TB COV")

    if final_line:
        print(f"{tag}_seed={seed} pass_code={pass_code} {final_line}")
    if stats_line:
        print(f"{tag}_seed={seed} {stats_line}")
    if lsu_line:
        print(f"{tag}_seed={seed} {lsu_line}")
    if atom_line:
        print(f"{tag}_seed={seed} {atom_line}")
    if cov_line:
        print(f"{tag}_seed={seed} {cov_line}")


def compile_sim() -> None:
    cmd = ["iverilog", "-g2012", "-o", str(SIM), *SIM_SOURCES]
    result = run(cmd, ROOT)
    if result.returncode != 0:
        sys.stderr.write(result.stdout)
        sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode)


def run_store_buffer_random_tb() -> None:
    compile_tb = run(["iverilog", "-g2012", "-o", str(STOREBUF_SIM), *STOREBUF_SOURCES], ROOT)
    if compile_tb.returncode != 0:
        sys.stderr.write(compile_tb.stdout)
        sys.stderr.write(compile_tb.stderr)
        raise SystemExit(compile_tb.returncode)

    sim = run(["vvp", str(STOREBUF_SIM)], ROOT)
    if sim.returncode != 0:
        sys.stderr.write(sim.stdout)
        sys.stderr.write(sim.stderr)
        raise SystemExit(sim.returncode)
    if "TB_STORE_BUFFER PASS" not in sim.stdout:
        sys.stderr.write(sim.stdout)
        sys.stderr.write(sim.stderr)
        raise SystemExit(1)
    print(next(line for line in sim.stdout.splitlines() if line.startswith("TB_STORE_BUFFER PASS")))


def main() -> int:
    if LOG_DIR is not None:
        LOG_DIR.mkdir(parents=True, exist_ok=True)

    random_cov = Counter()

    run_store_buffer_random_tb()
    compile_sim()

    with tempfile.TemporaryDirectory(prefix="otter_random_") as tmpdir:
        tmp = pathlib.Path(tmpdir)
        # First keep the original random arithmetic/dataflow coverage so the
        # deeper front end is still validated against the legacy test shape.
        for idx, seed in enumerate(SEEDS):
            pass_code = PASS_BASE + idx
            fail_base = FAIL_BASE + idx * 100
            asm_path = tmp / f"random_{seed}.s"
            mem_path = tmp / f"random_{seed}.mem"
            asm_path.write_text(build_program(seed, pass_code, fail_base, cov=random_cov), encoding="ascii")

            assemble = run(
                [
                    sys.executable,
                    "tools/assemble_tests.py",
                    str(asm_path),
                    "--out-dir",
                    str(tmp),
                ],
                ROOT,
            )
            if assemble.returncode != 0:
                sys.stderr.write(assemble.stdout)
                sys.stderr.write(assemble.stderr)
                return assemble.returncode

            generated_mem = tmp / f"{asm_path.stem}.mem"
            if not generated_mem.exists():
                raise FileNotFoundError(generated_mem)
            mem_path.write_text(generated_mem.read_text(encoding="ascii"), encoding="ascii")

            test_all = ROOT / "Test_All.mem"
            test_all.write_text(mem_path.read_text(encoding="ascii"), encoding="ascii")

            sim = run(
                [
                    "vvp",
                    str(SIM),
                    f"+PASS_SSEG={pass_code}",
                    "+FAIL_SSEG=-1",
                    "+MAX_CYCLES=20000",
                ],
                ROOT,
            )
            if sim.returncode != 0:
                sys.stderr.write(sim.stdout)
                sys.stderr.write(sim.stderr)
                return sim.returncode

            if f"TB PASS matched pass_sseg={pass_code}" not in sim.stdout:
                sys.stderr.write(sim.stdout)
                sys.stderr.write(sim.stderr)
                return 1

            if LOG_DIR is not None:
                (LOG_DIR / f"random_{seed}.log").write_text(sim.stdout, encoding="ascii")
            emit_sim_summary("base", seed, pass_code, sim.stdout)

        # Then run a front-end-focused stream that stresses redirects, returns,
        # and fence.i patch/refetch behavior specific to the IF1/IF2 split.
        for idx, seed in enumerate(FRONTEND_SEEDS):
            pass_code = FRONTEND_PASS_BASE + idx
            fail_base = FRONTEND_FAIL_BASE + idx * 100
            asm_path = tmp / f"frontend_random_{seed}.s"
            mem_path = tmp / f"frontend_random_{seed}.mem"
            asm_path.write_text(build_frontend_program(seed, pass_code, fail_base, cov=random_cov), encoding="ascii")

            assemble = run(
                [
                    sys.executable,
                    "tools/assemble_tests.py",
                    str(asm_path),
                    "--out-dir",
                    str(tmp),
                ],
                ROOT,
            )
            if assemble.returncode != 0:
                sys.stderr.write(assemble.stdout)
                sys.stderr.write(assemble.stderr)
                return assemble.returncode

            generated_mem = tmp / f"{asm_path.stem}.mem"
            if not generated_mem.exists():
                raise FileNotFoundError(generated_mem)
            mem_path.write_text(generated_mem.read_text(encoding="ascii"), encoding="ascii")

            test_all = ROOT / "Test_All.mem"
            test_all.write_text(mem_path.read_text(encoding="ascii"), encoding="ascii")

            sim = run(
                [
                    "vvp",
                    str(SIM),
                    f"+PASS_SSEG={pass_code}",
                    "+FAIL_SSEG=-1",
                    "+MAX_CYCLES=25000",
                ],
                ROOT,
            )
            if sim.returncode != 0:
                sys.stderr.write(sim.stdout)
                sys.stderr.write(sim.stderr)
                return sim.returncode

            if f"TB PASS matched pass_sseg={pass_code}" not in sim.stdout:
                sys.stderr.write(sim.stdout)
                sys.stderr.write(sim.stderr)
                return 1

            if LOG_DIR is not None:
                (LOG_DIR / f"frontend_{seed}.log").write_text(sim.stdout, encoding="ascii")
            emit_sim_summary("frontend", seed, pass_code, sim.stdout)

        # Finally, target the new in-order dual-issue queue directly. These
        # programs emit independent simple-op pairs followed by younger control
        # instructions, which catches both same-cycle pairing bugs and queue
        # metadata leaks that the legacy random streams rarely exercised.
        for idx, seed in enumerate(DUAL_ISSUE_SEEDS):
            pass_code = DUAL_ISSUE_PASS_BASE + idx
            fail_base = DUAL_ISSUE_FAIL_BASE + idx * 100
            asm_path = tmp / f"dual_issue_random_{seed}.s"
            mem_path = tmp / f"dual_issue_random_{seed}.mem"
            asm_path.write_text(build_dual_issue_program(seed, pass_code, fail_base, cov=random_cov), encoding="ascii")

            assemble = run(
                [
                    sys.executable,
                    "tools/assemble_tests.py",
                    str(asm_path),
                    "--out-dir",
                    str(tmp),
                ],
                ROOT,
            )
            if assemble.returncode != 0:
                sys.stderr.write(assemble.stdout)
                sys.stderr.write(assemble.stderr)
                return assemble.returncode

            generated_mem = tmp / f"{asm_path.stem}.mem"
            if not generated_mem.exists():
                raise FileNotFoundError(generated_mem)
            mem_path.write_text(generated_mem.read_text(encoding="ascii"), encoding="ascii")

            test_all = ROOT / "Test_All.mem"
            test_all.write_text(mem_path.read_text(encoding="ascii"), encoding="ascii")

            sim = run(
                [
                    "vvp",
                    str(SIM),
                    f"+PASS_SSEG={pass_code}",
                    "+FAIL_SSEG=-1",
                    "+MAX_CYCLES=25000",
                ],
                ROOT,
            )
            if sim.returncode != 0:
                sys.stderr.write(sim.stdout)
                sys.stderr.write(sim.stderr)
                return sim.returncode

            if f"TB PASS matched pass_sseg={pass_code}" not in sim.stdout:
                sys.stderr.write(sim.stdout)
                sys.stderr.write(sim.stderr)
                return 1

            if LOG_DIR is not None:
                (LOG_DIR / f"dual_{seed}.log").write_text(sim.stdout, encoding="ascii")
            emit_sim_summary("dual", seed, pass_code, sim.stdout)

        # Finally, randomize LR/SC reservation flow, AMO results, and the
        # stronger fence path so the new A-extension plumbing keeps old and new
        # memory ordering rules aligned.
        for idx, seed in enumerate(ATOMIC_SEEDS):
            pass_code = ATOMIC_PASS_BASE + idx
            fail_base = ATOMIC_FAIL_BASE + idx * 100
            asm_path = tmp / f"atomic_random_{seed}.s"
            mem_path = tmp / f"atomic_random_{seed}.mem"
            asm_path.write_text(build_atomic_program(seed, pass_code, fail_base, cov=random_cov), encoding="ascii")

            assemble = run(
                [
                    sys.executable,
                    "tools/assemble_tests.py",
                    str(asm_path),
                    "--out-dir",
                    str(tmp),
                ],
                ROOT,
            )
            if assemble.returncode != 0:
                sys.stderr.write(assemble.stdout)
                sys.stderr.write(assemble.stderr)
                return assemble.returncode

            generated_mem = tmp / f"{asm_path.stem}_full.mem"
            if not generated_mem.exists():
                raise FileNotFoundError(generated_mem)
            mem_path.write_text(generated_mem.read_text(encoding="ascii"), encoding="ascii")

            test_all = ROOT / "Test_All.mem"
            test_all.write_text(mem_path.read_text(encoding="ascii"), encoding="ascii")

            sim = run(
                [
                    "vvp",
                    str(SIM),
                    f"+PASS_SSEG={pass_code}",
                    "+FAIL_SSEG=-1",
                    "+MAX_CYCLES=25000",
                ],
                ROOT,
            )
            if sim.returncode != 0:
                sys.stderr.write(sim.stdout)
                sys.stderr.write(sim.stderr)
                return sim.returncode

            if f"TB PASS matched pass_sseg={pass_code}" not in sim.stdout:
                sys.stderr.write(sim.stdout)
                sys.stderr.write(sim.stderr)
                return 1

            if LOG_DIR is not None:
                (LOG_DIR / f"atomic_{seed}.log").write_text(sim.stdout, encoding="ascii")
            emit_sim_summary("atomic", seed, pass_code, sim.stdout)

    rand_cov_line = " ".join(f"{name}={value}" for name, value in sorted(random_cov.items()))
    print(f"RAND COV {rand_cov_line}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
