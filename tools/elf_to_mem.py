#!/usr/bin/env python3
"""Convert a flat binary image into the repo's word-wise .mem format."""

from __future__ import annotations

import argparse
from pathlib import Path


MEM_BYTES = 64 * 1024
WORD_BYTES = 4


def emit_mem(path: Path, image: bytes) -> None:
    lines = []
    for base in range(0, len(image), WORD_BYTES):
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
    parser.add_argument("input_bin", type=Path)
    parser.add_argument("output_mem", type=Path)
    args = parser.parse_args()

    data = args.input_bin.read_bytes()
    if len(data) > MEM_BYTES:
        raise SystemExit(
            f"binary too large for 64KB memory image: {len(data)} bytes > {MEM_BYTES}"
        )

    image = bytearray(MEM_BYTES)
    image[: len(data)] = data
    emit_mem(args.output_mem, image)


if __name__ == "__main__":
    main()
