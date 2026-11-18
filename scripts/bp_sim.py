#!/usr/bin/env python3
"""Trace-driven branch predictor study (no hardware involved).

usage: bp_sim.py <program> [<program> ...]     (needs build/prog/<name>.mem and the SoC build)

Runs each program on the core, reads the retirement trace, works out for every conditional branch
whether it was taken (the next retired PC is not PC+4), and replays that stream through several
predictors. Only the direction of conditional branches is predicted; targets and returns come later.
"""
import re
import subprocess
import sys

B = "build"
LINE = re.compile(r"^0x([0-9a-f]{8}) \(0x([0-9a-f]{8})\)")


def trace(name):
    r = subprocess.run([f"{B}/soc_top/soc_top_tb", f"+hex={B}/prog/{name}.mem"],
                       capture_output=True, text=True, timeout=300)
    return [(int(m.group(1), 16), int(m.group(2), 16))
            for m in map(LINE.match, r.stdout.splitlines()) if m]


class Static:
    def __init__(self, rule):
        self.rule = rule

    def predict(self, pc, backward):
        return self.rule(backward)

    def update(self, pc, taken):
        pass


class Bimodal:
    """2-bit saturating counters indexed by PC bits. Start at 1 (weakly not taken)."""

    def __init__(self, bits):
        self.mask = (1 << bits) - 1
        self.t = [1] * (1 << bits)

    def predict(self, pc, backward):
        return self.t[(pc >> 2) & self.mask] >= 2

    def update(self, pc, taken):
        i = (pc >> 2) & self.mask
        self.t[i] = min(3, self.t[i] + 1) if taken else max(0, self.t[i] - 1)


class Gshare:
    """Like Bimodal, but the index is the PC bits XOR the last 'bits' branch outcomes."""

    def __init__(self, bits):
        self.mask = (1 << bits) - 1
        self.t = [1] * (1 << bits)
        self.hist = 0

    def _index(self, pc):
        return ((pc >> 2) ^ self.hist) & self.mask

    def predict(self, pc, backward):
        return self.t[self._index(pc)] >= 2

    def update(self, pc, taken):
        i = self._index(pc)                      # index first, then shift the outcome into the history
        self.t[i] = min(3, self.t[i] + 1) if taken else max(0, self.t[i] - 1)
        self.hist = ((self.hist << 1) | int(taken)) & self.mask


def predictors():
    return [
        ("always not taken", Static(lambda backward: False)),
        ("always taken", Static(lambda backward: True)),
        ("backward taken", Static(lambda backward: backward)),
        ("bimodal 16", Bimodal(4)),
        ("bimodal 256", Bimodal(8)),
        ("gshare 256", Gshare(8)),
        ("gshare 1024", Gshare(10)),
    ]


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: bp_sim.py <program> [<program> ...]")
    names = sys.argv[1:]
    stats, acc = {}, {}

    for name in names:
        tr = trace(name)
        if not tr:
            sys.exit(f"no trace for {name} (run: make soc build/prog/{name}.mem)")
        branches, jal, jalr = [], 0, 0
        for (pc, inst), nxt in zip(tr, tr[1:]):
            op = inst & 0x7F
            if op == 0x63:                                   # conditional branch
                branches.append((pc, bool(inst >> 31), nxt[0] != pc + 4))   # (pc, backward, taken)
            elif op == 0x6F:
                jal += 1
            elif op == 0x67:
                jalr += 1
        taken = sum(1 for b in branches if b[2])
        stats[name] = (len(tr), len(branches), taken, jal, jalr)
        for label, p in predictors():
            ok = 0
            for pc, backward, t in branches:
                ok += p.predict(pc, backward) == t
                p.update(pc, t)
            miss = len(branches) - ok
            pct = 100.0 * ok / max(1, len(branches))
            acc.setdefault(label, {})[name] = f"{pct:.1f}% ({miss})"

    print(f"{'program':14s} {'instr':>8s} {'cond.br':>8s} {'taken':>7s} {'jal':>6s} {'jalr':>6s}   taken br + jumps")
    for n in names:
        i, b, t, j, jr = stats[n]
        print(f"{n:14s} {i:8d} {b:8d} {100.0 * t / max(1, b):6.1f}% {j:6d} {jr:6d}   {t + j + jr}")

    print("\nprediction accuracy of conditional branches (mispredictions in brackets)")
    print(f"{'predictor':18s}" + "".join(f"{n:>22s}" for n in names))
    for label in acc:
        print(f"{label:18s}" + "".join(f"{acc[label][n]:>22s}" for n in names))


main()
