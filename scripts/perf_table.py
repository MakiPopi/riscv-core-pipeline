#!/usr/bin/env python3
"""Run `make perf` for several branch-handling configurations and print markdown tables.

usage: perf_table.py     (slow: every configuration rebuilds the SoC simulation)
"""
import re
import subprocess
import sys

CONFIGS = [
    ("predict not taken", ["PRED=none", "RAS=0"]),
    ("bimodal", ["PRED=bimodal", "RAS=0"]),
    ("gshare", ["PRED=gshare", "RAS=0"]),
    ("bimodal + RAS", ["PRED=bimodal", "RAS=1"]),
    ("gshare + RAS", ["PRED=gshare", "RAS=1"]),
]
ROW = re.compile(r"^(bench_\w+)\s+cycles=(\d+) instructions=(\d+) IPC=([\d.]+) \| load-use stalls=(\d+), "
                 r"taken-branch/jump flushes=(\d+) \(2 cycles each\), mul/div stalls=(\d+), other=(\d+)")


def measure(args):
    r = subprocess.run(["make", "-s", "perf"] + args, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("make perf failed for " + " ".join(args) + ":\n" + r.stdout + r.stderr)
    rows = {}
    for line in r.stdout.splitlines():
        m = ROW.match(line)
        if m:
            name, cycles, instr, _, stalls, flushes, _md, other = m.groups()
            if int(other) != 4:
                print(f"WARNING: other={other} (expected 4) for {name} with {' '.join(args)}", file=sys.stderr)
            rows[name] = (int(cycles), int(instr), int(stalls), int(flushes))
    return rows


def main():
    results = [(label, measure(args)) for label, args in CONFIGS]
    kernels = list(results[0][1])
    head = "| Kernel | " + " | ".join(label for label, _ in results) + " |\n|---|" + "---|" * len(results)

    print("IPC (total cycles in brackets):\n")
    print(head)
    for k in kernels:
        cells = [f"{rows[k][1] / rows[k][0]:.3f} ({rows[k][0]:,})" for _, rows in results]
        print(f"| {k} | " + " | ".join(cells) + " |")

    print("\nRedirects (each costs 2 cycles):\n")
    print(head)
    for k in kernels:
        print(f"| {k} | " + " | ".join(f"{rows[k][3]:,}" for _, rows in results) + " |")


main()
