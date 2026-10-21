#!/usr/bin/env python3
"""Lockstep verification of the OTTER core against Spike.

Each program is assembled with GNU as, run on Spike (the RISC-V reference ISA
simulator) and on the RTL, and the two retirement traces are compared:

  * every retired instruction: PC, destination register, and written value
  * every architectural memory write: address, data, and size

Programs come from test_files/lockstep/*.s (directed) and from
tools/lockstep_random.py (seeded random streams). Unlike the self-checking
regression tests, nothing here trusts the program to know the right answer.

  python3 tools/lockstep.py                    # all directed programs
  python3 tools/lockstep.py --random 200       # directed + 200 random seeds
  python3 tools/lockstep.py test_files/lockstep/rv32m.s --keep out/ls
"""

from __future__ import annotations

import argparse
import concurrent.futures
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import lockstep_random  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[1]
LOCKSTEP_DIR = ROOT / "test_files" / "lockstep"
LINKER_SCRIPT = LOCKSTEP_DIR / "link.ld"

# F covers the core's single-precision subset (fadd/fsub/fmul/fdiv, flw/fsw);
# test programs only use those FP instructions.
ISA = "rv32imafc_zicsr_zifencei"
TEXT_BASE = 0x2000
MEM_BYTES = 64 * 1024
PASS_CODE = 1337
FAIL_CODE = 2989
MAX_CYCLES = 400_000
SPIKE_MAX_INSTRUCTIONS = 2_000_000
SPIKE_MEMORY = "-m0x2000:0xE000,0x11000000:0x1000"

AS = os.environ.get("RISCV_AS", "riscv64-unknown-elf-as")
LD = os.environ.get("RISCV_LD", "riscv64-unknown-elf-ld")
OBJCOPY = os.environ.get("RISCV_OBJCOPY", "riscv64-unknown-elf-objcopy")
SPIKE = os.environ.get("SPIKE", "spike")

def encode_jal(rd: int, offset: int) -> int:
    imm = offset & 0x1F_FFFF
    return (
        ((imm >> 20) & 1) << 31
        | ((imm >> 1) & 0x3FF) << 21
        | ((imm >> 11) & 1) << 20
        | ((imm >> 12) & 0xFF) << 12
        | rd << 7
        | 0x6F
    )


# "j 0x2000" placed at the RTL reset vector; Spike enters through its boot ROM.
TRAMPOLINE = encode_jal(0, TEXT_BASE)


@dataclass(frozen=True)
class Retire:
    pc: int
    rd: int
    value: int
    text: str = ""

    # rd 1-31 are x registers, 32-63 are f0-f31, 0 means no register write.
    def key(self) -> tuple[int, int, int]:
        return (self.pc, self.rd, self.value if self.rd else 0)

    def __str__(self) -> str:
        name = f"f{self.rd - 32}" if self.rd >= 32 else f"x{self.rd}"
        reg = f"{name}=0x{self.value:08x}" if self.rd else "no reg write"
        return f"pc=0x{self.pc:08x} {reg}" + (f"   [{self.text}]" if self.text else "")


@dataclass(frozen=True)
class Store:
    addr: int
    data: int
    size: int  # 0=byte, 1=half, 2=word

    def __str__(self) -> str:
        width = 2 << self.size
        return f"[0x{self.addr:08x}] <- 0x{self.data:0{width}x} ({1 << self.size}B)"


@dataclass
class Trace:
    retires: list[Retire]
    stores: list[Store]


@dataclass
class Result:
    name: str
    ok: bool
    detail: str
    retired: int = 0


def run(cmd: list[str], cwd: pathlib.Path | None = None, timeout: int = 600) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, cwd=cwd, text=True, capture_output=True, timeout=timeout, check=False)


# ---------------------------------------------------------------------------
# Build


def build_program(source: pathlib.Path, workdir: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path]:
    """Assemble and link one program; return (elf, rtl_memory_image)."""
    obj = workdir / "prog.o"
    elf = workdir / "prog.elf"
    binary = workdir / "prog.bin"
    mem = workdir / "Test_All.mem"

    for cmd in (
        [AS, f"-march={ISA}", "-mabi=ilp32", "-I", str(LOCKSTEP_DIR), str(source), "-o", str(obj)],
        [LD, "-m", "elf32lriscv", "-T", str(LINKER_SCRIPT), str(obj), "-o", str(elf)],
        [OBJCOPY, "-O", "binary", str(elf), str(binary)],
    ):
        result = run(cmd)
        if result.returncode != 0:
            raise RuntimeError(f"{cmd[0]} failed:\n{result.stdout}{result.stderr}")

    # objcopy's flat binary starts at the lowest loaded address (TEXT_BASE).
    image = bytearray(MEM_BYTES)
    payload = binary.read_bytes()
    if TEXT_BASE + len(payload) > MEM_BYTES:
        raise RuntimeError(f"{source.name}: image does not fit in 64 KB")
    image[TEXT_BASE : TEXT_BASE + len(payload)] = payload
    image[0:4] = TRAMPOLINE.to_bytes(4, "little")

    words = (int.from_bytes(image[i : i + 4], "little") for i in range(0, MEM_BYTES, 4))
    mem.write_text("".join(f"{w:08x}\n" for w in words))
    return elf, mem


def compile_rtl(out: pathlib.Path) -> None:
    # IVERILOG_FLAGS passes build options through, e.g. -DOTTER_TRUE_LRU.
    extra = shlex.split(os.environ.get("IVERILOG_FLAGS", ""))
    result = run(["iverilog", "-g2012", *extra, "-o", str(out), "-c", str(ROOT / "rtl.f"), str(ROOT / "tb_core.sv")],
                 cwd=ROOT)
    if result.returncode != 0:
        raise RuntimeError(f"iverilog failed:\n{result.stdout}{result.stderr}")


# ---------------------------------------------------------------------------
# Trace capture

_SPIKE_COMMIT = re.compile(r"^core\s+\d+:\s+3\s+0x([0-9a-f]+)\s+\((0x[0-9a-f]+)\)(.*)$")
_SPIKE_DISASM = re.compile(r"^core\s+\d+:\s+0x([0-9a-f]+)\s+\(0x[0-9a-f]+\)\s+(.*)$")


def parse_spike_log(text: str) -> Trace:
    retires: list[Retire] = []
    stores: list[Store] = []
    disasm: dict[int, str] = {}

    for line in text.splitlines():
        m = _SPIKE_DISASM.match(line)
        if m:
            disasm[int(m.group(1), 16)] = m.group(2).strip()
            continue
        m = _SPIKE_COMMIT.match(line)
        if not m:
            continue
        pc = int(m.group(1), 16)
        if pc < TEXT_BASE:
            continue  # boot ROM

        rd, value = 0, 0
        tokens = m.group(3).split()
        i = 0
        while i < len(tokens):
            tok = tokens[i]
            if re.fullmatch(r"x\d+", tok):
                rd, value = int(tok[1:]), int(tokens[i + 1], 16)
                i += 2
            elif re.fullmatch(r"f\d+", tok):
                rd, value = 32 + int(tok[1:]), int(tokens[i + 1], 16)
                i += 2
            elif tok == "mem":
                addr = int(tokens[i + 1], 16)
                if i + 2 < len(tokens) and tokens[i + 2].startswith("0x"):
                    data_tok = tokens[i + 2]
                    size = {2: 0, 4: 1, 8: 2}[len(data_tok) - 2]
                    stores.append(Store(addr, int(data_tok, 16), size))
                    i += 3
                else:
                    i += 2  # load: address only
            else:
                i += 2  # CSR write or other "name value" pair
        retires.append(Retire(pc, rd, value, disasm.get(pc, "")))

    return Trace(retires, stores)


def run_spike(elf: pathlib.Path, workdir: pathlib.Path) -> Trace:
    log = workdir / "spike.log"
    result = run(
        [
            SPIKE,
            f"--instructions={SPIKE_MAX_INSTRUCTIONS}",
            f"--isa={ISA}",
            "--priv=m",
            SPIKE_MEMORY,
            "-l",
            "--log-commits",
            f"--log={log}",
            str(elf),
        ],
        timeout=120,
    )
    if result.returncode != 0:
        raise RuntimeError(f"spike failed rc={result.returncode}:\n{result.stdout}{result.stderr}")
    return parse_spike_log(log.read_text())


def parse_rtl_log(text: str) -> Trace:
    retires: list[Retire] = []
    stores: list[Store] = []
    for line in text.splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "R":
            pc = int(parts[1], 16)
            if pc >= TEXT_BASE:
                retires.append(Retire(pc, int(parts[2]), int(parts[3], 16)))
        elif parts[0] == "S":
            size = int(parts[3])
            mask = (1 << (8 << size)) - 1
            stores.append(Store(int(parts[1], 16), int(parts[2], 16) & mask, size))
    return Trace(retires, stores)


def run_rtl(sim: pathlib.Path, workdir: pathlib.Path) -> tuple[Trace, str]:
    log = workdir / "rtl_commits.log"
    # $readmemh("Test_All.mem") resolves relative to the cwd, so each program
    # runs in its own directory and never touches the repo's Test_All.mem.
    result = run(
        [
            "vvp",
            "-n",
            str(sim),
            f"+PASS_SSEG={PASS_CODE}",
            f"+FAIL_SSEG={FAIL_CODE}",
            f"+MAX_CYCLES={MAX_CYCLES}",
            f"+COMMIT_LOG={log}",
        ],
        cwd=workdir,
    )
    output = result.stdout + result.stderr
    (workdir / "rtl.out").write_text(output)
    trace = parse_rtl_log(log.read_text()) if log.exists() else Trace([], [])
    return trace, output


# ---------------------------------------------------------------------------
# Comparison


def first_store_index(trace: Trace, addr: int) -> int | None:
    for idx, store in enumerate(trace.stores):
        if store.addr == addr:
            return idx
    return None


def compare(rtl: Trace, ref: Trace, rtl_output: str) -> tuple[bool, str]:
    # The testbench stops when the pass/fail code reaches the SSEG register, so
    # the RTL trace is a prefix of Spike's. Everything Spike retired before the
    # SSEG store must also have retired, identically, on the RTL.
    sseg = 0x1100_0040
    ref_sseg = first_store_index(ref, sseg)
    if ref_sseg is None:
        return False, "Spike never reached the SSEG pass/fail store (runaway program?)"

    for idx, (got, want) in enumerate(zip(rtl.retires, ref.retires)):
        if got.key() != want.key():
            lo = max(0, idx - 4)
            context = "\n".join(f"      {r}" for r in ref.retires[lo:idx])
            return False, (
                f"retire #{idx} differs\n"
                f"    spike: {want}\n"
                f"    rtl:   {got}\n"
                f"    preceding (spike):\n{context}"
            )

    for idx, (got, want) in enumerate(zip(rtl.stores, ref.stores)):
        if (got.addr, got.data, got.size) != (want.addr, want.data, want.size):
            return False, f"memory write #{idx} differs\n    spike: {want}\n    rtl:   {got}"

    if len(rtl.stores) < ref_sseg + 1:
        tail = "\n".join(line for line in rtl_output.splitlines() if line.startswith(("TB", "ASSERT", "ATOMIC", "Result")))
        return False, (
            f"RTL stopped after {len(rtl.stores)} memory writes / {len(rtl.retires)} retires; "
            f"Spike needed {ref_sseg + 1} writes to reach SSEG\n{tail}"
        )

    sseg_store = ref.stores[ref_sseg]
    if sseg_store.data == FAIL_CODE:
        return False, "program took an unexpected trap (both models agree)"
    if "TB PASS" not in rtl_output:
        return False, "RTL did not report TB PASS:\n" + rtl_output[-2000:]
    asserts = [line for line in rtl_output.splitlines() if line.startswith("ASSERT_FAIL")]
    if asserts:
        return False, "RTL testbench assertion failed:\n" + "\n".join(asserts[:10])
    return True, ""


def run_one(name: str, source: pathlib.Path, sim: pathlib.Path, workdir: pathlib.Path) -> Result:
    workdir.mkdir(parents=True, exist_ok=True)
    try:
        elf, _ = build_program(source, workdir)
        ref = run_spike(elf, workdir)
        rtl, output = run_rtl(sim, workdir)
    except (RuntimeError, subprocess.TimeoutExpired) as exc:
        return Result(name, False, str(exc))
    ok, detail = compare(rtl, ref, output)
    return Result(name, ok, detail, retired=len(rtl.retires))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("programs", nargs="*", type=pathlib.Path, help="lockstep .s programs (default: all directed)")
    parser.add_argument("--random", type=int, default=0, metavar="N", help="also run N random programs")
    parser.add_argument("--seed-base", type=int, default=1, help="first random seed")
    parser.add_argument("--no-directed", action="store_true", help="skip directed programs")
    parser.add_argument("--keep", type=pathlib.Path, help="keep per-program artifacts in this directory")
    parser.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 4)
    parser.add_argument("-v", "--verbose", action="store_true", help="also list every passing program")
    parser.add_argument("--require", action="store_true", help="fail instead of skipping when a tool is missing")
    args = parser.parse_args()

    for tool in (AS, LD, OBJCOPY, SPIKE, "iverilog", "vvp"):
        if shutil.which(tool) is None:
            print(f"LOCKSTEP status=skipped reason=missing_{pathlib.Path(tool).name}")
            return 1 if args.require else 0

    work_root = args.keep or pathlib.Path(tempfile.mkdtemp(prefix="otter_lockstep_"))
    work_root.mkdir(parents=True, exist_ok=True)
    sim = work_root / "otter_tb.vvp"
    compile_rtl(sim)

    jobs: list[tuple[str, pathlib.Path]] = []
    if args.programs:
        jobs += [(p.stem, p.resolve()) for p in args.programs]
    elif not args.no_directed:
        jobs += [(p.stem, p) for p in sorted(LOCKSTEP_DIR.glob("*.s"))]

    random_dir = work_root / "random_src"
    random_dir.mkdir(exist_ok=True)
    for seed in range(args.seed_base, args.seed_base + args.random):
        src = random_dir / f"random_{seed}.s"
        src.write_text(lockstep_random.generate(seed))
        jobs.append((f"random_{seed}", src))

    results: list[Result] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = [pool.submit(run_one, name, src, sim, work_root / name) for name, src in jobs]
        for fut in concurrent.futures.as_completed(futures):
            res = fut.result()
            results.append(res)
            if not res.ok:
                print(f"  FAIL {res.name}", flush=True)
                print("    " + res.detail.replace("\n", "\n    "), flush=True)
            elif args.verbose:
                print(f"  PASS {res.name} ({res.retired} instructions)", flush=True)

    failed = [r for r in results if not r.ok]
    total_retired = sum(r.retired for r in results)
    print(f"Lockstep: {len(results) - len(failed)} programs matched Spike, {len(failed)} mismatched "
          f"({total_retired} instructions compared)")
    if not args.keep:
        shutil.rmtree(work_root, ignore_errors=True)
    else:
        print(f"LOCKSTEP artifacts={work_root}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
