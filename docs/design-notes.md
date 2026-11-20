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
