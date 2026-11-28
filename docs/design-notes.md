# Design notes

State of the project: an RV32IM core in two versions (a single-cycle baseline, and a 5-stage pipeline with branch
prediction, a return-address stack and an iterative multiply/divide unit), checked against Spike with directed programs
and a fuzzer, with cycle accounting and measurements on five benchmark kernels. Memory is zero-latency for now; caches
are next. Tags: v0.1 single-cycle, v0.2 pipeline, v0.3 predictor, v0.4 return stack (v0.5 M extension).

## 1. Architecture

**Basics**
- RV32IM, no compressed instructions, no CSRs. ecall, ebreak and CSR instructions decode as illegal; fence is a no-op.
- Memory: 64 KiB at 0x80000000 (Spike's base), combinational reads, byte-enable writes, zero latency. Out-of-range reads
  return 0 and out-of-range writes are ignored (no wraparound).
- Exit: a store to 0x20000000 ends a run; the stored value is the exit code (0 = pass). Spike has a built-in device at
  0x10000000, so that address could not be used.
- Traps: an illegal instruction, a misaligned jump target or a misaligned load/store stops the core with no side
  effects. Real exceptions need CSRs.
- Retirement trace: for each completed instruction, the PC, the instruction word, the register write and the memory
  access. This is the interface to Spike.

**Datapath decisions**
- The ALU does all address and target arithmetic (load/store addresses, branch and jal targets, lui, auipc are ADDs); the
  decoder selects the ALU inputs. Whether a branch is taken is decided by a separate comparator.
- Register file: two read ports, one write port, x0 has no storage. The same-cycle bypass (a read of the register being
  written returns the new value) is the parameter `BYPASS`: on in the pipeline, off in the single-cycle core, where it
  would create a combinational loop (`addi x1,x1,1`).
- Decoder outputs `uses_rs1/rs2` (so lui and jal create no fake hazards), `illegal` (no side effects) and `is_muldiv`.
- Load/store unit: word interface with four byte enables; store data is replicated across lanes; misaligned accesses are
  flagged and never written.

**Pipeline (`core_pipe.sv`, `CORE=pipe`)**: IF, ID, EX, MEM, WB, with packed-struct registers (`pipe_pkg.sv`); a bubble is
the all-zeros value. Traps travel with the instruction and are reported in WB.
- Data hazards: forwarding from MEM and WB into the ALU inputs, the branch comparator and the store data; a load whose
  result is needed by the next instruction stalls ID for one cycle (the data then arrives by forwarding from WB).
- Control hazards: IF looks up a BTB (direct-mapped, full tags), a direction predictor (2-bit counters, bimodal or
  gshare) and a return-address stack. Each instruction carries what was predicted; EX recomputes the next PC and redirects
  (2-cycle flush) when it differs, which covers a wrong direction, a wrong target and a prediction on a non-branch. The
  BTB is trained on every conditional branch, jal and jalr, taken or not, with call and return flags (a call writes x1 or
  x5; a return is a jalr that reads one and writes none). The global history is shifted at fetch with the predicted
  outcome (once per instruction, never while a stall or hold repeats the fetch) and restored in EX on every redirect;
  training uses the history that the prediction used.
- Return stack: two copies. IF pushes and pops a speculative copy; EX applies the calls and returns that really execute
  to a committed copy (EX only sees correct-path instructions); every redirect overwrites the speculative copy with the
  committed one, undoing all wrong-path pushes and pops exactly.
- Multiply/divide: an iterative unit (`muldiv.sv`) producing `MUL_BITS` or `DIV_BITS` result bits per cycle. An M
  instruction holds EX for `32/bits + 2` cycles (`32/bits + 1` stall cycles): PC, IF/ID and ID/EX freeze, a bubble goes
  into MEM, the operands are latched in the first EX cycle (when forwarding is correct), and the result joins the normal
  result path. Signed operations work on magnitudes. Division by zero gives all ones (rem: the dividend); INT_MIN / -1
  gives INT_MIN (rem: 0); neither traps.
- The single-cycle core executes M combinationally with the language's own operators, a second independent
  implementation; the two agree through Spike.

**Configuration (Makefile variables)**

| Variable | Values | Meaning |
|---|---|---|
| `CORE` | `pipe` (default), `single` | which core the SoC simulation uses |
| `PRED` | `gshare` (default), `bimodal`, `none` | gshare: 1024 counters + 10 history bits; bimodal: 256 counters; none: predict not taken (BTB and stack off) |
| `RAS`, `RAS_DEPTH` | `1`, `3` | return stack and jalr targets in the BTB; log2 of the stack entries |
| `BTB_BITS` | `6` | log2 of the BTB entries |
| `MUL_BITS`, `DIV_BITS` | `4`, `2` | result bits per cycle; must divide 32 |

## 2. Verification

- **Unit testbenches** for every module (`make test`, about 21 million checks): hand-derived directed cases plus random
  cases against an independent C++ model; the decoder is also swept over every opcode/funct3/funct7 combination.
- **Programs** (`make programs`): 12 self-checking programs, whose exit code names the first failing check.
- **Spike co-simulation** (`make cosim`): every retired instruction (PC, word, register and memory effects) of the 12
  programs, 230,706 instructions, is identical to Spike. Reference: Spike 1.1.1-dev (riscv-isa-sim 020edce6).
- **Fuzzing** (`make fuzz`): seeded random programs compared with Spike (forward-only control flow, a protected base
  register, dependency chains, store/load collisions, odd-offset jalr). Seeds 1-200 (300 items): 90,843 instructions;
  seeds 1000-1499 (600 items): 411,006. With M instructions (`FUZZ_M=m`; the old seeds still give the old programs):
  90,805 and 411,536 instructions, and 100 programs at each of the unit speeds 1/1 and 32/8.
- **External checks:** the decoder's opcode/funct tables against the Cornell CS 3410 reference; the hand-assembled
  `first_loop.mem` and the M encodings against the assembler. The other hand-written words in `decoder_tb.cpp` were not
  individually cross-checked (programs and Spike cover them indirectly).
- **Mutation checks.** A fault planted in the RTL must make the intended test fail:

| Fault planted | Caught by | Result |
|---|---|---|
| ALU arithmetic shift made logical | test_alu; cosim | code 21; cosim names the `srai` (instruction 70) |
| `blt` compared unsigned | test_branch | code 15 |
| `jalr` bit-0 clearing removed | test_jump | TRAP at the first odd target |
| `sb` byte enable always lane 0 | test_mem | code 43 |
| halfword select uses address bit 0 | test_mem | code 13 |
| `sltu` compared signed | fuzz | 20 of 20 seeds |
| load-use stall ignores rs2 | fuzz | 15 of 20 seeds (store data from a load) |
| predictor history restore without the shift | bpred unit test | 94,747 of 600,017 checks fail (bimodal unaffected) |
| BTB hit ignores the tag | btb unit test | 500,213 of 800,486 checks fail |
| return stack: entry copy missing on restore | ras unit test | 295,156 of 802,229 checks fail |
| return stack repair disabled in the core | bench_ras_stress | redirects 562 -> 1,081; no other test notices |
| mulhsu treats b as signed | muldiv unit test | 5,805 of 4,801,372 checks fail |
| mul decoded as illegal | decoder test | 80,165 of 4,239,056 checks fail |
| IF/ID not held during a multiply | test_muldiv; cosim | the instruction behind the mul vanishes (cosim mismatch at instruction 9) |
| held EX sends no bubble to MEM | fuzz with M | 20 of 20 seeds; first mismatch is the M instruction itself (result 0) |

## 3. Cycle accounting and workloads

`cycles = instructions + load-use stalls + 2 x redirects + mul/div stalls + 4` (4 = pipeline fill), checked on every run
(the harness prints the remainder as `other`, which must be 4). The core exposes `perf_stall`, `perf_flush` and
`perf_mdstall`; the harness counts them up to the exit store. The single-cycle core has IPC 1.000 everywhere.

- The hand-written tests are mostly taken branches (IPC 0.5-0.7) and are not representative.
- Benchmark kernels (all self-checking): `bench_sort` (insertion sort, 128 values), `bench_sieve` (primes below 1000),
  `bench_calls` (recursive fib(18) plus 400 indirect calls), `bench_collatz` (3n+1: a data-dependent branch),
  `bench_mix_m` (12x12 matrix multiply, 300 gcds, 300 signed divisions; built for rv32im, the others for rv32i).
- Verification programs, not benchmarks: `bench_ras_stress`, `test_muldiv` (generated by `scripts/gen_muldiv_test.py`).

## 4. Results

### 4.1 Branch handling (IPC, total cycles in brackets; `make perf-table`)

| Kernel | predict not taken | bimodal | gshare | bimodal + stack | gshare + stack |
|---|---|---|---|---|---|
| bench_sort | 0.676 (39,984) | 0.864 (31,296) | 0.860 (31,408) | 0.864 (31,296) | 0.860 (31,408) |
| bench_sieve | 0.686 (21,432) | 0.908 (16,194) | 0.898 (16,378) | 0.908 (16,194) | 0.898 (16,378) |
| bench_calls | 0.802 (135,529) | 0.796 (136,517) | 0.845 (128,705) | 0.912 (119,207) | 0.976 (111,395) |
| bench_collatz | 0.725 (24,436) | 0.893 (19,846) | 0.895 (19,792) | 0.893 (19,846) | 0.895 (19,792) |

Redirects (2 cycles each):

| Kernel | predict not taken | bimodal | gshare | bimodal + stack | gshare + stack |
|---|---|---|---|---|---|
| bench_sort | 4,486 | 142 | 198 | 142 | 198 |
| bench_sieve | 2,863 | 244 | 336 | 244 | 336 |
| bench_calls | 13,256 | 13,750 | 9,844 | 5,095 | 1,189 |
| bench_collatz | 3,359 | 1,064 | 1,037 | 1,064 | 1,037 |

Where the remaining lost cycles go (gshare + stack): `bench_sort` 91% load-use stalls (3,983), 9% redirects;
`bench_sieve` 60% stalls (998), 40% redirects; `bench_calls` 89% redirects (1,189); `bench_collatz` 99.8% redirects
(near-random branch). The load-use stall is already one cycle; only compiler scheduling can remove it.

### 4.2 Offline predictor study (`make bp`)
The retirement trace gives each conditional branch's outcome (next PC != PC+4), replayed through predictors. Cross-check:
taken branches + jal + jalr from the trace equal the hardware flush counts exactly.

| Direction accuracy | bench_sort | bench_sieve | bench_calls | bench_collatz |
|---|---|---|---|---|
| conditional branches | 8,485 | 4,028 | 9,562 | 4,574 |
| always not taken | 47.2% | 31.4% | 59.3% | 26.6% |
| backward taken | 98.5% | 91.1% | 51.0% | 71.1% |
| bimodal, 16 / 256 counters | 98.4% | 94.0% | 53.1% / 52.1% | 76.8% |
| gshare, 256 counters | 97.9% | 92.5% | 92.7% | 73.5% |
| gshare, 1024 counters | 97.7% | 92.0% | 93.0% | 77.4% |

- `bench_collatz` has a real data-dependent branch (1.46 conditional branches per step); no predictor passes 77.4%.
- On the recursive `bench_calls`, bimodal is worse than no prediction (0.796 vs 0.802) and gshare reaches 93%: the
  `n < 2` branch follows the recursion pattern, so history helps. (Not yet confirmed by varying the history length.)
- The kernels have few static branches, so table size has no effect; capacity questions need a larger workload.
- The model's projection for bimodal (0.864 / 0.898 / 0.794 / 0.893) is matched by the hardware (0.864 / 0.908 / 0.796 /
  0.893); the +0.010 on `bench_sieve` is the 96 `jal` that the model charged 2 cycles and the BTB predicts. Bimodal
  flush counts equal the model's mispredictions + jalr + 1 or 2; gshare differs by -1, +11, +8, +3 flushes (my
  explanation, unverified: the hardware history is speculative and only includes branches the BTB knows).
- A wrong predictor or history never breaks correctness, only the redirect count, so cosim and fuzz cannot see it.

### 4.3 Return stack
- `bench_calls` with gshare: 128,705 -> 111,395 cycles (IPC 0.845 -> 0.976). The stack removes exactly 8,655 redirects
  with either direction predictor (13,750 -> 5,095 and 9,844 -> 1,189). 509 `jalr` redirects remain (9,164 - 8,655):
  about 400 are the indirect calls through a pointer table (the BTB keeps only the last target), about 109 I have not
  attributed. About 680 conditional-branch mispredictions remain.
- Stack depth 2, 4, 8 and 16 entries all give 1,189 redirects (32 entries: 1,188). My explanation, unverified: fib
  returns to the same address at every depth, so an overflowed stack still holds the right value. This kernel cannot
  measure stack size.
- `bench_calls` gives identical results with the repair disabled, so no kernel exercises it. `bench_ras_stress` does: a
  coin-flip branch (bit 0 of xorshift32, which changes 505 times in 1,000 iterations) whose wrong path contains a call
  or a return.

| Configuration | Redirects | Cycles | IPC |
|---|---|---|---|
| stack off | 2,070 | 17,682 | 0.766 |
| stack on, repair on | 562 | 14,666 | 0.923 |
| stack on, repair off (mutation) | 1,081 | 15,704 | 0.862 |

### 4.4 M extension
- `test_muldiv`: every operation on 16 x 16 interesting values (2,048 checks; expected values from a Python model whose
  identities were checked), 7,431 instructions identical to Spike on both cores. Stalls = 256 x (4 x (32/m + 1) + 4 x
  (32/d + 1)) exactly: 67,584 / 26,624 / 7,168 at unit speeds 1/1, 4/2, 32/8.
- `bench_mix_m` (40,867 instructions, 627 redirects, 0 load-use stalls): gcc emitted 1,728 multiply-type and 4,042
  divide-type instructions (3,442 remu from the gcds, 300 div, 300 rem) and no library calls. Stalls =
  `muls x (32/m + 1) + divs x (32/d + 1)`, matched exactly at every speed:

| MUL_BITS / DIV_BITS | mul/div stalls | cycles | IPC |
|---|---|---|---|
| 1 / 1 | 190,410 | 232,535 | 0.176 |
| 2 / 2 | 98,090 | 140,215 | 0.291 |
| 4 / 2 (default) | 84,266 | 126,391 | 0.323 |
| 8 / 4 | 45,018 | 87,143 | 0.469 |
| 32 / 8 | 23,666 | 65,791 | 0.621 |

- Divides are 81.5% of the stalls at the default speed. Estimates from the formula (not measured): the divider from 2
  to 4 bits per cycle would save about 32,336 cycles, the multiplier from 4 to 8 about 6,912. 2/2 -> 4/2 changes only
  the multiplier and saved exactly 13,824 (1,728 x 8). There are no area or clock numbers, so only the cycle half of the
  speed/area trade-off is known.

## 5. Mistakes and lessons
- The `BYPASS` loop in the single-cycle core was found while designing it, not by a test.
- Forwarding a load took its address: the directed programs passed, the fuzzer failed 199 of 200 seeds.
- A syntax error in the shared linker script broke every program build at once.
- `crt0` ending in `j .` made the flush count off by 2 (the jump redirected one cycle before the exit store); it now ends
  in `ebreak`.
- Spike has a device at 0x10000000: giving it RAM there failed with an overlap error; the exit address moved.
- Wrong guess: that gcc had made the Collatz branch branch-free (the predictor study showed it did not).
- Wrong guess: that return-stack depth would matter on fib (it does not); and disabling the stack repair changed
  nothing on any kernel, which showed that none of them tested it, hence `bench_ras_stress`.
- Mutations that left a signal unread were rejected by the lint and tested nothing; they were redone with mutations
  that keep every signal in use.
- Equal retired-instruction totals at two unit speeds say nothing about whether the speed parameters reached the
  build; the stall counter does.

## 6. Open items
- Memory hierarchy: a latency model, then instruction and data caches (size, associativity, line size). Next.
- riscv-tests and CoreMark/Dhrystone; a larger workload for predictor and cache capacity questions.
- CSRs and real exceptions (misaligned accesses and ecall/ebreak currently stop the core); fence is a no-op.
- Unconfirmed explanations above (gshare vs model, return-stack depth, the 109 unattributed redirects, the gshare
  history length) and a `make perfcheck` that fails when a redirect count changes.
- Area and clock estimates (FPGA synthesis) to complete the multiplier/divider and predictor trade-offs.
- Cleanup: remove `sw/first_loop.mem` and the `run-first` Makefile target.
