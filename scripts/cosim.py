#!/usr/bin/env python3
"""Compare the core's retirement trace with Spike's commit log, line by line.

usage: cosim.py <program>     (needs build/prog/<program>.elf and .mem, and the SoC build)
"""
import re
import subprocess
import sys
import threading

B = "build"
SPIKE_LINE = re.compile(r"^core\s+0:\s+\d+\s+(0x[0-9a-f]{8})\s+\((0x[0-9a-f]{8})\)(.*)$")


def norm(text):
    return " ".join(text.split())          # collapse runs of spaces


def run_core(name):
    r = subprocess.run([f"{B}/soc_top/soc_top_tb", f"+hex={B}/prog/{name}.mem"],
                       capture_output=True, text=True, timeout=60)
    trace, status = [], ""
    for line in r.stdout.splitlines():
        if line.startswith("0x"):
            trace.append(norm(line))
        elif line.startswith(("EXIT", "TRAP", "TIMEOUT")):
            status = line
    return trace, status


def run_spike(name, count):
    # 0x80000000: program memory. 0x20000000: RAM for the exit store (Spike has a
    # built-in device at 0x10000000, so that address cannot be used).
    cmd = ["spike", "--isa=rv32i", "-m0x80000000:0x10000,0x20000000:0x1000",
           "--log-commits", f"{B}/prog/{name}.elf"]
    p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    watchdog = threading.Timer(20, p.kill)     # in case Spike hangs without output
    watchdog.start()
    lines, other, started = [], [], False
    for raw in p.stderr:
        m = SPIKE_LINE.match(raw.strip())
        if not m:
            if len(other) < 5:
                other.append(raw.strip())      # keep Spike's own messages for error reports
            continue
        if not started:                        # skip Spike's boot ROM
            if int(m.group(1), 16) != 0x80000000:
                continue
            started = True
        lines.append(norm(f"{m.group(1)} ({m.group(2)}){m.group(3)}"))
        if len(lines) == count:
            break
    p.kill()
    p.wait()
    watchdog.cancel()
    return lines, other


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: cosim.py <program>")
    name = sys.argv[1]

    core, status = run_core(name)
    if not core:
        sys.exit(f"COSIM FAIL {name}: the core produced no trace ({status})")
    ref, other = run_spike(name, len(core))

    for i, (c, s) in enumerate(zip(core, ref)):
        if c != s:
            print(f"COSIM FAIL {name}: first mismatch at instruction {i + 1}")
            for j in range(max(0, i - 3), i):
                print(f"    ok     {core[j]}")
            print(f"    core:  {c}")
            print(f"    spike: {s}")
            sys.exit(1)
    if len(ref) < len(core):
        msg = f"COSIM FAIL {name}: Spike produced only {len(ref)} of {len(core)} instructions"
        if other:
            msg += "\n    Spike said:\n      " + "\n      ".join(other)
        sys.exit(msg)
    if not status.startswith("EXIT"):
        sys.exit(f"COSIM FAIL {name}: the core ended abnormally: {status}")
    print(f"COSIM PASS {name}: {len(core)} instructions identical")


main()
