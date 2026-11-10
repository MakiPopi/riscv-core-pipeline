#!/usr/bin/env python3
"""Convert a raw binary into $readmemh text: one 32-bit little-endian word per line."""
import sys


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: bin2mem.py <input.bin> <output.mem>")
    with open(sys.argv[1], "rb") as f:
        data = f.read()
    data += b"\x00" * (-len(data) % 4)   # pad to a whole number of words
    with open(sys.argv[2], "w") as out:
        for i in range(0, len(data), 4):
            out.write("%08x\n" % int.from_bytes(data[i:i + 4], "little"))


main()
