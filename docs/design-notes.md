# Design notes

## Decisions
- **ISA:** RV32I first; M extension and CSRs later.
- **Language / simulator:** SystemVerilog, Verilator, C++ testbenches.
- **ALU does all address and target math.** Load/store address, branch/JAL target,
  LUI and AUIPC are all ADDs. The decoder selects ALU inputs (`a_sel`: rs1/PC/zero,
  `b_sel`: rs2/imm). Branch *taken* is decided by a separate comparator.
- **Register file:** two read ports, one write port, x0 has no storage. The
  same-cycle bypass (a read of the register being written returns the new value)
  is a parameter, `BYPASS`. A pipeline needs it on (Write-back and Decode overlap).
  The single-cycle core needs it OFF: with it on, `addi x1, x1, 1` would read its own
  result through a combinational loop. This was found while designing the core, not by a test.
- **Decoder:** emits `uses_rs1` / `uses_rs2` (so LUI/JAL do not create fake hazards)
  and an `illegal` flag. Illegal instructions have no side effects.
- **Load/store unit:** word-based memory interface with 4 byte enables. Store data
  is replicated across lanes and the byte enable picks the lane. Misaligned accesses
  are flagged and never written.
- **Memory model:** zero-latency, combinational read, byte-enable write, 64 KiB at
  0x80000000 (Spike's default base). Out-of-range reads return 0 and out-of-range
  writes are ignored (no wraparound). Loaded with `$readmemh` via `+hex=<file>`.
  Memory latency comes later, together with caches.
- **Core (single-cycle):** the five stages are one combinational path between clock
  edges. JALR clears bit 0 of its target. Reset is synchronous, active high.
- **Traps:** until CSRs exist there are no exceptions. On an illegal instruction, a
  misaligned jump/branch target, or a misaligned load/store, `trap` goes high and
  nothing changes: no register write, no memory write, no PC update.
- **Retirement trace:** `ret_valid`, PC, instruction, destination register and value,
  memory access type/address/data. One record per completed instruction. This is the
  interface for the Spike comparison.
- **Simulation exit:** a store to 0x10000000 ends the run; the stored value is the
  exit code. The harness detects it from the trace, so the core has no special hardware.

## Verification approach
Unit level: each module has a self-checking testbench with
1. directed tests (expected values worked out by hand),
2. randomized tests against an independent C++ model, with edge values
   (0, 1, -1, INT_MIN, INT_MAX) and forced collisions (e.g. a == b for branches).
The decoder is also swept over every opcode/funct3/funct7 combination.

System level: assembly programs in `sw/` check their own results with the `CHECK`
macro (expected values worked out by hand from the spec) and report the number of the
first failing check as the exit code.

Checks performed so far:
- The decoder's opcode/funct3/funct7 table was compared with the Cornell CS 3410
  RISC-V quick reference (which quotes the RISC-V manual): all entries matched.
- The hand-assembled `first_loop.mem` is identical to the real assembler's output
  (covers addi, add, bne, lui, sw encodings, including the branch immediate).
- Mutation check: replacing the ALU's arithmetic shift with a logical shift makes
  `test_alu` fail with exit code 21 (the first `srai` check); restoring it passes.
  So the system-level test detects a fault planted below the core.

Not yet independently checked:
- FENCE encoding, and the other hand-written instruction words in `decoder_tb.cpp`
  (to be cross-checked with the assembler and with Spike).
- Jumps and loads/stores at the program level (tests still to be written).

## Open items
- Misaligned fetch/branch targets and misaligned loads/stores should trap as real
  exceptions (exceptions phase); today they stop the core.
- ECALL, EBREAK, CSR instructions and the M extension decode as illegal.
- FENCE is a no-op (single core, no caches yet).
- Cleanup: remove `sw/first_loop.mem` and the `run-first` Makefile target once a
  proper test runner replaces them (the assembler builds the same file).

## Program-level test coverage
| Program | Covers |
|---|---|
| `first_loop` | addi, add, bne (backward), lui, sw; exit-by-store; read-and-write of one register |
| `test_alu` | all OP and OP-IMM instructions with edge values, lui, auipc, x0 behaviour, shift-amount masking |
| `test_branch` | beq/bne/blt/bge/bltu/bgeu taken and not taken (signed vs. unsigned edge values, swapped operands, x0, same register), far branches of about +4 KiB and -4 KiB, and sentinel registers showing that branches never write a register |

Mutation checks (a fault planted in the RTL must make a program fail at the expected check):
- ALU arithmetic shift made logical: `test_alu` fails with code 21.
- Branch comparator `blt` made unsigned: `test_branch` fails with code 15.
