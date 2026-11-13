# riscv-core-pipeline

A parameterizable RISC-V (RV32I) in-order core written in SystemVerilog,
built as a platform for microarchitecture exploration.

## Roadmap
- [x] ALU, register file, instruction decoder, branch comparator, load/store unit
      (each with a self-checking Verilator testbench)
- [x] Memory model, single-cycle core, SoC wrapper, simulation harness
- [x] Retirement trace (one record per completed instruction)
- [x] Toolchain flow: assembly -> ELF -> hex, run with `make run`
- [x] Self-checking assembly tests for every instruction the decoder supports
      (ALU, branches, jumps, loads/stores)
- [x] Co-simulation against Spike: every retired instruction of every test program compared
- [ ] riscv-tests and randomized instruction streams
- [ ] 5-stage pipeline with forwarding and hazard detection
- [ ] Performance counters (cycles, instructions, IPC)
- [ ] Branch prediction (bimodal, gshare, BTB)
- [ ] Parameterizable L1 I/D caches
- [ ] M extension, CSRs, exceptions
- [ ] Benchmarks (CoreMark, Dhrystone) and design-space analysis
- [ ] Stretch: superscalar / out-of-order, FPGA synthesis

## Layout
    rtl/       SystemVerilog sources
    tb/        Verilator C++ testbenches (one per module, plus the SoC harness)
    sw/        test programs (assembly), linker script, shared test macros
    scripts/   helper scripts (bin2mem.py, cosim.py)
    docs/      design notes

## Requirements
Verilator (5.x), a C++ compiler, Python 3, the RISC-V binutils/gcc
(`binutils-riscv64-unknown-elf`, `gcc-riscv64-unknown-elf` on Ubuntu), and Spike
built from riscv-software-src/riscv-isa-sim (run `git submodule update --init --recursive`
in the clone before building).

## Usage
    make test                                  # unit testbench for every module
    make lint                                  # lint the whole core
    make programs                              # run every self-checking program
    make cosim                                 # compare every program with Spike, instruction by instruction
    make run PROG=test_alu                     # run one program with a full trace
    make run PROG=first_loop ARGS=+expect=15   # check the exit code

A program ends by storing its exit code to 0x20000000 (Spike has a built-in device at
0x10000000, so that address cannot be used); 0 means every check passed.

## Status
The single-cycle core passes all self-checking programs and matches Spike instruction by
instruction. Randomized co-simulation and the pipelined core are next. See
`docs/design-notes.md` for design decisions, verification notes and open items.
