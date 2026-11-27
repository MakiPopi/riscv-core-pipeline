# Design notes

## Design decisions
- **ISA / tools:** RV32I (M, CSRs later); SystemVerilog, Verilator, C++ testbenches.
- **ALU does all address and target math** (load/store address, branch/JAL target, lui, auipc are ADDs); the
  decoder selects the ALU inputs. Branch *taken* is decided by a separate comparator.
- **Register file:** 2 read ports, 1 write port, x0 has no storage. Same-cycle bypass is a parameter
  (`BYPASS`): on in the pipeline, off in the single-cycle core, where it would create a combinational loop
  (`addi x1,x1,1`). Found while designing the core, not by a test.
- **Decoder** outputs `uses_rs1/rs2` (no fake hazards for lui/jal) and `illegal` (no side effects).
- **Load/store unit:** word memory interface with byte enables; misaligned accesses are flagged, never written.
- **Memory:** zero-latency, 64 KiB at 0x80000000 (Spike's base); out-of-range reads give 0, writes are ignored.
- **Traps:** no exceptions until CSRs exist; an illegal instruction or misaligned jump/access stops the core
  with no side effects. **Exit:** a store to 0x20000000 ends the run (value = exit code).
- **Retirement trace** (PC, instruction, register write, memory access) is the interface to Spike.

## Pipeline (`core_pipe.sv`, selected with `CORE=pipe`; `CORE=single` is the baseline)
- IF, ID, EX, MEM, WB; registers are packed structs (`pipe_pkg.sv`); a bubble is the all-zeros value.
- Branches/jumps resolve in EX, predict-not-taken; a taken one flushes IF/ID and ID/EX (2 cycles).
- Forwarding from MEM and WB into the ALU inputs, branch comparator and store data; a load-use hazard stalls
  ID for one cycle (the load data then arrives by forwarding from WB). Traps travel to WB.
- How each piece was found: without forwarding, first_loop failed at instruction 3; with forwarding, the fuzzer
  failed 199 of 200 seeds because forwarding a load took its ADDRESS (e.g. `sll` gave 0x80000b12 << 18); the
  stall fixed that.

## Verification
- **Unit:** every module has a self-checking testbench (hand-derived directed cases + random cases against an
  independent C++ model; decoder swept over all opcode/funct3/funct7). `make test`.
- **Programs:** assembly tests check their own results (`make programs`): ALU, branches, jumps, loads/stores,
  plus four compiled C kernels. Return value = number of the first failing check.
- **Spike co-simulation** (`make cosim`): every retired instruction compared (PC, word, register, memory).
  Reference: Spike 1.1.1-dev, riscv-isa-sim 020edce6. Spike has a device at 0x10000000, hence exit at 0x20000000.
- **Fuzzing** (`make fuzz`): seeded random programs (forward-only control flow, protected base register,
  dependency chains, store/load collisions, odd-offset jalr). Single-cycle and pipeline: seeds 1-200 give 90,843
  and seeds 1000-1499 (600 items) give 411,006 instructions identical to Spike.
- **Checked externally:** decoder opcode/funct tables vs the Cornell CS 3410 reference; hand-assembled
  `first_loop.mem` identical to the assembler's output. Not independently checked: the other hand-written
  words in `decoder_tb.cpp`.

| Fault planted in the RTL | Caught by | Result |
|---|---|---|
| ALU arithmetic shift made logical | test_alu; cosim | code 21; cosim names the `srai` (instruction 70) |
| `blt` compared unsigned | test_branch | code 15 |
| `jalr` bit-0 clearing removed | test_jump | TRAP at the first odd target |
| `sb` byte enable always lane 0 | test_mem | code 43 |
| halfword select uses addr bit 0 | test_mem | code 13 |
| `sltu` compared signed | fuzz | 20 of 20 seeds |
| load-use stall ignores rs2 | fuzz | 15 of 20 seeds (store data from a load) |
| predictor history restore without the shift | bpred unit test (random pipelined part) | 94,747 of 600,017 checks fail; the bimodal configuration is unaffected |
| BTB hit ignores the tag | btb unit test | first failure `same index, other tag`; 500,213 of 800,486 checks fail |

## Performance (`make perf`)
The core exposes `perf_stall` and `perf_flush`; the harness checks
`cycles = instructions + stalls + 2*flushes + 4` (4 = pipeline fill) on every run. Single-cycle IPC is 1.000.
All kernels pass and match Spike. Baseline (predict-not-taken, resolve in EX):

| Program | Instr. | Cycles | IPC | Stalls | Flushes | IPC if flushes were free |
|---|---|---|---|---|---|---|
| bench_sort | 27025 | 39984 | 0.676 | 3983 | 4486 | 0.871 |
| bench_sieve | 14704 | 21432 | 0.686 | 998 | 2863 | 0.936 |
| bench_calls | 108713 | 135529 | 0.802 | 300 | 13256 | 0.997 |
| bench_collatz | 17714 | 24436 | 0.725 | 0 | 3359 | 1.000 |

The hand-written test programs are mostly taken branches (IPC 0.5-0.7) and are not representative.

## Branch predictor study (`make bp`, offline, direction only)
Outcomes come from the retirement trace. Cross-check: taken branches + jal + jalr from the trace equal the
hardware flush counts exactly.

| Predictor | bench_sort | bench_sieve | bench_calls | bench_collatz |
|---|---|---|---|---|
| conditional branches | 8485 | 4028 | 9562 | 4574 |
| always not taken | 47.2% | 31.4% | 59.3% | 26.6% |
| always taken | 52.8% | 68.6% | 40.7% | 73.4% |
| backward taken | 98.5% | 91.1% | 51.0% | 71.1% |
| bimodal 16 / 256 | 98.4% | 94.0% | 53.1% / 52.1% | 76.8% |
| gshare 256 | 97.9% | 92.5% | 92.7% | 73.5% |
| gshare 1024 | 97.7% | 92.0% | 93.0% | 77.4% |

- bench_collatz has a real data-dependent branch (1.46 branches per step); no predictor passes 77.4%.
- bench_calls: bimodal is worse than always-not-taken; gshare gets 93%, since the `n < 2` branch follows the
  recursion pattern (history length not yet varied to confirm).
- The kernels have few static branches, so table size has no effect; capacity needs a larger workload.

Projected IPC (ideal target always available, 0 cycles if right, 2 if wrong). Targets for the hardware, not results:

| Program | baseline | backward taken | bimodal 256 | gshare 1024 | best + jumps free |
|---|---|---|---|---|---|
| bench_sort | 0.676 | 0.864 | 0.864 | 0.860 | 0.864 |
| bench_sieve | 0.686 | 0.885 | 0.898 | 0.889 | 0.908 |
| bench_calls | 0.802 | 0.793 | 0.794 | 0.842 | 0.985 |
| bench_collatz | 0.725 | 0.870 | 0.893 | 0.895 | 0.895 |

bench_calls' remaining loss is 9,164 `jalr` (calls and returns), which needs a return-address stack.

## Mistakes found along the way
`BYPASS` loop (above); a linker-script syntax error that broke every build; `crt0` ending in `j .` made the
flush accounting off by 2 (now `ebreak`); my Spike exit address overlapped a built-in device; a wrong guess that
gcc had made the Collatz branch branch-free (the predictor study showed otherwise).

## Open items
- Misaligned jumps/accesses should become real exceptions; ecall, ebreak, CSRs and the M extension decode as illegal.
- fence is a no-op (no caches yet). riscv-tests and CoreMark are not run yet.
- Cleanup: remove `sw/first_loop.mem` and the `run-first` Makefile target.

## Branch prediction in the pipeline (measured)
IF looks up a direct-mapped BTB (64 entries, full tags) and a direction predictor (`PRED=bimodal`: 256 counters;
`PRED=gshare`: 1024 counters, 10 history bits; `PRED=none`: the old predict-not-taken). Each instruction carries what
was predicted; EX recomputes the next PC and redirects (2 cycles) when it differs, which covers a wrong direction, a
wrong target and a prediction on a non-branch. jalr is never predicted. The BTB is trained on every conditional
branch and jal, taken or not (so the history knows about every branch after its first sighting). The global history
is shifted at fetch with the predicted outcome (only for branches that hit the BTB) and restored in EX on any
redirect; training uses the history the branch was predicted with. A history shift happens once per instruction, not
while a load-use stall holds the fetch.

Regression: PRED=none reproduces the old pipeline exactly. With prediction on, all programs, cosim (same counts)
and both fuzz runs (90,843 and 411,006 instructions) are unchanged. other = 4 everywhere.

| Kernel | none: IPC (cycles) | bimodal: IPC (cycles, flushes) | gshare: IPC (cycles, flushes) |
|---|---|---|---|
| bench_sort | 0.676 (39,984) | 0.864 (31,296, 142) | 0.860 (31,408, 198) |
| bench_sieve | 0.686 (21,432) | 0.908 (16,194, 244) | 0.898 (16,378, 336) |
| bench_calls | 0.802 (135,529) | 0.796 (136,517, 13,750) | 0.845 (128,705, 9,844) |
| bench_collatz | 0.725 (24,436) | 0.893 (19,846, 1,064) | 0.895 (19,792, 1,037) |

- Bimodal flushes = study's mispredictions + jalr + 1 or 2 (probably first sightings of jal): sort 139+2+1,
  sieve 240+2+2, calls 4,584+9,164+2, collatz 1,061+2+1. gshare differs from the study by -1, +11, +8, +3 flushes
  (my explanation, unverified: the hardware history is speculative and only includes branches the BTB knows).
- bench_calls with bimodal is slower than predicting nothing (as the study said); gshare is 5.0% faster in cycles.
- Remaining loss: load-use stalls on sort (93%) and sieve (67%); jalr on calls (9,164 of 9,844 redirects, IPC would be
  about 0.985 without them); collatz is limited by a near-random branch.
- A wrong history or predictor never breaks correctness, only the flush count, so cosim and fuzz cannot detect it;
  quality is checked by comparing flush counts with the model.

## Return-address stack (`RAS=1`, `RAS_DEPTH`)
The BTB now also holds jalr, with call and return flags (a call writes x1 or x5; a return is a jalr that reads one
and writes none). IF pushes PC+4 on a predicted call and takes a return's target from the stack. There are two
copies: a speculative one that IF updates, and a committed one that EX updates with the calls and returns that
really execute (EX only ever sees correct-path instructions); every redirect overwrites the speculative copy with
the committed one, undoing all wrong-path pushes and pops exactly. The BTB entry learns a call or return the
first time it executes, and the commit copy repairs the stack after that first miss.

Regression: `RAS=0` reproduces the previous numbers exactly; with the stack on, all programs, cosim and both
fuzz runs (90,843 and 411,006 instructions) are unchanged. Unit-test mutation (entry copy removed on restore):
295,156 of 802,229 checks fail.

bench_calls with gshare: 128,705 -> 111,395 cycles, IPC 0.845 -> 0.976, redirects 9,844 -> 1,189 (the study's ceiling
with every jump free was 0.985). bench_sort is unchanged at every depth. Stack depth 1-4 (2-16 entries) all give
1,189 redirects and depth 5 (32 entries) 1,188. My explanation (unverified): fib returns to the same address at
every depth, so an overflowed stack still holds the right value and only the outermost return is lost; fib(18)
recurses about 18 deep, which fits the single redirect appearing between 16 and 32 entries. This kernel cannot
measure stack size; calls that return to different addresses are needed. Rough breakdown of the remaining 1,189
(estimate): about 680 conditional-branch mispredictions, about 400 indirect calls through a pointer table (the BTB
keeps only the last target), about 109 unattributed.

All configurations (generated by scripts/perf_table.py):

IPC (total cycles in brackets):

| Kernel | predict not taken | bimodal | gshare | bimodal + RAS | gshare + RAS |
|---|---|---|---|---|---|
| bench_sort | 0.676 (39,984) | 0.864 (31,296) | 0.860 (31,408) | 0.864 (31,296) | 0.860 (31,408) |
| bench_sieve | 0.686 (21,432) | 0.908 (16,194) | 0.898 (16,378) | 0.908 (16,194) | 0.898 (16,378) |
| bench_calls | 0.802 (135,529) | 0.796 (136,517) | 0.845 (128,705) | 0.912 (119,207) | 0.976 (111,395) |
| bench_collatz | 0.725 (24,436) | 0.893 (19,846) | 0.895 (19,792) | 0.893 (19,846) | 0.895 (19,792) |

Redirects (each costs 2 cycles):

| Kernel | predict not taken | bimodal | gshare | bimodal + RAS | gshare + RAS |
|---|---|---|---|---|---|
| bench_sort | 4,486 | 142 | 198 | 142 | 198 |
| bench_sieve | 2,863 | 244 | 336 | 244 | 336 |
| bench_calls | 13,256 | 13,750 | 9,844 | 5,095 | 1,189 |
| bench_collatz | 3,359 | 1,064 | 1,037 | 1,064 | 1,037 |

## Return-stack stress test (`bench_ras_stress`)
A coin-flip branch (xorshift32 bit 0, which changes 505 times in 1,000 iterations) whose wrong path contains a call
(`jal t0, f`) or a return (`ret`), so a mispredicted branch pushes or pops the speculative stack wrongly. Self-check:
f runs 510 times (computed in Python). Cosim: 13,538 instructions identical.

| Configuration | Redirects | Cycles | IPC |
|---|---|---|---|
| stack off | 2,070 | 17,682 | 0.766 |
| stack on, repair on | 562 | 14,666 | 0.923 |
| stack on, repair off (mutation: `.restore(1'b0)`) | 1,081 | 15,704 | 0.862 |

- The stack removes 1,508 redirects: the 1,510 returns minus 2 (probably the first sighting of each return).
- Disabling the repair costs 519 redirects, about one per mispredicted branch.
- `bench_calls` gives identical results with the repair disabled (1,189 redirects either way): none of the four kernels
  exercises the repair, which is why this program exists. Correctness tests cannot see a wrong stack, because a wrong
  prediction only costs cycles; only the redirect counts can.

## M extension (multiply/divide)
The decoder takes funct7 = 0000001 on the OP opcode (`is_muldiv`). Pipeline: an iterative unit (`muldiv.sv`) that produces
MUL_BITS (default 4) or DIV_BITS (default 2) result bits per cycle. An M instruction holds EX for `32/bits + 2` cycles, so
`32/bits + 1` stall cycles (9 for mul and 17 for div at the defaults). PC, IF/ID and ID/EX hold, a bubble enters MEM, the
operands are latched in the first EX cycle (when forwarding is correct), the result joins the normal result path (so
forwarding is unchanged), and `fetch_accept` honours the hold (the predictor history and the return stack must not
shift twice). The single-cycle core executes M combinationally with the language's own operators, a second independent
implementation: the two agree through Spike. Assembly is built with -march=rv32im and Spike runs --isa=rv32im; the C
benchmarks stay rv32i so their numbers remain comparable. Cycle accounting is now
`cycles = instructions + load-use stalls + 2*flushes + mul/div stalls + 4`.

Verification: unit test of the unit at three speeds (4,801,372 / 2,398,964 / 1,259,520 checks; the mulhsu-as-signed
mutation fails 5,805 checks); decoder sweep (4,239,056 checks; mutation: mul decoded as illegal fails 80,165);
`test_muldiv` (2,048 checks, every operation on 16 x 16 interesting values, expected values from a Python model whose
identities were checked; cosim 7,431 instructions identical on both cores); mutation: IF/ID not held during a multiply
makes the instruction behind the first mul vanish (cosim mismatch at instruction 9).

test_muldiv at three unit speeds (mul/div stalls = 256 * (4*(32/m + 1) + 4*(32/d + 1)) exactly):

| MUL_BITS / DIV_BITS | mul/div stalls | cycles | IPC |
|---|---|---|---|
| 1 / 1 | 67,584 | 77,363 | 0.096 |
| 4 / 2 | 26,624 | 36,403 | 0.204 |
| 32 / 8 | 7,168 | 16,947 | 0.438 |

Its 2,304 load-use stalls are 256 * 9 (the lw feeding the first multiply, and the lw feeding each of the 8 compares).
This program is only M operations, so its IPC is not typical; a realistic workload is the next step.
