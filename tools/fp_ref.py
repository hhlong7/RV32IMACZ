#!/usr/bin/env python3
"""Exact-arithmetic reference for RISC-V single-precision fadd/fsub/fmul/fdiv.

Results are computed as exact rationals (fractions.Fraction) and then rounded
to binary32 with the RISC-V rules: canonical NaN results, NV on signaling
NaN inputs, tininess detected after rounding, fflags = {NV, DZ, OF, UF, NX}.
The RTL computes with shifted significands and sticky bits instead, so this
model shares no algorithm with it.

  python3 tools/fp_ref.py vectors out/fp_vectors.txt --count 50000
writes one test per line: "<op> <rm> <a> <b> <result> <flags>" in hex, with
op 0=add 1=sub 2=mul 3=div.
"""

from __future__ import annotations

import argparse
import pathlib
import random
from fractions import Fraction

RNE, RTZ, RDN, RUP, RMM = range(5)
NV, DZ, OF, UF, NX = 16, 8, 4, 2, 1
CANONICAL_NAN = 0x7FC00000
MIN_NORMAL_EXP = -126
FRAC_BITS = 23


def fields(x: int) -> tuple[int, int, int]:
    return x >> 31, (x >> 23) & 0xFF, x & 0x7FFFFF


def is_nan(x: int) -> bool:
    _, e, f = fields(x)
    return e == 0xFF and f != 0


def is_snan(x: int) -> bool:
    return is_nan(x) and not (x >> 22) & 1


def is_inf(x: int) -> bool:
    _, e, f = fields(x)
    return e == 0xFF and f == 0


def is_zero(x: int) -> bool:
    return x & 0x7FFFFFFF == 0


def value(x: int) -> Fraction:
    """Exact value of a finite binary32 number."""
    s, e, f = fields(x)
    mag = Fraction(f, 1 << FRAC_BITS) * Fraction(2) ** MIN_NORMAL_EXP if e == 0 else \
        Fraction((1 << FRAC_BITS) | f, 1 << FRAC_BITS) * Fraction(2) ** (e - 127)
    return -mag if s else mag


def round_int(q: Fraction, negative: bool, rm: int) -> int:
    """Round a non-negative magnitude to an integer in rounding mode rm."""
    floor = q.numerator // q.denominator
    rem = q - floor
    if rem == 0:
        return floor
    if rm == RNE:
        return floor + (rem > Fraction(1, 2) or (rem == Fraction(1, 2) and floor % 2 == 1))
    if rm == RTZ:
        return floor
    if rm == RDN:
        return floor + negative
    if rm == RUP:
        return floor + (not negative)
    if rm == RMM:
        return floor + (rem >= Fraction(1, 2))
    raise ValueError(rm)


def exponent_of(mag: Fraction) -> int:
    """floor(log2(mag)) for a positive rational, exactly."""
    e = mag.numerator.bit_length() - mag.denominator.bit_length()
    if Fraction(2) ** e > mag:
        e -= 1
    while Fraction(2) ** (e + 1) <= mag:
        e += 1
    return e


def round_to_single(exact: Fraction, rm: int) -> tuple[int, int]:
    """Round a nonzero exact value to binary32; returns (bits, flags)."""
    negative = exact < 0
    mag = -exact if negative else exact
    sign = int(negative) << 31
    flags = 0

    # Unbounded-exponent rounding decides tininess (after rounding).
    e = exponent_of(mag)
    scaled = mag / Fraction(2) ** (e - FRAC_BITS)
    m = round_int(scaled, negative, rm)
    if m == 1 << (FRAC_BITS + 1):
        m >>= 1
        e += 1
    tiny = e < MIN_NORMAL_EXP

    if e < MIN_NORMAL_EXP:
        # Subnormal range: fixed quantum 2^-149.
        quantum = Fraction(2) ** (MIN_NORMAL_EXP - FRAC_BITS)
        q = mag / quantum
        m = round_int(q, negative, rm)
        inexact = Fraction(m) != q
        bits = m  # m <= 2^23; m == 2^23 is the smallest normal, encoded naturally
    else:
        inexact = Fraction(m) * Fraction(2) ** (e - FRAC_BITS) != mag
        if e > 127:
            flags |= OF | NX
            to_max = rm == RTZ or (rm == RDN and not negative) or (rm == RUP and negative)
            return sign | (0x7F7FFFFF if to_max else 0x7F800000), flags
        bits = ((e + 127) << FRAC_BITS) | (m & 0x7FFFFF)

    if inexact:
        flags |= NX
        if tiny:
            flags |= UF
    return sign | bits, flags


def fp_add(a: int, b: int, rm: int, subtract: bool = False) -> tuple[int, int]:
    if subtract:
        b ^= 0x80000000
    if is_nan(a) or is_nan(b):
        return CANONICAL_NAN, NV if (is_snan(a) or is_snan(b)) else 0
    if is_inf(a) and is_inf(b):
        return (CANONICAL_NAN, NV) if (a >> 31) != (b >> 31) else (a, 0)
    if is_inf(a):
        return a, 0
    if is_inf(b):
        return b, 0
    exact = value(a) + value(b)
    if exact == 0:
        if (a >> 31) == (b >> 31) and is_zero(a) and is_zero(b):
            return a & 0x80000000, 0
        return (0x80000000 if rm == RDN else 0), 0
    return round_to_single(exact, rm)


def fp_mul(a: int, b: int, rm: int) -> tuple[int, int]:
    sign = ((a ^ b) >> 31) << 31
    if is_nan(a) or is_nan(b):
        return CANONICAL_NAN, NV if (is_snan(a) or is_snan(b)) else 0
    if (is_inf(a) and is_zero(b)) or (is_zero(a) and is_inf(b)):
        return CANONICAL_NAN, NV
    if is_inf(a) or is_inf(b):
        return sign | 0x7F800000, 0
    if is_zero(a) or is_zero(b):
        return sign, 0
    return round_to_single(value(a) * value(b), rm)


def fp_div(a: int, b: int, rm: int) -> tuple[int, int]:
    sign = ((a ^ b) >> 31) << 31
    if is_nan(a) or is_nan(b):
        return CANONICAL_NAN, NV if (is_snan(a) or is_snan(b)) else 0
    if (is_zero(a) and is_zero(b)) or (is_inf(a) and is_inf(b)):
        return CANONICAL_NAN, NV
    if is_inf(a):
        return sign | 0x7F800000, 0
    if is_zero(b):
        return sign | 0x7F800000, DZ
    if is_zero(a) or is_inf(b):
        return sign, 0
    return round_to_single(value(a) / value(b), rm)


def compute(op: int, a: int, b: int, rm: int) -> tuple[int, int]:
    if op == 0:
        return fp_add(a, b, rm)
    if op == 1:
        return fp_add(a, b, rm, subtract=True)
    if op == 2:
        return fp_mul(a, b, rm)
    return fp_div(a, b, rm)


# ---------------------------------------------------------------------------
# Operand generation aimed at the hard cases.

SPECIALS = [
    0x00000000, 0x80000000,             # zeros
    0x7F800000, 0xFF800000,             # infinities
    0x7FC00000, 0x7FA00000, 0xFFFFFFFF, # quiet NaN, signaling NaN, NaN
    0x00000001, 0x80000001, 0x007FFFFF, # smallest / largest subnormals
    0x00400000, 0x00800000, 0x80800000, # subnormal, smallest normals
    0x7F7FFFFF, 0xFF7FFFFF, 0x7F7FFFFE, # largest finite
    0x3F800000, 0xBF800000, 0x3F800001, # 1, -1, 1+ulp
    0x3F7FFFFF, 0x40000000, 0x3FC00000, # 1-ulp, 2, 1.5
    0x34000000, 0x33800000, 0x4B000000, # 2^-23, 2^-24, 2^23
]


def random_operand(rng: random.Random) -> int:
    r = rng.random()
    if r < 0.15:
        return rng.choice(SPECIALS)
    if r < 0.30:
        return rng.getrandbits(1) << 31 | rng.getrandbits(23)        # subnormal
    if r < 0.45:
        e = rng.choice([1, 2, 3, 24, 25, 126, 127, 128, 252, 253, 254])
        return rng.getrandbits(1) << 31 | e << 23 | rng.getrandbits(23)
    return rng.getrandbits(32)


def related_operand(rng: random.Random, a: int) -> int:
    """An operand close to a (cancellation, halfway, near-equal cases)."""
    r = rng.random()
    if r < 0.3:
        return a ^ 0x80000000 ^ rng.choice([0, 1, 2, 0x400000])   # near -a
    if r < 0.6:
        return (a + rng.randint(-3, 3)) & 0xFFFFFFFF                # near a
    shift = rng.randint(1, 30)
    return (a & 0x807FFFFF) | ((max(0, ((a >> 23) & 0xFF) - shift)) << 23)  # scaled down


def generate_vectors(count: int, seed: int) -> list[tuple[int, int, int, int, int, int]]:
    rng = random.Random(seed)
    vectors = []
    # Every special against every special, all ops, all rounding modes.
    for op in range(4):
        for rm in range(5):
            for a in SPECIALS:
                for b in SPECIALS:
                    vectors.append((op, rm, a, b, *compute(op, a, b, rm)))
    while len(vectors) < count:
        op = rng.randrange(4)
        rm = rng.randrange(5)
        a = random_operand(rng)
        b = related_operand(rng, a) if rng.random() < 0.4 else random_operand(rng)
        vectors.append((op, rm, a, b, *compute(op, a, b, rm)))
    return vectors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    gen = sub.add_parser("vectors", help="write test vectors")
    gen.add_argument("out", type=pathlib.Path)
    gen.add_argument("--count", type=int, default=50000)
    gen.add_argument("--seed", type=int, default=1)
    one = sub.add_parser("eval", help="evaluate one operation")
    one.add_argument("op", choices=["add", "sub", "mul", "div"])
    one.add_argument("a")
    one.add_argument("b")
    one.add_argument("--rm", type=int, default=RNE)
    args = parser.parse_args()

    if args.cmd == "eval":
        op = ["add", "sub", "mul", "div"].index(args.op)
        result, flags = compute(op, int(args.a, 16), int(args.b, 16), args.rm)
        print(f"{result:08x} flags={flags:05b}")
        return 0

    vectors = generate_vectors(args.count, args.seed)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("".join(f"{op} {rm} {a:08x} {b:08x} {r:08x} {f:02x}\n" for op, rm, a, b, r, f in vectors))
    print(f"FP_REF wrote {len(vectors)} vectors to {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
