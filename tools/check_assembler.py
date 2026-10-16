#!/usr/bin/env python3
"""Cross-check tools/assemble_tests.py against GNU as.

The directed regression images are produced by the repo's own small
assembler, so an encoding bug there could make a test exercise the wrong
instruction. This generates every mnemonic it supports with random and edge
operands, assembles the same text with both assemblers, and compares the
encodings word for word.

  python3 tools/check_assembler.py [--count N] [--seed S]
"""

from __future__ import annotations

import argparse
import pathlib
import random
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import assemble_tests  # noqa: E402

AS = "riscv64-unknown-elf-as"
LD = "riscv64-unknown-elf-ld"
OBJCOPY = "riscv64-unknown-elf-objcopy"

R_OPS = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and",
         "mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"]
I_OPS = ["addi", "slti", "sltiu", "xori", "ori", "andi"]
SHIFTS = ["slli", "srli", "srai"]
LOADS = ["lb", "lh", "lw", "lbu", "lhu"]
STORES = ["sb", "sh", "sw"]
BRANCHES = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]
AMOS = ["amoswap.w", "amoadd.w", "amoxor.w", "amoand.w", "amoor.w",
        "amomin.w", "amomax.w", "amominu.w", "amomaxu.w"]
CSRS = ["0x300", "0x305", "0x340", "0x341", "0xB00", "0xC00"]


def x(rng: random.Random, lo: int = 0) -> str:
    return f"x{rng.randint(lo, 31)}"


def cx(rng: random.Random) -> str:
    return f"x{rng.randint(8, 15)}"


def imm(rng: random.Random, bits: int, signed: bool = True, align: int = 1) -> int:
    lo, hi = (-(1 << (bits - 1)), (1 << (bits - 1)) - 1) if signed else (0, (1 << bits) - 1)
    value = rng.choice([lo, hi, 0, 1, -1 if signed else 1, rng.randint(lo, hi)])
    return (value // align) * align


CHUNK = 32  # instructions between labels, so every branch offset is in range


def labels(i: int) -> tuple[str, str]:
    """Nearest label behind and ahead of instruction i."""
    return f"L{i // CHUNK}", f"L{i // CHUNK + 1}"


def gen_32bit(rng: random.Random, count: int) -> list[str]:
    lines = []
    for i in range(count):
        if i % CHUNK == 0:
            lines.append(f"L{i // CHUNK}:")
        back, fwd = labels(i)
        kind = rng.randrange(12)
        if kind == 0:
            lines.append(f"{rng.choice(R_OPS)} {x(rng)}, {x(rng)}, {x(rng)}")
        elif kind == 1:
            lines.append(f"{rng.choice(I_OPS)} {x(rng)}, {x(rng)}, {imm(rng, 12)}")
        elif kind == 2:
            lines.append(f"{rng.choice(SHIFTS)} {x(rng)}, {x(rng)}, {rng.randint(0, 31)}")
        elif kind == 3:
            lines.append(f"{rng.choice(LOADS)} {x(rng)}, {imm(rng, 12)}({x(rng)})")
        elif kind == 4:
            lines.append(f"{rng.choice(STORES)} {x(rng)}, {imm(rng, 12)}({x(rng)})")
        elif kind == 5:
            lines.append(f"{rng.choice(BRANCHES)} {x(rng)}, {x(rng)}, {rng.choice([back, fwd])}")
        elif kind == 6:
            lines.append(f"jal {x(rng)}, {rng.choice([back, fwd])}")
        elif kind == 7:
            lines.append(f"jalr {x(rng)}, {imm(rng, 12)}({x(rng)})")
        elif kind == 8:
            lines.append(f"{rng.choice(['lui', 'auipc'])} {x(rng)}, {imm(rng, 20, signed=False)}")
        elif kind == 9:
            op = rng.choice(["csrrw", "csrrs", "csrrc"])
            if rng.random() < 0.5:
                lines.append(f"{op} {x(rng)}, {rng.choice(CSRS)}, {x(rng)}")
            else:
                lines.append(f"{op}i {x(rng)}, {rng.choice(CSRS)}, {rng.randint(0, 31)}")
        elif kind == 10:
            sfx = rng.choice(["", ".aq", ".rl", ".aqrl"])
            choice = rng.randrange(3)
            if choice == 0:
                lines.append(f"lr.w{sfx} {x(rng)}, ({x(rng)})")
            elif choice == 1:
                lines.append(f"sc.w{sfx} {x(rng)}, {x(rng)}, ({x(rng)})")
            else:
                lines.append(f"{rng.choice(AMOS)}{sfx} {x(rng)}, {x(rng)}, ({x(rng)})")
        else:
            lines.append(rng.choice(["ecall", "ebreak", "mret", "fence.i"]))
    lines.append(f"L{count // CHUNK + 1}:")
    lines.append("addi x0, x0, 0")
    return lines


def gen_compressed(rng: random.Random, count: int) -> list[str]:
    lines = []
    nz6 = lambda: rng.choice([i for i in range(-32, 32) if i])  # noqa: E731
    for i in range(count):
        if i % CHUNK == 0:
            lines.append(f"L{i // CHUNK}:")
        back, fwd = labels(i)
        kind = rng.randrange(20)
        rd_nz = x(rng, 1)
        if kind == 0:
            lines.append(f"c.addi4spn {cx(rng)}, x2, {rng.randint(1, 255) * 4}")
        elif kind == 1:
            lines.append(f"c.lw {cx(rng)}, {rng.randint(0, 31) * 4}({cx(rng)})")
        elif kind == 2:
            lines.append(f"c.sw {cx(rng)}, {rng.randint(0, 31) * 4}({cx(rng)})")
        elif kind == 3:
            lines.append(f"c.addi {rd_nz}, {nz6()}")
        elif kind == 4:
            lines.append(f"c.li {rd_nz}, {rng.randint(-32, 31)}")
        elif kind == 5:
            lines.append(f"c.addi16sp x2, {nz6() * 16}")
        elif kind == 6:
            rd = rng.choice([r for r in range(1, 32) if r != 2])
            lines.append(f"c.lui x{rd}, {rng.choice([*range(-32, 0), *range(1, 32)])}")
        elif kind == 7:
            lines.append(f"{rng.choice(['c.srli', 'c.srai'])} {cx(rng)}, {rng.randint(1, 31)}")
        elif kind == 8:
            lines.append(f"c.andi {cx(rng)}, {rng.randint(-32, 31)}")
        elif kind == 9:
            lines.append(f"{rng.choice(['c.sub', 'c.xor', 'c.or', 'c.and'])} {cx(rng)}, {cx(rng)}")
        elif kind == 10:
            lines.append(f"{rng.choice(['c.j', 'c.jal'])} {rng.choice([back, fwd])}")
        elif kind == 11:
            lines.append(f"{rng.choice(['c.beqz', 'c.bnez'])} {cx(rng)}, {rng.choice([back, fwd])}")
        elif kind == 12:
            lines.append(f"c.slli {rd_nz}, {rng.randint(1, 31)}")
        elif kind == 13:
            lines.append(f"c.lwsp {rd_nz}, {rng.randint(0, 63) * 4}(x2)")
        elif kind == 14:
            lines.append(f"c.swsp {x(rng)}, {rng.randint(0, 63) * 4}(x2)")
        elif kind == 15:
            lines.append(f"{rng.choice(['c.jr', 'c.jalr'])} {rd_nz}")
        elif kind == 16:
            lines.append(f"c.mv {rd_nz}, {x(rng, 1)}")
        elif kind == 17:
            lines.append(f"c.add {rd_nz}, {x(rng, 1)}")
        elif kind == 18:
            lines.append("c.nop")
        else:
            lines.append("c.ebreak")
    lines.append(f"L{count // CHUNK + 1}:")
    lines.append("c.nop")
    lines.append("c.nop")
    return lines


def assemble_repo(lines: list[str], workdir: pathlib.Path) -> bytes:
    src = workdir / "repo.s"
    src.write_text(".text\n" + "\n".join(lines) + "\n")
    asm = assemble_tests.Assembler(src)
    asm.first_pass()
    image, _, _ = asm.second_pass()
    return bytes(image)


def assemble_gnu(lines: list[str], workdir: pathlib.Path, rvc: bool) -> bytes:
    src = workdir / "gnu.s"
    obj = workdir / "gnu.o"
    elf = workdir / "gnu.elf"
    binary = workdir / "gnu.bin"
    option = ".option rvc" if rvc else ".option norvc"
    # GNU as spells a negative c.lui immediate in its 20-bit form.
    lines = [re.sub(r"^(c\.lui x\d+, )(-\d+)$", lambda m: f"{m.group(1)}{int(m.group(2)) & 0xFFFFF:#x}", line)
             for line in lines]
    src.write_text(f".text\n{option}\n" + "\n".join(lines) + "\n")
    for cmd in (
        [AS, "-march=rv32imac_zicsr_zifencei", "-mabi=ilp32", "-mno-relax", str(src), "-o", str(obj)],
        [LD, "-m", "elf32lriscv", "-Ttext=0", "--no-relax", str(obj), "-o", str(elf)],
        [OBJCOPY, "-O", "binary", "-j", ".text", str(elf), str(binary)],
    ):
        result = subprocess.run(cmd, text=True, capture_output=True, check=False)
        if result.returncode != 0:
            raise SystemExit(f"{cmd[0]} failed:\n{result.stderr}")
    return binary.read_bytes()


def compare(name: str, lines: list[str], repo: bytes, gnu: bytes, unit: int) -> int:
    failures = 0
    body = [line for line in lines if not line.endswith(":")]
    for idx in range(len(gnu) // unit):
        want = int.from_bytes(gnu[idx * unit:(idx + 1) * unit], "little")
        got = int.from_bytes(repo[idx * unit:(idx + 1) * unit], "little")
        if want != got:
            failures += 1
            if failures <= 10:
                text = body[idx] if idx < len(body) else "?"
                print(f"ASM_CHECK {name} mismatch #{idx}: {text!r} gnu=0x{want:0{unit * 2}x} repo=0x{got:0{unit * 2}x}")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--count", type=int, default=3000)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--require", action="store_true", help="fail instead of skipping when GNU binutils is missing")
    args = parser.parse_args()

    if any(shutil.which(tool) is None for tool in (AS, LD, OBJCOPY)):
        print(f"ASM_CHECK status=skipped reason=missing_{AS}")
        return 1 if args.require else 0

    rng = random.Random(args.seed)
    failures = 0
    with tempfile.TemporaryDirectory(prefix="otter_asmchk_") as tmp:
        workdir = pathlib.Path(tmp)
        lines = gen_32bit(rng, args.count)
        failures += compare("rv32", lines, assemble_repo(lines, workdir), assemble_gnu(lines, workdir, rvc=False), 4)
        lines = gen_compressed(rng, args.count)
        failures += compare("rvc", lines, assemble_repo(lines, workdir), assemble_gnu(lines, workdir, rvc=True), 2)

    print(f"Assembler check: {2 * args.count} random instructions, {failures} encoding mismatches vs GNU as")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
