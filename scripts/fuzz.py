#!/usr/bin/env python3
"""Generate random programs and compare each one with Spike.

usage: fuzz.py <first_seed> <count> [items]
"""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_random import generate

B = "build"
PASS_LINE = re.compile(r"COSIM PASS \S+: (\d+) instructions identical")


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: fuzz.py <first_seed> <count> [items]")
    first, count = int(sys.argv[1]), int(sys.argv[2])
    items = int(sys.argv[3]) if len(sys.argv) > 3 else 300

    r = run(["make", "-s", "soc"])                    # build the SoC simulation once
    if r.returncode != 0:
        sys.exit("could not build the SoC:\n" + r.stdout + r.stderr)
    os.makedirs(f"{B}/fuzz", exist_ok=True)

    failures, total = [], 0
    for seed in range(first, first + count):
        name = f"fuzz_{seed}"
        with open(f"{B}/fuzz/{name}.S", "w") as f:
            f.write(generate(seed, items))
        r = run(["make", "-s", f"{B}/prog/{name}.mem"])
        if r.returncode != 0:
            failures.append((seed, "build failed:\n" + r.stdout + r.stderr))
            print("B", end="", flush=True)
            continue
        r = run(["python3", "scripts/cosim.py", name])
        m = PASS_LINE.search(r.stdout)
        if r.returncode == 0 and m:
            total += int(m.group(1))
            print(".", end="", flush=True)
        else:
            failures.append((seed, r.stdout + r.stderr))
            print("F", end="", flush=True)
    print()

    if not failures:
        print(f"FUZZ PASS: {count} programs, {total} instructions identical to Spike")
        return
    print(f"FUZZ FAIL: {len(failures)} of {count} programs failed "
          f"(seeds: {', '.join(str(s) for s, _ in failures[:20])})")
    for seed, text in failures[:3]:
        print(f"\n--- seed {seed} ---")
        print(text.rstrip())
        print(f"reproduce: python3 scripts/fuzz.py {seed} 1")
        print(f"source:    {B}/fuzz/fuzz_{seed}.S   (trace: make run PROG=fuzz_{seed})")
    sys.exit(1)


main()
