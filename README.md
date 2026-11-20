# riscv-core-pipeline

A RISC-V (RV32I) in-order core in SystemVerilog, built as a platform for microarchitecture
exploration: a single-cycle baseline, a 5-stage pipeline, and a verification setup (unit tests,
Spike co-simulation, a random-program fuzzer) that every change must pass. Branch prediction is
being added next, with the design chosen from measurements.

## Status
- [x] Datapath modules (ALU, register file, decoder, branch comparator, load/store unit), each with a
      self-checking Verilator testbench
- [x] Single-cycle core, memory model, SoC wrapper, simulation harness, retirement trace
- [x] Assembly toolchain flow and self-checking tests for every instruction the decoder supports
- [x] Co-simulation against Spike (`make cosim`) and seeded random programs (`make fuzz`)
- [x] 5-stage pipeline: forwarding, load-use stall, branch flush
- [x] Cycle accounting (`make perf`) and four compiled C benchmark kernels
- [x] Offline branch predictor study on the kernels (`make bp`)
- [x] Direction predictor (bimodal/gshare) and branch target buffer, unit-tested (`make bpred`, `make btb`)
- [ ] Predictor and BTB integrated into the pipeline, measured against the study
- [ ] Return-address stack
- [ ] riscv-tests, CoreMark/Dhrystone
- [ ] Parameterizable L1 caches
- [ ] M extension, CSRs, exceptions
- [ ] Stretch: superscalar / out-of-order, FPGA synthesis

## Results so far
Pipeline with predict-not-taken and resolution in EX (a taken branch or jump costs 2 cycles); the
single-cycle core has IPC 1.000 on every program.

| Kernel | Instructions | Cycles | IPC | Load-use stalls | Taken branch/jump flushes |
|---|---|---|---|---|---|
| bench_sort | 27,025 | 39,984 | 0.676 | 3,983 | 4,486 |
| bench_sieve | 14,704 | 21,432 | 0.686 | 998 | 2,863 |
| bench_calls | 108,713 | 135,529 | 0.802 | 300 | 13,256 |
| bench_collatz | 17,714 | 24,436 | 0.725 | 0 | 3,359 |

Every lost cycle is accounted for (`cycles = instructions + stalls + 2 x flushes + 4`).
The offline predictor study replays each kernel's branch outcomes through several predictors:

| Direction accuracy | sort | sieve | calls | collatz |
|---|---|---|---|---|
| always not taken | 47.2% | 31.4% | 59.3% | 26.6% |
| bimodal, 256 counters | 98.4% | 94.0% | 52.1% | 76.8% |
| gshare, 1024 counters | 97.7% | 92.0% | 93.0% | 77.4% |

On the recursive `bench_calls`, a bimodal predictor is worse than always-not-taken, while gshare
reaches 93%, so the branch outcome depends on history. Projected IPC with an ideal predictor is
0.86-0.90 on the loop-heavy kernels; `bench_calls` is limited by its 9,164 calls and returns, which
need a return-address stack. These are projections, not measurements of the hardware yet. Details
and caveats are in `docs/design-notes.md`.

## Verification
- **Unit testbenches** for every module: hand-derived directed cases plus random cases against an
  independent C++ model (`make test`).
- **Self-checking programs** (assembly and C) whose exit code names the first failing check
  (`make programs`).
- **Spike co-simulation:** every retired instruction (PC, word, register and memory effects) of
  nine programs, about 169,000 instructions, is identical to Spike (`make cosim`).
- **Fuzzing:** seeded random programs compared with Spike; 411,006 instructions identical in one run
  of 500 programs (`make fuzz`).
- **Mutation checks:** faults planted in the RTL (wrong shift, signed vs unsigned compare, dropped
  `jalr` bit-0 clearing, wrong byte lane, a hazard check missing a source register, a predictor
  history that is not restored, a BTB hit that ignores the tag) were each caught by the intended test; see the table in the design notes.

## Layout
    rtl/       SystemVerilog sources
    tb/        Verilator C++ testbenches (one per module, plus the SoC harness)
    sw/        test programs and benchmark kernels, startup code, linker script, test macros
    scripts/   bin2mem.py, cosim.py, gen_random.py, fuzz.py, bp_sim.py
    docs/      design notes

## Requirements
Verilator 5.x, a C++ compiler, Python 3, the RISC-V binutils and gcc (on Ubuntu:
`binutils-riscv64-unknown-elf`, `gcc-riscv64-unknown-elf`), and Spike built from
riscv-software-src/riscv-isa-sim (run `git submodule update --init --recursive` in the clone first).

## Usage
    make test            # unit testbenches for every module, including the predictor and BTB
    make lint            # lint the single-cycle core (make lint-pipe for the pipeline)
    make programs        # run every self-checking program
    make cosim           # compare every program with Spike, instruction by instruction
    make fuzz            # random programs, each compared with Spike
    make perf            # cycles, IPC and where the lost cycles went
    make bp              # offline branch predictor study on the benchmark kernels
    make run PROG=test_alu                     # run one program with a full trace
    make run PROG=first_loop ARGS=+expect=15   # check the exit code

Add `CORE=single` or `CORE=pipe` (the default) to pick the core. A program ends by storing its
exit code to 0x20000000 (Spike has a built-in device at 0x10000000); 0 means every check passed.
