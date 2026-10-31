# riscv-core-pipeline
A parameterizable RISC-V (RV32I) in-order core written in SystemVerilog,
built as a platform for microarchitecture exploration.

## Roadmap
- [ ] 5-stage pipeline with forwarding and hazard detection
- [ ] Co-simulation against golden ISA model
- [ ] Branch prediction (bimodal, gshare, BTB)
- [ ] Parameterizable L1 I/D caches
- [ ] M extension, CSRs, exceptions
- [ ] Performance counters + benchmark analysis (CoreMark, Dhrystone)
- [ ] Stretch: superscalar / out-of-order, FPGA synthesis

## Status
Work in progress. Rebuilding my earlier 5-stage pipeline from scratch
with a focus on verification and design-space analysis.
