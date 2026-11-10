# riscv-core-pipeline

A parameterizable RISC-V (RV32I) in-order core written in SystemVerilog,
built as a platform for microarchitecture exploration.

## Roadmap
- [x] ALU, register file, instruction decoder, branch comparator, load/store unit
      (each with a self-checking Verilator testbench)
- [x] Memory model, single-cycle core, SoC wrapper, simulation harness
- [x] Retirement trace (one record per completed instruction)
- [x] Toolchain flow: assembly -> ELF -> hex, run with `make run`
- [x] Self-checking assembly test framework (ALU instructions covered)
- [x] Self-checking test for all six branch types
- [x] Self-checking test for jal and jalr (links, bit-0 clearing, call/return)
- [ ] Self-checking test for loads and stores
- [ ] Co-simulation against Spike (golden ISA model), riscv-tests
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
    scripts/   helper scripts (bin2mem.py)
    docs/      design notes

## Requirements
Verilator (5.x), a C++ compiler, Python 3, and the RISC-V binutils/gcc
(`binutils-riscv64-unknown-elf`, `gcc-riscv64-unknown-elf` on Ubuntu).

## Usage
    make test                                  # unit testbench for every module
    make lint                                  # lint the whole core
    make programs                              # run every self-checking program
    make run PROG=test_alu                     # run one program with a full trace
    make run PROG=first_loop ARGS=+expect=15   # check the exit code

A program ends by storing its exit code to 0x10000000; 0 means every check passed.

## Status
Single-cycle core runs self-checking programs. The pipelined core and the
Spike comparison are next. See `docs/design-notes.md` for design decisions,
verification notes and open items.
