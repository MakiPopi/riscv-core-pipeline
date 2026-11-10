# riscv-core-pipeline

A parameterizable RISC-V (RV32I) in-order core written in SystemVerilog,
built as a platform for microarchitecture exploration.

## Roadmap
- [x] ALU, register file, instruction decoder, branch comparator, load/store unit
      (each with a self-checking Verilator testbench)
- [x] Single-cycle core + memory model + retirement trace (runs first hand-assembled program)
- [ ] Co-simulation against Spike (golden ISA model), riscv-tests
- [ ] 5-stage pipeline with forwarding and hazard detection
- [ ] Performance counters (cycles, instructions, IPC)
- [ ] Branch prediction (bimodal, gshare, BTB)
- [ ] Parameterizable L1 I/D caches
- [ ] M extension, CSRs, exceptions
- [ ] Benchmarks (CoreMark, Dhrystone) and design-space analysis
- [ ] Stretch: superscalar / out-of-order, FPGA synthesis

## Running the unit tests
Requires Verilator and a C++ compiler.

    make test          # build and run every module testbench
    make decoder       # run a single module

## Status
Work in progress. Datapath modules are complete and tested; the core is next.
See `docs/design-notes.md` for design decisions and open items.
