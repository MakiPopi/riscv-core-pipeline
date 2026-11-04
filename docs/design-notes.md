# Design notes

## Decisions
- **ISA:** RV32I first; M extension and CSRs later.
- **Language / simulator:** SystemVerilog, Verilator, C++ testbenches.
- **ALU does all address and target math.** Load/store address, branch/JAL target,
  LUI and AUIPC are all ADDs. The decoder selects ALU inputs (`a_sel`: rs1/PC/zero,
  `b_sel`: rs2/imm). Branch *taken* is decided by a separate comparator.
- **Register file** has two read ports and one write port. x0 has no storage.
  A read of the register being written in the same cycle returns the new value
  (internal bypass), so the future forwarding unit only has to cover instructions
  one and two stages apart.
- **Decoder** emits `uses_rs1` / `uses_rs2` (so LUI/JAL do not create fake hazards)
  and an `illegal` flag. Illegal instructions have no side effects.
- **Load/store unit** uses a word-based memory interface with 4 byte enables.
  Misaligned accesses are flagged and never written.
- **Memory map (planned):** reset PC and memory base at 0x80000000 to match Spike.

## Verification approach
Each module has a self-checking testbench with:
1. directed tests (expected values worked out by hand),
2. randomized tests against an independent C++ model, with edge values
   (0, 1, -1, INT_MIN, INT_MAX) and forced collisions (e.g. a == b for branches).
The decoder is also swept over every opcode/funct3/funct7 combination.

The decoder's opcode/funct3/funct7 table was checked against the Cornell CS 3410
RISC-V quick reference. Not yet independently checked: FENCE encoding and the
hand-written directed instruction words (to be cross-checked with the RISC-V
assembler and Spike).

## Open items
- JALR must clear bit 0 of its target (belongs in next-PC logic).
- Misaligned fetch/branch targets and misaligned loads/stores must trap (exceptions phase).
- ECALL, EBREAK, CSR instructions and M-extension are currently decoded as illegal.
- FENCE is a no-op (single core, no caches yet).
