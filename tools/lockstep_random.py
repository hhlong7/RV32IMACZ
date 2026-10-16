#!/usr/bin/env python3
"""Seeded random program generator for tools/lockstep.py.

Spike is the oracle, so generated programs never check their own results.
That frees the generator to aim at microarchitectural corners instead:

  * dense read-after-write chains (forwarding from every stage and both lanes)
  * independent simple ALU ops back to back (dual-issue pairing)
  * a 16/32-bit instruction mix, so 32-bit instructions straddle words
  * loads right after stores to the same bytes (store-buffer forwarding)
  * branches, bounded loops, calls/returns (BHT, BTB and RAS training)
  * atomics, CSR read-modify-write, fence and fence.i
  * synchronous traps (ecall, ebreak, illegal, misaligned) in random
    pipeline states; a resume handler steps over the trapping instruction

Register conventions inside generated programs:
  x2 (sp), x9 (s1)  base pointers into the data area (compressed loads/stores)
  x3 (gp)           base pointer at the middle of the data area
  x31               loop counter
Everything else is fair game, including ra/t0 which also drive the RAS.

  python3 tools/lockstep_random.py 42 > /tmp/random_42.s
"""

from __future__ import annotations

import random
import sys

DATA_WORDS = 1024  # 4 KB data area
BASE_REGS = {2, 3, 9}
LOOP_REG = 31
FREE_REGS = [r for r in range(1, 31) if r not in BASE_REGS]
# Compressed register-register forms only reach x8-x15.
C_REGS = [r for r in range(8, 16) if r not in BASE_REGS]

EDGE_VALUES = [
    0, 1, 2, 31, 32, 0x7FF, 0x800, 0xFFF, 0x7FFF_FFFF, 0x8000_0000,
    0x8000_0001, 0xFFFF_FFFF, 0xFFFF_FFFE, 0x0000_FFFF, 0xFFFF_0000,
    0x5555_5555, 0xAAAA_AAAA,
]

R_OPS = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"]
M_OPS = ["mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"]
I_OPS = ["addi", "slti", "sltiu", "xori", "ori", "andi"]
SHIFT_I_OPS = ["slli", "srli", "srai"]
LOADS = [("lb", 1), ("lh", 2), ("lw", 4), ("lbu", 1), ("lhu", 2)]
STORES = [("sb", 1), ("sh", 2), ("sw", 4)]
BRANCHES = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]
AMOS = ["amoswap.w", "amoadd.w", "amoxor.w", "amoand.w", "amoor.w",
        "amomin.w", "amomax.w", "amominu.w", "amomaxu.w"]


class Generator:
    def __init__(self, seed: int, free_regs: list[int] | None = None, label_prefix: str = "r") -> None:
        self.rng = random.Random(seed)
        self.seed = seed
        self.free = free_regs or FREE_REGS
        self.c_regs = [r for r in C_REGS if r in self.free]
        self.lines: list[str] = []
        self.label_prefix = label_prefix
        self.label_id = 0
        self.recent: list[int] = []  # recently written registers, newest last

    # -- helpers ---------------------------------------------------------

    def emit(self, text: str) -> None:
        self.lines.append("    " + text)

    def emit32(self, text: str) -> None:
        self.emit(f"I32 {text}")

    def label(self) -> str:
        self.label_id += 1
        return f".L{self.label_prefix}{self.label_id}"

    def wrote(self, reg: int) -> None:
        if reg:
            self.recent = (self.recent + [reg])[-4:]

    def src(self, pool: list[int] | None = None, allow_zero: bool = True) -> int:
        """Pick a source, strongly biased toward fresh results."""
        pool = pool or self.free
        fresh = [r for r in self.recent if r in pool]
        if fresh and self.rng.random() < 0.6:
            return self.rng.choice(fresh)
        if allow_zero and self.rng.random() < 0.05:
            return 0
        return self.rng.choice(pool)

    def csrc(self) -> int:
        """Source for a compressed x8-x15 form (x0 is not encodable)."""
        return self.src(self.c_regs, allow_zero=False)

    def dst(self, pool: list[int] | None = None) -> int:
        return self.rng.choice(pool or self.free)

    def imm12(self) -> int:
        if self.rng.random() < 0.3:
            return self.rng.choice([0, 1, -1, 2047, -2048, 0x7F, -0x80])
        return self.rng.randint(-2048, 2047)

    def value(self) -> int:
        if self.rng.random() < 0.5:
            return self.rng.choice(EDGE_VALUES)
        return self.rng.getrandbits(32)

    # -- instruction groups ----------------------------------------------

    def gen_li(self) -> None:
        rd = self.dst()
        self.emit32(f"li x{rd}, {self.value():#x}")
        self.wrote(rd)

    def gen_alu(self) -> None:
        rd, a, b = self.dst(), self.src(), self.src()
        op = self.rng.choice(R_OPS + M_OPS if self.rng.random() < 0.35 else R_OPS)
        self.emit32(f"{op} x{rd}, x{a}, x{b}")
        self.wrote(rd)

    def gen_alu_imm(self) -> None:
        rd, a = self.dst(), self.src()
        if self.rng.random() < 0.3:
            op = self.rng.choice(SHIFT_I_OPS)
            self.emit32(f"{op} x{rd}, x{a}, {self.rng.randint(0, 31)}")
        else:
            self.emit32(f"{self.rng.choice(I_OPS)} x{rd}, x{a}, {self.imm12()}")
        self.wrote(rd)

    def gen_upper(self) -> None:
        rd = self.dst()
        op = self.rng.choice(["lui", "auipc"])
        self.emit32(f"{op} x{rd}, {self.rng.getrandbits(20):#x}")
        self.wrote(rd)

    def gen_compressed_alu(self) -> None:
        choice = self.rng.randrange(9)
        if choice == 0:
            rd = self.dst()
            imm = self.rng.randint(-32, 31) or 1
            self.emit(f"c.addi x{rd}, {imm}")
        elif choice == 1:
            rd = self.dst()
            self.emit(f"c.li x{rd}, {self.rng.randint(-32, 31)}")
        elif choice == 2:
            rd = self.dst()
            imm = self.rng.choice([*range(1, 0x20), *range(0xFFFE0, 0x100000)])
            self.emit(f"c.lui x{rd}, {imm:#x}")
        elif choice == 3:
            rd, rs = self.dst(), self.src(allow_zero=False)
            self.emit(f"c.mv x{rd}, x{rs}")
        elif choice == 4:
            rd, rs = self.dst(), self.src(allow_zero=False)
            self.emit(f"c.add x{rd}, x{rs}")
        elif choice == 5:
            rd, rs = self.dst(self.c_regs), self.csrc()
            op = self.rng.choice(["c.sub", "c.xor", "c.or", "c.and"])
            self.emit(f"{op} x{rd}, x{rs}")
        elif choice == 6:
            rd = self.dst(self.c_regs)
            op = self.rng.choice(["c.srli", "c.srai"])
            self.emit(f"{op} x{rd}, {self.rng.randint(1, 31)}")
        elif choice == 7:
            rd = self.dst(self.c_regs)
            self.emit(f"c.andi x{rd}, {self.rng.randint(-32, 31)}")
        else:
            rd = self.dst()
            self.emit(f"c.slli x{rd}, {self.rng.randint(1, 31)}")
        self.wrote(rd)

    def data_offset(self, size: int) -> int:
        """Offset from gp (middle of the data area), aligned to the size."""
        off = self.rng.randrange(-2048, 2048 - size + 1)
        if self.rng.random() < 0.5:
            off = self.rng.randrange(-64, 64)  # hot region => more aliasing
        return off & ~(size - 1)

    def gen_load(self) -> None:
        op, size = self.rng.choice(LOADS)
        rd = self.dst()
        self.emit32(f"{op} x{rd}, {self.data_offset(size)}(gp)")
        self.wrote(rd)

    def gen_store(self) -> None:
        op, size = self.rng.choice(STORES)
        self.emit32(f"{op} x{self.src()}, {self.data_offset(size)}(gp)")

    def gen_store_load_pair(self) -> None:
        """Store then load overlapping bytes: store-buffer forward/conflict paths."""
        sop, ssize = self.rng.choice(STORES)
        lop, lsize = self.rng.choice(LOADS)
        base = self.rng.randrange(-64, 64) & ~3
        soff = base + (self.rng.randrange(0, 4) & ~(ssize - 1))
        loff = base + (self.rng.randrange(0, 4) & ~(lsize - 1))
        self.emit32(f"{sop} x{self.src()}, {soff}(gp)")
        for _ in range(self.rng.randrange(0, 3)):
            self.gen_alu()
        rd = self.dst()
        self.emit32(f"{lop} x{rd}, {loff}(gp)")
        self.wrote(rd)
        if self.rng.random() < 0.5:  # immediate consumer => load-use stall
            rd2 = self.dst()
            self.emit32(f"add x{rd2}, x{rd}, x{self.src()}")
            self.wrote(rd2)

    def gen_store_burst(self) -> None:
        """Back-to-back stores that overflow the 4-entry store buffer."""
        for _ in range(self.rng.randint(5, 9)):
            op, size = self.rng.choice(STORES)
            self.emit32(f"{op} x{self.src()}, {self.data_offset(size)}(gp)")
        if self.rng.random() < 0.5:
            self.gen_load()

    def gen_compressed_mem(self) -> None:
        rd = self.dst(self.c_regs)
        choice = self.rng.randrange(4)
        off = self.rng.randrange(0, 32) * 4
        if choice == 0:
            self.emit(f"c.lw x{rd}, {off}(x9)")
            self.wrote(rd)
        elif choice == 1:
            self.emit(f"c.sw x{self.csrc()}, {off}(x9)")
        elif choice == 2:
            rd = self.dst()
            self.emit(f"c.lwsp x{rd}, {self.rng.randrange(0, 64) * 4}(sp)")
            self.wrote(rd)
        else:
            self.emit(f"c.swsp x{self.src()}, {self.rng.randrange(0, 64) * 4}(sp)")

    def gen_atomic(self) -> None:
        off = self.rng.randrange(-16, 16) * 4
        addr = self.dst()
        self.emit32(f"addi x{addr}, gp, {off}")
        rd = self.dst([r for r in self.free if r != addr])  # keep the address live for SC
        if self.rng.random() < 0.35:
            # LR/SC pair. Whether a same-hart store between them breaks the
            # reservation is implementation-defined (Spike keeps it, this core
            # clears it), so only a mismatched SC address is used to force a
            # deterministic failure.
            self.emit32(f"lr.w x{rd}, (x{addr})")
            if self.rng.random() < 0.3:
                other = self.dst([r for r in self.free if r not in (addr, rd)])
                self.emit32(f"addi x{other}, x{addr}, 4")
                addr = other
            rd2 = self.dst()  # may clobber the address: SC is its last use
            self.emit32(f"sc.w x{rd2}, x{self.src()}, (x{addr})")
            self.wrote(rd2)
        else:
            op = self.rng.choice(AMOS)
            suffix = self.rng.choice(["", ".aq", ".rl", ".aqrl"])
            self.emit32(f"{op}{suffix} x{rd}, x{self.src()}, (x{addr})")
        self.wrote(rd)

    def gen_csr(self) -> None:
        # mscratch belongs to the trap handler; mtval is fully writable and
        # traps overwrite it identically on both models.
        rd = self.dst()
        op = self.rng.choice(["csrrw", "csrrs", "csrrc"])
        if self.rng.random() < 0.5:
            self.emit32(f"{op} x{rd}, mtval, x{self.src()}")
        else:
            self.emit32(f"{op}i x{rd}, mtval, {self.rng.randrange(32)}")
        self.wrote(rd)

    def gen_trap(self) -> None:
        choice = self.rng.randrange(6)
        if choice == 0:
            self.emit32("ecall")
        elif choice == 1:
            self.emit(self.rng.choice(["I32 ebreak", "c.ebreak"]))
        elif choice == 2:
            self.emit(self.rng.choice([".word 0x0000000b", ".half 0x0000", ".word 0x02001033"]))
        elif choice == 3:
            op, size = self.rng.choice([("lh", 2), ("lhu", 2), ("lw", 4)])
            rd = self.dst()
            self.emit32(f"{op} x{rd}, {(self.data_offset(4) | 1)}(gp)")
        elif choice == 4:
            op = self.rng.choice(["sh", "sw"])
            self.emit32(f"{op} x{self.src()}, {(self.data_offset(4) | 2) - (1 if op == 'sh' else 0)}(gp)")
        else:
            addr = self.dst()
            self.emit32(f"addi x{addr}, gp, {self.rng.randrange(-16, 16) * 4 + 2}")
            self.emit32(f"amoadd.w x{self.dst()}, x{self.src()}, (x{addr})")

    def gen_fence(self) -> None:
        self.emit32(self.rng.choice(["fence", "fence rw, rw", "fence.i"]))

    def gen_forward_branch(self) -> None:
        target = self.label()
        if self.rng.random() < 0.25:
            op = self.rng.choice(["c.beqz", "c.bnez"])
            self.emit(f"{op} x{self.csrc()}, {target}")
        else:
            self.emit32(f"{self.rng.choice(BRANCHES)} x{self.src()}, x{self.src()}, {target}")
        for _ in range(self.rng.randrange(0, 4)):
            self.gen_simple()
        self.lines.append(f"{target}:")

    def gen_jump(self) -> None:
        target = self.label()
        if self.rng.random() < 0.5:
            self.emit("c.j " + target)
        else:
            self.emit32(f"jal x{self.rng.choice([0, 0, self.dst()])}, {target}")
        for _ in range(self.rng.randrange(1, 3)):
            self.gen_simple()  # skipped
        self.lines.append(f"{target}:")

    def gen_loop(self) -> None:
        top = self.label()
        self.emit32(f"li x{LOOP_REG}, {self.rng.randint(2, 6)}")
        self.lines.append(f"{top}:")
        for _ in range(self.rng.randrange(2, 7)):
            self.gen_simple()
        self.emit32(f"addi x{LOOP_REG}, x{LOOP_REG}, -1")
        self.emit32(f"bnez x{LOOP_REG}, {top}")

    def gen_call(self) -> None:
        """Call a nearby leaf function: exercises the RAS and BTB.

        The function is emitted inline and jumped over, so short c.jal/c.j
        offsets always reach it.
        """
        name, skip = self.label(), self.label()
        leaf = Generator(
            self.rng.getrandbits(32),
            free_regs=[r for r in self.free if r not in (1, 5)],  # keep the link intact
            label_prefix=f"{self.label_prefix}f{self.label_id}_",
        )
        for _ in range(self.rng.randrange(1, 6)):
            leaf.gen_simple()

        self.emit(f"c.j {skip}" if self.rng.random() < 0.5 else f"I32 jal x0, {skip}")
        self.lines.append(f"{name}:")
        self.lines.extend(leaf.lines)
        self.emit(self.rng.choice(["ret", "c.jr x1", "I32 jalr x0, 0(x1)"]))
        self.lines.append(f"{skip}:")

        style = self.rng.randrange(3)
        if style == 0:
            self.emit32(f"jal x1, {name}")
        elif style == 1:
            self.emit(f"c.jal {name}")
        else:
            tmp = self.rng.choice([r for r in self.free if r != 1])
            self.emit32(f"la x{tmp}, {name}")
            self.emit(f"c.jalr x{tmp}" if self.rng.random() < 0.5 else f"I32 jalr x1, 0(x{tmp})")
        self.wrote(1)

    def gen_simple(self) -> None:
        r = self.rng.random()
        if r < 0.30:
            self.gen_alu()
        elif r < 0.50:
            self.gen_alu_imm()
        elif r < 0.75:
            self.gen_compressed_alu()
        elif r < 0.82:
            self.gen_upper()
        elif r < 0.90:
            self.gen_load()
        else:
            self.gen_store()

    # -- program ---------------------------------------------------------

    def generate(self, length: int = 400) -> str:
        weighted = [
            (self.gen_simple, 40),
            (self.gen_li, 4),
            (self.gen_store_load_pair, 8),
            (self.gen_store_burst, 2),
            (self.gen_compressed_mem, 6),
            (self.gen_atomic, 4),
            (self.gen_csr, 2),
            (self.gen_fence, 1),
            (self.gen_forward_branch, 8),
            (self.gen_jump, 3),
            (self.gen_loop, 2),
            (self.gen_call, 3),
            (self.gen_trap, 2),
        ]
        funcs, weights = zip(*weighted)

        # Seed every free register so early reads are interesting.
        for reg in self.free + [LOOP_REG]:
            self.emit32(f"li x{reg}, {self.value():#x}")
        while len(self.lines) < length:
            self.rng.choices(funcs, weights)[0]()

        data = [f"    .word {self.rng.getrandbits(32):#010x}" for _ in range(DATA_WORDS)]
        return "\n".join(
            [
                f"# Random lockstep program, seed {self.seed}. Generated by tools/lockstep_random.py.",
                '.include "harness.inc"',
                "LOCKSTEP_START",
                "    la t0, resume_handler",
                "    csrw mtvec, t0",
                "    la gp, lockstep_data + 2048",
                "    la x9, lockstep_data",
                "    la sp, lockstep_data + 1024",
                *self.lines,
                "    LOCKSTEP_PASS",
                "",
                "    .balign 4",
                "resume_handler:",
                "    csrw mscratch, t0",
                "    csrr t0, mepc",
                "    lhu t0, 0(t0)",
                "    andi t0, t0, 3",
                "    addi t0, t0, -3",
                "    beqz t0, 1f",
                "    csrr t0, mepc",
                "    addi t0, t0, 2",
                "    j 2f",
                "1:  csrr t0, mepc",
                "    addi t0, t0, 4",
                "2:  csrw mepc, t0",
                "    csrr t0, mscratch",
                "    mret",
                "",
                "LOCKSTEP_FOOTER",
                "",
                "    .data",
                "    .balign 16",
                "lockstep_data:",
                *data,
                "",
            ]
        )


def generate(seed: int) -> str:
    return Generator(seed).generate()


if __name__ == "__main__":
    print(generate(int(sys.argv[1]) if len(sys.argv) > 1 else 1))
