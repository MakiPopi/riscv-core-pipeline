# riscv-core-pipeline

An RV32IM in-order core in SystemVerilog, built as a platform for microarchitecture exploration. It comes in two
versions, a single-cycle baseline and a 5-stage pipeline with a branch target buffer, bimodal/gshare prediction, a
return-address stack and an iterative multiply/divide unit, and with a verification setup that every change has to
pass: unit testbenches, self-checking programs, Spike co-simulation and a random-program fuzzer. Performance is
measured with cycle accounting that attributes every lost cycle to a cause.

## Status
- [x] Datapath modules (ALU, register file, decoder, branch comparator, load/store unit), each with a testbench
- [x] Single-cycle core, memory model, SoC wrapper, simulation harness, retirement trace
- [x] Assembly and C toolchain flow, 12 self-checking programs
- [x] Co-simulation against Spike (`make cosim`) and seeded random programs (`make fuzz`)
- [x] 5-stage pipeline: forwarding, load-use stall, flush on misprediction
- [x] Cycle accounting (`make perf`) and five benchmark kernels
- [x] Branch prediction: BTB, bimodal/gshare, return-address stack, checked against an offline model (`make bp`)
- [x] M extension: iterative multiply/divide unit with configurable speed; fuzzed and benchmarked
- [ ] Memory latency model and parameterizable L1 caches (next)
- [ ] riscv-tests, CoreMark/Dhrystone
- [ ] CSRs and exceptions
- [ ] Stretch: superscalar / out-of-order, FPGA synthesis

## Results
IPC of the pipeline (the single-cycle core has IPC 1.000 everywhere):

| Kernel | Predict not taken | gshare + BTB | + return stack |
|---|---|---|---|
| bench_sort | 0.676 | 0.860 | 0.860 |
| bench_sieve | 0.686 | 0.898 | 0.898 |
| bench_calls | 0.802 | 0.845 | 0.976 |
| bench_collatz | 0.725 | 0.895 | 0.895 |

Multiply/divide unit speed on `bench_mix_m` (matrix multiply, gcds, signed division; 40,867 instructions):

| Result bits per cycle (mul / div) | 1 / 1 | 2 / 2 | 4 / 2 | 8 / 4 | 32 / 8 |
|---|---|---|---|---|---|
| IPC | 0.176 | 0.291 | 0.323 | 0.469 | 0.621 |

- Every lost cycle is accounted for (`cycles = instructions + load-use stalls + 2 x redirects + mul/div stalls + 4`);
  the harness checks the identity on every run.
- An offline model fed with the programs' branch traces predicted the hardware's redirect counts (the trace-derived
  count equals the hardware's exactly; for bimodal the model's mispredictions plus calls and returns, to within 1 or 2).
  It also predicted that bimodal is slower than no prediction on recursive code (0.796 vs 0.802) while gshare is 5%
  faster; the return stack then removes 8,655 of the remaining redirects on `bench_calls`.
- On the loop kernels the remaining loss is load-use stalls (91% on `bench_sort`), which a predictor cannot remove.
- Divides are 81.5% of the multiply/divide stall cycles on `bench_mix_m` at the default speed.

Details, caveats and the guesses that turned out wrong: `docs/design-notes.md`.

## Verification
- **Unit testbenches** for every module (about 21 million checks): hand-derived directed cases plus random cases
  against an independent C++ model (`make test`).
- **Spike co-simulation:** every retired instruction (PC, word, register and memory effects) of the 12 programs,
  230,706 instructions, is identical to Spike (`make cosim`).
- **Fuzzing:** seeded random programs compared with Spike, with and without M instructions; 411,006 and 411,536
  instructions identical in the 500-program runs (`make fuzz`, `make fuzz FUZZ_M=m`).
- **Mutation checks:** 15 faults planted in the RTL, among them a wrong shift, a signed/unsigned compare, a hazard check
  missing a source register, an unrestored predictor history, a BTB hit that ignores its tag, a broken return-stack
  repair and a multiplier held wrongly, were each caught by the intended test (table in the design notes).

## Layout
    rtl/       SystemVerilog: alu, regfile, decoder, branch_cmp, lsu, mem, core (single-cycle), core_pipe,
               bpred, btb, ras, muldiv, soc_top, packages
    tb/        Verilator C++ testbenches (one per module, plus the SoC harness)
    sw/        test programs and benchmark kernels, startup code, linker script
    scripts/   bin2mem.py, cosim.py, fuzz.py, gen_random.py, gen_muldiv_test.py, bp_sim.py, perf_table.py
    docs/      design notes

## Requirements
Verilator 5.x, a C++ compiler, Python 3, the RISC-V binutils and gcc (on Ubuntu: `binutils-riscv64-unknown-elf`,
`gcc-riscv64-unknown-elf`), and Spike built from riscv-software-src/riscv-isa-sim (run
`git submodule update --init --recursive` in the clone first).

## Usage
    make test            # unit testbenches for every module
    make lint            # lint the single-cycle core (make lint-pipe for the pipeline)
    make programs        # run the 12 self-checking programs
    make cosim           # compare every program with Spike, instruction by instruction
    make fuzz            # random programs vs Spike (FUZZ_M=m adds M instructions; FUZZ_FIRST, FUZZ_COUNT, FUZZ_ITEMS)
    make perf            # cycles, IPC and where the lost cycles went
    make perf-table      # markdown tables for all branch-handling configurations (slow)
    make bp              # offline branch predictor study on the benchmark kernels
    make run PROG=test_alu                     # one program with a full trace
    make run PROG=first_loop ARGS=+expect=15   # check an exit code

Variables, usable with any of the above: `CORE=single|pipe`, `PRED=gshare|bimodal|none`, `RAS=0|1`,
`RAS_DEPTH=<log2 entries>`, `BTB_BITS=<log2 entries>`, `MUL_BITS=<n> DIV_BITS=<n>` (result bits per cycle).
A program ends by storing its exit code to 0x20000000 (Spike has a built-in device at 0x10000000); 0 means pass.
