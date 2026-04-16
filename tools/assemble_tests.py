#!/usr/bin/env python3
"""Tiny assembler for the subset of RV32IMA/Zicsr/Zifencei used by this repo's tests."""

from __future__ import annotations

import argparse
import ast
import pathlib
import re
from dataclasses import dataclass


TEXT_BASE = 0x0000_0000
DATA_BASE = 0x0000_2000
MEM_BYTES = 64 * 1024
MEM_WORDS = MEM_BYTES // 4

REGISTER_NAMES = {
    **{f"x{i}": i for i in range(32)},
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


class ExprEvaluator(ast.NodeVisitor):
    def __init__(self, symbols: dict[str, int]) -> None:
        self.symbols = symbols

    def visit_Expression(self, node: ast.Expression) -> int:
        return self.visit(node.body)

    def visit_Name(self, node: ast.Name) -> int:
        if node.id not in self.symbols:
            raise KeyError(f"unknown symbol: {node.id}")
        return self.symbols[node.id]

    def visit_Constant(self, node: ast.Constant) -> int:
        if not isinstance(node.value, int):
            raise ValueError(f"unsupported constant: {node.value!r}")
        return int(node.value)

    def visit_UnaryOp(self, node: ast.UnaryOp) -> int:
        value = self.visit(node.operand)
        if isinstance(node.op, ast.UAdd):
            return value
        if isinstance(node.op, ast.USub):
            return -value
        if isinstance(node.op, ast.Invert):
            return ~value
        raise ValueError(f"unsupported unary op: {ast.dump(node.op)}")

    def visit_BinOp(self, node: ast.BinOp) -> int:
        left = self.visit(node.left)
        right = self.visit(node.right)
        if isinstance(node.op, ast.Add):
            return left + right
        if isinstance(node.op, ast.Sub):
            return left - right
        if isinstance(node.op, ast.BitOr):
            return left | right
        if isinstance(node.op, ast.BitAnd):
            return left & right
        if isinstance(node.op, ast.BitXor):
            return left ^ right
        if isinstance(node.op, ast.LShift):
            return left << right
        if isinstance(node.op, ast.RShift):
            return left >> right
        raise ValueError(f"unsupported binary op: {ast.dump(node.op)}")

    def generic_visit(self, node: ast.AST) -> int:
        raise ValueError(f"unsupported expression: {ast.dump(node)}")


def eval_expr(expr: str, symbols: dict[str, int]) -> int:
    expr = expr.strip()
    if re.fullmatch(r"[A-Za-z_.$][\w.$]*", expr):
        if expr not in symbols:
            raise KeyError(f"unknown symbol: {expr}")
        return symbols[expr]
    tree = ast.parse(expr, mode="eval")
    return ExprEvaluator(symbols).visit(tree)


def sign_extend(value: int, bits: int) -> int:
    mask = (1 << bits) - 1
    value &= mask
    sign = 1 << (bits - 1)
    return (value ^ sign) - sign


def check_signed(value: int, bits: int, what: str) -> int:
    lo = -(1 << (bits - 1))
    hi = (1 << (bits - 1)) - 1
    if value < lo or value > hi:
        raise ValueError(f"{what} out of range for {bits} bits: {value}")
    return value


def check_unsigned(value: int, bits: int, what: str) -> int:
    if value < 0 or value >= (1 << bits):
        raise ValueError(f"{what} out of range for {bits} bits: {value}")
    return value


def split_comment(line: str) -> str:
    for marker in ("#", "//"):
        idx = line.find(marker)
        if idx != -1:
            line = line[:idx]
    return line.strip()


def strip_labels(line: str) -> tuple[list[str], str]:
    labels: list[str] = []
    rest = line
    while True:
        match = re.match(r"^([A-Za-z_.$][\w.$]*):", rest)
        if not match:
            break
        labels.append(match.group(1))
        rest = rest[match.end() :].strip()
    return labels, rest


def parse_args_list(text: str) -> list[str]:
    if not text:
        return []
    return [part.strip() for part in text.split(",") if part.strip()]


def parse_reg(name: str) -> int:
    key = name.lower()
    if key not in REGISTER_NAMES:
        raise ValueError(f"unknown register: {name}")
    return REGISTER_NAMES[key]


def parse_compact_reg(name: str) -> int:
    reg = parse_reg(name)
    if reg < 8 or reg > 15:
        raise ValueError(f"compressed register must be x8-x15: {name}")
    return reg - 8


def parse_mem_operand(operand: str, symbols: dict[str, int]) -> tuple[int, int]:
    match = re.fullmatch(r"(.*)\(([^()]+)\)", operand.replace(" ", ""))
    if not match:
        raise ValueError(f"bad memory operand: {operand}")
    imm_text = match.group(1)
    imm = 0 if imm_text == "" else eval_expr(imm_text, symbols)
    rs1 = parse_reg(match.group(2))
    return imm, rs1


def encode_r(opcode: int, funct3: int, funct7: int, rd: int, rs1: int, rs2: int) -> int:
    return (
        ((funct7 & 0x7F) << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((rd & 0x1F) << 7)
        | (opcode & 0x7F)
    )


def encode_i(opcode: int, funct3: int, rd: int, rs1: int, imm: int) -> int:
    imm = check_signed(imm, 12, "I-immediate") & 0xFFF
    return (
        (imm << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((rd & 0x1F) << 7)
        | (opcode & 0x7F)
    )


def encode_shift_i(opcode: int, funct3: int, funct7: int, rd: int, rs1: int, shamt: int) -> int:
    shamt = check_unsigned(shamt, 5, "shift amount")
    imm = ((funct7 & 0x7F) << 5) | shamt
    return encode_i(opcode, funct3, rd, rs1, imm)


def encode_csr(funct3: int, rd: int, rs1_or_uimm: int, csr: int) -> int:
    csr = check_unsigned(csr, 12, "CSR address")
    return (
        ((csr & 0xFFF) << 20)
        | ((rs1_or_uimm & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((rd & 0x1F) << 7)
        | 0x73
    )


def encode_atomic(funct5: int, aq: int, rl: int, rd: int, rs1: int, rs2: int) -> int:
    funct7 = ((funct5 & 0x1F) << 2) | ((aq & 0x1) << 1) | (rl & 0x1)
    return encode_r(0x2F, 0x2, funct7, rd, rs1, rs2)


def parse_atomic_mnemonic(mnemonic: str) -> tuple[str, int, int] | None:
    m = mnemonic.lower()
    aq = 0
    rl = 0

    if m.endswith(".aqrl"):
        m = m[:-5]
        aq = 1
        rl = 1
    elif m.endswith(".aq"):
        m = m[:-3]
        aq = 1
    elif m.endswith(".rl"):
        m = m[:-3]
        rl = 1

    atomic_bases = {
        "lr.w",
        "sc.w",
        "amoswap.w",
        "amoadd.w",
        "amoxor.w",
        "amoand.w",
        "amoor.w",
        "amomin.w",
        "amomax.w",
        "amominu.w",
        "amomaxu.w",
    }
    if m not in atomic_bases:
        return None
    return m, aq, rl


def encode_s(opcode: int, funct3: int, rs1: int, rs2: int, imm: int) -> int:
    imm = check_signed(imm, 12, "S-immediate") & 0xFFF
    return (
        (((imm >> 5) & 0x7F) << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((imm & 0x1F) << 7)
        | (opcode & 0x7F)
    )


def encode_b(opcode: int, funct3: int, rs1: int, rs2: int, imm: int) -> int:
    if imm & 0x1:
        raise ValueError(f"branch target must be 2-byte aligned: {imm}")
    imm = check_signed(imm, 13, "B-immediate") & 0x1FFF
    return (
        (((imm >> 12) & 0x1) << 31)
        | (((imm >> 5) & 0x3F) << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | (((imm >> 1) & 0xF) << 8)
        | (((imm >> 11) & 0x1) << 7)
        | (opcode & 0x7F)
    )


def encode_u(opcode: int, rd: int, imm20: int) -> int:
    imm20 = check_unsigned(imm20 & 0xFFFFF, 20, "U-immediate")
    return (imm20 << 12) | ((rd & 0x1F) << 7) | (opcode & 0x7F)


def encode_j(opcode: int, rd: int, imm: int) -> int:
    if imm & 0x1:
        raise ValueError(f"jal target must be 2-byte aligned: {imm}")
    imm = check_signed(imm, 21, "J-immediate") & 0x1FFFFF
    return (
        (((imm >> 20) & 0x1) << 31)
        | (((imm >> 1) & 0x3FF) << 21)
        | (((imm >> 11) & 0x1) << 20)
        | (((imm >> 12) & 0xFF) << 12)
        | ((rd & 0x1F) << 7)
        | (opcode & 0x7F)
    )


COMPRESSED_MNEMONICS = {
    "c.addi4spn",
    "c.lw",
    "c.sw",
    "c.nop",
    "c.addi",
    "c.jal",
    "c.li",
    "c.addi16sp",
    "c.lui",
    "c.srli",
    "c.srai",
    "c.andi",
    "c.sub",
    "c.xor",
    "c.or",
    "c.and",
    "c.j",
    "c.beqz",
    "c.bnez",
    "c.slli",
    "c.lwsp",
    "c.jr",
    "c.mv",
    "c.ebreak",
    "c.jalr",
    "c.add",
    "c.swsp",
    "c.unimp",
}


def encode_compressed(mnemonic: str, args: list[str], pc: int, symbols: dict[str, int]) -> int:
    m = mnemonic.lower()

    if m == "c.unimp":
        return 0x0000

    if m == "c.nop":
        imm = 0 if not args else check_signed(eval_expr(args[0], symbols), 6, "c.nop immediate")
        imm &= 0x3F
        return (0b01) | (((imm >> 5) & 0x1) << 12) | ((imm & 0x1F) << 2)

    if m == "c.addi4spn":
        if len(args) == 3:
            rd_name, base_name, imm_text = args
            if parse_reg(base_name) != 2:
                raise ValueError("c.addi4spn base must be sp")
        elif len(args) == 2:
            rd_name, imm_text = args
        else:
            raise ValueError("c.addi4spn expects rd, imm or rd, sp, imm")

        rd_p = parse_compact_reg(rd_name)
        imm = check_unsigned(eval_expr(imm_text, symbols), 10, "c.addi4spn immediate")
        if imm == 0 or (imm & 0x3):
            raise ValueError("c.addi4spn immediate must be non-zero and 4-byte aligned")
        return ((rd_p & 0x7) << 2) | (((imm >> 2) & 0x1) << 6) | (((imm >> 6) & 0xF) << 7) | \
               (((imm >> 4) & 0x3) << 11) | (((imm >> 3) & 0x1) << 5)

    if m == "c.lw":
        rd_p = parse_compact_reg(args[0])
        imm, rs1 = parse_mem_operand(args[1], symbols)
        rs1_p = parse_compact_reg(f"x{rs1}")
        imm = check_unsigned(imm, 7, "c.lw offset")
        if imm & 0x3:
            raise ValueError("c.lw offset must be 4-byte aligned")
        return (0b010 << 13) | ((rd_p & 0x7) << 2) | ((rs1_p & 0x7) << 7) | \
               (((imm >> 6) & 0x1) << 5) | (((imm >> 3) & 0x7) << 10) | (((imm >> 2) & 0x1) << 6)

    if m == "c.sw":
        rs2_p = parse_compact_reg(args[0])
        imm, rs1 = parse_mem_operand(args[1], symbols)
        rs1_p = parse_compact_reg(f"x{rs1}")
        imm = check_unsigned(imm, 7, "c.sw offset")
        if imm & 0x3:
            raise ValueError("c.sw offset must be 4-byte aligned")
        return (0b110 << 13) | ((rs2_p & 0x7) << 2) | ((rs1_p & 0x7) << 7) | \
               (((imm >> 6) & 0x1) << 5) | (((imm >> 3) & 0x7) << 10) | (((imm >> 2) & 0x1) << 6)

    if m == "c.addi":
        rd = parse_reg(args[0])
        imm = check_signed(eval_expr(args[1], symbols), 6, "c.addi immediate") & 0x3F
        return (0b01) | (0b000 << 13) | ((rd & 0x1F) << 7) | (((imm >> 5) & 0x1) << 12) | ((imm & 0x1F) << 2)

    if m in {"c.jal", "c.j"}:
        offset = eval_expr(args[0], symbols) - pc
        offset = check_signed(offset, 12, f"{m} offset")
        if offset & 0x1:
            raise ValueError(f"{m} target must be 2-byte aligned")
        imm = offset & 0xFFF
        funct3 = 0b001 if m == "c.jal" else 0b101
        return (0b01) | (funct3 << 13) | (((imm >> 11) & 0x1) << 12) | (((imm >> 4) & 0x1) << 11) | \
               (((imm >> 8) & 0x3) << 9) | (((imm >> 10) & 0x1) << 8) | (((imm >> 6) & 0x1) << 7) | \
               (((imm >> 7) & 0x1) << 6) | (((imm >> 1) & 0x7) << 3) | (((imm >> 5) & 0x1) << 2)

    if m == "c.li":
        rd = parse_reg(args[0])
        imm = check_signed(eval_expr(args[1], symbols), 6, "c.li immediate") & 0x3F
        return (0b01) | (0b010 << 13) | ((rd & 0x1F) << 7) | (((imm >> 5) & 0x1) << 12) | ((imm & 0x1F) << 2)

    if m == "c.addi16sp":
        if len(args) == 2:
            if parse_reg(args[0]) != 2:
                raise ValueError("c.addi16sp destination must be sp")
            imm_text = args[1]
        elif len(args) == 1:
            imm_text = args[0]
        else:
            raise ValueError("c.addi16sp expects imm or sp, imm")
        imm = check_signed(eval_expr(imm_text, symbols), 10, "c.addi16sp immediate")
        if imm == 0 or (imm & 0xF):
            raise ValueError("c.addi16sp immediate must be non-zero and 16-byte aligned")
        imm &= 0x3FF
        return (0b01) | (0b011 << 13) | (2 << 7) | (((imm >> 9) & 0x1) << 12) | (((imm >> 7) & 0x3) << 3) | \
               (((imm >> 6) & 0x1) << 5) | (((imm >> 5) & 0x1) << 2) | (((imm >> 4) & 0x1) << 6)

    if m == "c.lui":
        rd = parse_reg(args[0])
        if rd == 2:
            raise ValueError("use c.addi16sp for stack-pointer adjustment")
        imm = check_signed(eval_expr(args[1], symbols), 6, "c.lui immediate")
        if imm == 0:
            raise ValueError("c.lui immediate must be non-zero")
        imm &= 0x3F
        return (0b01) | (0b011 << 13) | ((rd & 0x1F) << 7) | (((imm >> 5) & 0x1) << 12) | ((imm & 0x1F) << 2)

    if m in {"c.srli", "c.srai", "c.andi"}:
        rd_p = parse_compact_reg(args[0])
        funct2 = {"c.srli": 0b00, "c.srai": 0b01, "c.andi": 0b10}[m]
        if m == "c.andi":
            imm = check_signed(eval_expr(args[1], symbols), 6, f"{m} immediate") & 0x3F
            top_bit = (imm >> 5) & 0x1
        else:
            shamt = check_unsigned(eval_expr(args[1], symbols), 5, f"{m} shamt")
            imm = shamt
            top_bit = 0
        return (0b01) | (0b100 << 13) | (((top_bit if m == "c.andi" else 0) & 0x1) << 12) | \
               ((rd_p & 0x7) << 7) | ((funct2 & 0x3) << 10) | ((imm & 0x1F) << 2)

    if m in {"c.sub", "c.xor", "c.or", "c.and"}:
        rd_p = parse_compact_reg(args[0])
        rs2_p = parse_compact_reg(args[1])
        subop = {"c.sub": 0b000, "c.xor": 0b001, "c.or": 0b010, "c.and": 0b011}[m]
        return (0b01) | (0b100 << 13) | (0b11 << 10) | ((rd_p & 0x7) << 7) | \
               ((subop & 0x3) << 5) | ((rs2_p & 0x7) << 2)

    if m in {"c.beqz", "c.bnez"}:
        rs1_p = parse_compact_reg(args[0])
        offset = eval_expr(args[1], symbols) - pc
        offset = check_signed(offset, 9, f"{m} offset")
        if offset & 0x1:
            raise ValueError(f"{m} target must be 2-byte aligned")
        imm = offset & 0x1FF
        funct3 = 0b110 if m == "c.beqz" else 0b111
        return (0b01) | (funct3 << 13) | (((imm >> 8) & 0x1) << 12) | ((rs1_p & 0x7) << 7) | \
               (((imm >> 3) & 0x3) << 10) | (((imm >> 6) & 0x3) << 5) | (((imm >> 1) & 0x3) << 3) | (((imm >> 5) & 0x1) << 2)

    if m == "c.slli":
        rd = parse_reg(args[0])
        shamt = check_unsigned(eval_expr(args[1], symbols), 5, "c.slli shamt")
        return (0b10) | (0b000 << 13) | ((rd & 0x1F) << 7) | ((shamt & 0x1F) << 2)

    if m == "c.lwsp":
        rd = parse_reg(args[0])
        imm, rs1 = parse_mem_operand(args[1], symbols)
        if rs1 != 2:
            raise ValueError("c.lwsp base must be sp")
        if rd == 0:
            raise ValueError("c.lwsp destination cannot be x0")
        imm = check_unsigned(imm, 8, "c.lwsp offset")
        if imm & 0x3:
            raise ValueError("c.lwsp offset must be 4-byte aligned")
        return (0b10) | (0b010 << 13) | ((rd & 0x1F) << 7) | (((imm >> 5) & 0x1) << 12) | \
               (((imm >> 2) & 0x7) << 4) | (((imm >> 6) & 0x3) << 2)

    if m == "c.jr":
        rs1 = parse_reg(args[0])
        if rs1 == 0:
            raise ValueError("c.jr source cannot be x0")
        return (0b10) | (0b100 << 13) | ((rs1 & 0x1F) << 7)

    if m == "c.mv":
        rd = parse_reg(args[0])
        rs2 = parse_reg(args[1])
        if rs2 == 0:
            raise ValueError("c.mv source cannot be x0")
        return (0b10) | (0b100 << 13) | ((rd & 0x1F) << 7) | ((rs2 & 0x1F) << 2)

    if m == "c.ebreak":
        return (0b10) | (0b100 << 13) | (1 << 12)

    if m == "c.jalr":
        rs1 = parse_reg(args[0])
        if rs1 == 0:
            raise ValueError("c.jalr source cannot be x0")
        return (0b10) | (0b100 << 13) | (1 << 12) | ((rs1 & 0x1F) << 7)

    if m == "c.add":
        rd = parse_reg(args[0])
        rs2 = parse_reg(args[1])
        if rs2 == 0:
            raise ValueError("c.add source cannot be x0")
        return (0b10) | (0b100 << 13) | (1 << 12) | ((rd & 0x1F) << 7) | ((rs2 & 0x1F) << 2)

    if m == "c.swsp":
        rs2 = parse_reg(args[0])
        imm, rs1 = parse_mem_operand(args[1], symbols)
        if rs1 != 2:
            raise ValueError("c.swsp base must be sp")
        imm = check_unsigned(imm, 8, "c.swsp offset")
        if imm & 0x3:
            raise ValueError("c.swsp offset must be 4-byte aligned")
        return (0b10) | (0b110 << 13) | (((imm >> 2) & 0xF) << 9) | (((imm >> 6) & 0x3) << 7) | ((rs2 & 0x1F) << 2)

    raise ValueError(f"unsupported compressed instruction: {mnemonic}")


def hi20(value: int) -> int:
    return ((value + 0x800) >> 12) & 0xFFFFF


def lo12(value: int) -> int:
    hi = sign_extend(hi20(value), 20) << 12
    return sign_extend(value - hi, 12)


def instruction_size(mnemonic: str, args: list[str], symbols: dict[str, int]) -> int:
    # First-pass sizing only needs to model pseudos that may expand to two words.
    if mnemonic.lower() in COMPRESSED_MNEMONICS:
        return 2
    if mnemonic == "la":
        return 8
    if mnemonic == "li":
        imm = sign_extend(eval_expr(args[1], symbols), 32)
        return 4 if -2048 <= imm <= 2047 else 8
    return 4


@dataclass
class SourceLine:
    text: str
    lineno: int


class Assembler:
    def __init__(self, path: pathlib.Path) -> None:
        self.path = path
        self.lines = [SourceLine(line.rstrip("\n"), idx + 1) for idx, line in enumerate(path.read_text().splitlines())]
        self.eqv: dict[str, int] = {}
        self.labels: dict[str, int] = {}

    def first_pass(self) -> None:
        # Pass 1 resolves labels and pseudo sizes so forward branches/la/li can be encoded later.
        segment = "text"
        loc = {"text": TEXT_BASE, "data": DATA_BASE}

        for entry in self.lines:
            line = split_comment(entry.text)
            if not line:
                continue

            labels, rest = strip_labels(line)
            for label in labels:
                self.labels[label] = loc[segment]
            if not rest:
                continue

            if rest.startswith(".eqv"):
                _, name, expr = rest.split(None, 2)
                symbols = {**self.eqv, **self.labels}
                self.eqv[name] = eval_expr(expr, symbols)
                continue

            if rest == ".text":
                segment = "text"
                continue
            if rest == ".data":
                segment = "data"
                continue
            if rest.startswith(".globl"):
                continue
            if rest.startswith(".align"):
                _, expr = rest.split(None, 1)
                align = 1 << eval_expr(expr, {**self.eqv, **self.labels})
                loc[segment] = (loc[segment] + align - 1) & -align
                continue
            if rest.startswith(".word"):
                exprs = parse_args_list(rest[len(".word") :].strip())
                loc[segment] += 4 * len(exprs)
                continue
            if rest.startswith(".space"):
                _, expr = rest.split(None, 1)
                loc[segment] += eval_expr(expr, {**self.eqv, **self.labels})
                continue

            parts = rest.split(None, 1)
            mnemonic = parts[0].lower()
            args = parse_args_list(parts[1] if len(parts) > 1 else "")
            loc[segment] += instruction_size(mnemonic, args, {**self.eqv, **self.labels})

    def write_word(self, image: bytearray, addr: int, value: int) -> None:
        if addr < 0 or addr + 4 > MEM_BYTES:
            raise ValueError(f"address out of range: 0x{addr:08x}")
        value &= 0xFFFFFFFF
        image[addr + 0] = value & 0xFF
        image[addr + 1] = (value >> 8) & 0xFF
        image[addr + 2] = (value >> 16) & 0xFF
        image[addr + 3] = (value >> 24) & 0xFF

    def write_half(self, image: bytearray, addr: int, value: int) -> None:
        if addr < 0 or addr + 2 > MEM_BYTES:
            raise ValueError(f"address out of range: 0x{addr:08x}")
        if addr & 0x1:
            raise ValueError(f"halfword write must be 2-byte aligned: 0x{addr:08x}")
        value &= 0xFFFF
        image[addr + 0] = value & 0xFF
        image[addr + 1] = (value >> 8) & 0xFF

    def encode_real(self, mnemonic: str, args: list[str], pc: int, symbols: dict[str, int]) -> list[int]:
        m = mnemonic.lower()

        if m in COMPRESSED_MNEMONICS:
            return [encode_compressed(m, args, pc, symbols)]

        r_ops = {
            "add": (0x33, 0x0, 0x00),
            "sub": (0x33, 0x0, 0x20),
            "sll": (0x33, 0x1, 0x00),
            "slt": (0x33, 0x2, 0x00),
            "sltu": (0x33, 0x3, 0x00),
            "xor": (0x33, 0x4, 0x00),
            "srl": (0x33, 0x5, 0x00),
            "sra": (0x33, 0x5, 0x20),
            "or": (0x33, 0x6, 0x00),
            "and": (0x33, 0x7, 0x00),
            "mul": (0x33, 0x0, 0x01),
            "mulh": (0x33, 0x1, 0x01),
            "mulhsu": (0x33, 0x2, 0x01),
            "mulhu": (0x33, 0x3, 0x01),
            "div": (0x33, 0x4, 0x01),
            "divu": (0x33, 0x5, 0x01),
            "rem": (0x33, 0x6, 0x01),
            "remu": (0x33, 0x7, 0x01),
        }
        i_ops = {
            "addi": (0x13, 0x0),
            "slti": (0x13, 0x2),
            "sltiu": (0x13, 0x3),
            "xori": (0x13, 0x4),
            "ori": (0x13, 0x6),
            "andi": (0x13, 0x7),
            "lb": (0x03, 0x0),
            "lh": (0x03, 0x1),
            "lw": (0x03, 0x2),
            "lbu": (0x03, 0x4),
            "lhu": (0x03, 0x5),
            "jalr": (0x67, 0x0),
        }
        s_ops = {
            "sb": (0x23, 0x0),
            "sh": (0x23, 0x1),
            "sw": (0x23, 0x2),
        }
        b_ops = {
            "beq": (0x63, 0x0),
            "bne": (0x63, 0x1),
            "blt": (0x63, 0x4),
            "bge": (0x63, 0x5),
            "bltu": (0x63, 0x6),
            "bgeu": (0x63, 0x7),
        }
        csr_ops = {
            "csrrw": 0x1,
            "csrrs": 0x2,
            "csrrc": 0x3,
            "csrrwi": 0x5,
            "csrrsi": 0x6,
            "csrrci": 0x7,
        }

        if m in r_ops:
            rd, rs1, rs2 = map(parse_reg, args)
            opcode, funct3, funct7 = r_ops[m]
            return [encode_r(opcode, funct3, funct7, rd, rs1, rs2)]

        if m in {"slli", "srli", "srai"}:
            rd = parse_reg(args[0])
            rs1 = parse_reg(args[1])
            shamt = eval_expr(args[2], symbols)
            funct7 = 0x20 if m == "srai" else 0x00
            funct3 = 0x1 if m == "slli" else 0x5
            return [encode_shift_i(0x13, funct3, funct7, rd, rs1, shamt)]

        if m in i_ops:
            opcode, funct3 = i_ops[m]
            rd = parse_reg(args[0])
            if m in {"lb", "lh", "lw", "lbu", "lhu"}:
                imm, rs1 = parse_mem_operand(args[1], symbols)
            elif m == "jalr" and "(" in args[1]:
                imm, rs1 = parse_mem_operand(args[1], symbols)
            else:
                rs1 = parse_reg(args[1])
                imm = eval_expr(args[2], symbols)
            return [encode_i(opcode, funct3, rd, rs1, imm)]

        if m in s_ops:
            opcode, funct3 = s_ops[m]
            rs2 = parse_reg(args[0])
            imm, rs1 = parse_mem_operand(args[1], symbols)
            return [encode_s(opcode, funct3, rs1, rs2, imm)]

        if m in b_ops:
            opcode, funct3 = b_ops[m]
            rs1 = parse_reg(args[0])
            rs2 = parse_reg(args[1])
            imm = eval_expr(args[2], symbols) - pc
            return [encode_b(opcode, funct3, rs1, rs2, imm)]

        if m == "jal":
            if len(args) == 1:
                rd = 1
                target = eval_expr(args[0], symbols)
            else:
                rd = parse_reg(args[0])
                target = eval_expr(args[1], symbols)
            return [encode_j(0x6F, rd, target - pc)]

        if m == "lui":
            rd = parse_reg(args[0])
            imm20 = eval_expr(args[1], symbols)
            return [encode_u(0x37, rd, imm20)]

        if m == "auipc":
            rd = parse_reg(args[0])
            imm20 = eval_expr(args[1], symbols)
            return [encode_u(0x17, rd, imm20)]

        if m in csr_ops:
            rd = parse_reg(args[0])
            csr = eval_expr(args[1], symbols)
            funct3 = csr_ops[m]
            if funct3 & 0x4:
                rs1 = check_unsigned(eval_expr(args[2], symbols), 5, "CSR immediate")
            else:
                rs1 = parse_reg(args[2])
            word = encode_csr(funct3, rd, rs1, csr)
            return [word]

        atomic_spec = parse_atomic_mnemonic(m)
        if atomic_spec is not None:
            base, aq, rl = atomic_spec
            funct5_map = {
                "lr.w": 0b00010,
                "sc.w": 0b00011,
                "amoswap.w": 0b00001,
                "amoadd.w": 0b00000,
                "amoxor.w": 0b00100,
                "amoand.w": 0b01100,
                "amoor.w": 0b01000,
                "amomin.w": 0b10000,
                "amomax.w": 0b10100,
                "amominu.w": 0b11000,
                "amomaxu.w": 0b11100,
            }
            rd = parse_reg(args[0])
            funct5 = funct5_map[base]

            if base == "lr.w":
                imm, rs1 = parse_mem_operand(args[1], symbols)
                if imm != 0:
                    raise ValueError("lr.w only supports zero offset in this assembler")
                rs2 = 0
            else:
                rs2 = parse_reg(args[1])
                imm, rs1 = parse_mem_operand(args[2], symbols)
                if imm != 0:
                    raise ValueError(f"{base} only supports zero offset in this assembler")

            return [encode_atomic(funct5, aq, rl, rd, rs1, rs2)]

        if m == "ecall":
            return [0x0000_0073]
        if m == "ebreak":
            return [0x0010_0073]
        if m == "mret":
            return [0x3020_0073]
        if m == "fence.i":
            return [0x0000_100F]
        if m == "fence":
            return [0x0FF0_000F]

        if m == "nop":
            return [encode_i(0x13, 0x0, 0, 0, 0)]
        if m == "j":
            target = eval_expr(args[0], symbols)
            return [encode_j(0x6F, 0, target - pc)]
        if m == "li":
            rd = parse_reg(args[0])
            imm = sign_extend(eval_expr(args[1], symbols), 32)
            if -2048 <= imm <= 2047:
                return [encode_i(0x13, 0x0, rd, 0, imm)]
            hi = hi20(imm)
            lo = lo12(imm)
            return [encode_u(0x37, rd, hi), encode_i(0x13, 0x0, rd, rd, lo)]
        if m == "la":
            rd = parse_reg(args[0])
            target = eval_expr(args[1], symbols)
            delta = target - pc
            hi = hi20(delta)
            lo = lo12(delta)
            return [encode_u(0x17, rd, hi), encode_i(0x13, 0x0, rd, rd, lo)]

        raise ValueError(f"unsupported instruction: {mnemonic}")

    def second_pass(self) -> tuple[bytearray, int, int]:
        # Pass 2 emits one flat 64 KiB image that matches the memory model used by the testbench.
        image = bytearray(MEM_BYTES)
        segment = "text"
        loc = {"text": TEXT_BASE, "data": DATA_BASE}
        highest = 0
        highest_text = 0
        symbols = {**self.eqv, **self.labels}

        for entry in self.lines:
            line = split_comment(entry.text)
            if not line:
                continue

            _, rest = strip_labels(line)
            if not rest:
                continue

            if rest.startswith(".eqv"):
                continue
            if rest == ".text":
                segment = "text"
                continue
            if rest == ".data":
                segment = "data"
                continue
            if rest.startswith(".globl"):
                continue
            if rest.startswith(".align"):
                _, expr = rest.split(None, 1)
                align = 1 << eval_expr(expr, symbols)
                loc[segment] = (loc[segment] + align - 1) & -align
                continue
            if rest.startswith(".word"):
                exprs = parse_args_list(rest[len(".word") :].strip())
                for expr in exprs:
                    value = eval_expr(expr, symbols)
                    self.write_word(image, loc[segment], value)
                    highest = max(highest, loc[segment] + 4)
                    if segment == "text":
                        highest_text = max(highest_text, loc[segment] + 4)
                    loc[segment] += 4
                continue
            if rest.startswith(".space"):
                _, expr = rest.split(None, 1)
                loc[segment] += eval_expr(expr, symbols)
                highest = max(highest, loc[segment])
                if segment == "text":
                    highest_text = max(highest_text, loc[segment])
                continue

            parts = rest.split(None, 1)
            mnemonic = parts[0]
            args = parse_args_list(parts[1] if len(parts) > 1 else "")
            words = self.encode_real(mnemonic, args, loc[segment], symbols)
            is_compressed = mnemonic.lower() in COMPRESSED_MNEMONICS
            for word in words:
                if is_compressed:
                    self.write_half(image, loc[segment], word)
                    width = 2
                else:
                    self.write_word(image, loc[segment], word)
                    width = 4
                highest = max(highest, loc[segment] + width)
                if segment == "text":
                    highest_text = max(highest_text, loc[segment] + width)
                loc[segment] += width

        return image, highest_text, highest


def emit_mem(path: pathlib.Path, image: bytearray, words: int) -> None:
    lines = []
    for idx in range(words):
        base = idx * 4
        value = (
            image[base + 0]
            | (image[base + 1] << 8)
            | (image[base + 2] << 16)
            | (image[base + 3] << 24)
        )
        lines.append(f"{value:08x}")
    path.write_text("\n".join(lines) + ("\n" if lines else ""))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("inputs", nargs="+", type=pathlib.Path)
    parser.add_argument("--out-dir", type=pathlib.Path, default=pathlib.Path("test_files/generated"))
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)

    for asm_path in args.inputs:
        assembler = Assembler(asm_path)
        assembler.first_pass()
        image, highest_text, highest = assembler.second_pass()

        stem = asm_path.stem
        # Keep the legacy instruction-only .mem format for normal tests, but also emit
        # a full image for cases that rely on initialized data memory.
        compact_words = max(1, (highest_text + 3) // 4)
        emit_mem(args.out_dir / f"{stem}.mem", image, compact_words)
        emit_mem(args.out_dir / f"{stem}_full.mem", image, MEM_WORDS)


if __name__ == "__main__":
    main()
