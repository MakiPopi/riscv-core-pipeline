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
- **Simulation exit:** a store to 0x20000000 ends the run; the stored value is the
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
- The hand-written instruction words in `decoder_tb.cpp`
  (to be cross-checked with the assembler and with Spike).

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
| `test_jump` | jal forward/backward/far (about 8 KB each way), jal x0, jalr with zero, positive and negative offsets, bit-0 clearing three ways, rd == rs1, link values checked against auipc, call and nested return |
| `test_mem` | lb/lbu/lh/lhu/lw at every offset (sign bit set, clear and mixed), negative offsets, rd == rs1, loads into x0, sb/sh/sw lane isolation, negative store offsets, sentinels for the rd-field bits of stores, guard words, fence as a no-op (assembler encoding 0ff0000f) |

Mutation checks (a fault planted in the RTL must make a program fail at the expected check):
- ALU arithmetic shift made logical: `test_alu` fails with code 21.
- Branch comparator `blt` made unsigned: `test_branch` fails with code 15.
- `jalr` bit-0 clearing removed from the core: `test_jump` stops with a TRAP on the first odd target.
- Link value changed from PC+4 to PC: `test_jump` fails with code 2.
- `sb` byte enable always lane 0: `test_mem` fails with code 43.
- Halfword select uses `addr_lo[0]` instead of `addr_lo[1]`: `test_mem` fails with code 13.

Not covered at program level: misaligned loads/stores and misaligned jumps. They stop the core
for now and belong to the exceptions phase.

## Co-simulation with Spike
scripts/cosim.py runs the core and Spike (--isa=rv32i --log-commits) on the same ELF and
compares the retirement trace line by line: PC, instruction word, register write and memory
access. Spike's boot ROM (5 instructions at 0x1000) is skipped; the comparison starts at
0x80000000. Spike is stopped after as many instructions as the core retired, so the two do not
need the same exit mechanism.

- Exit address: 0x20000000. Spike has a built-in device at 0x10000000 (giving Spike RAM there
  fails with an "overlap" error), so the exit address was moved. Spike gets a 4 KiB RAM at
  0x20000000 so that the exit store is an ordinary store.
- Spike build: needs the berkeley-softfloat-3 git submodule
  (git submodule update --init --recursive) before make works. Installed under ~/riscv.
- Results: first_loop 19, test_alu 154, test_branch 212, test_jump 80, test_mem 249
  instructions (714 total), all identical.
- Mutation check: ALU arithmetic shift made logical. The program's own check only notices at the
  exit store (instruction 76); cosim reports the faulty srai itself (instruction 70, core
  0x08000000, Spike 0xf8000000).
- Reference version: Spike 1.1.1-dev (riscv-isa-sim commit 020edce6).

## Randomized co-simulation
scripts/gen_random.py writes a random RV32I program for a given seed; scripts/fuzz.py builds
each one with the normal Makefile rules and compares it with Spike using cosim.py.
Generator rules: forward-only branches/jumps (always terminates); x31 is a never-written base
register pointing at the middle of a 1 KiB scratch area, with aligned offsets (no misaligned or
out-of-range accesses); x30 is a jump-target temporary; x1..x29 are initialised first (nothing
depends on Spike's boot code); half of the source registers come from the last four destinations
(dependency chains); 30% of memory offsets use a 32-byte window (store/load collisions); jalr is
generated with offsets 0 and 1 (bit-0 clearing); occasional writes to x0; the program ends by
storing x1..x29 so the final register state is part of the trace.
Not covered: loops, traps, misaligned accesses, CSRs, instructions outside RV32I.
Failing programs are kept in build/fuzz/ and can be reproduced from the seed.
- Fuzz run: seeds 1-200 (300 items each), 90843 instructions identical to Spike. Mutation check: sltu compared as signed was caught by 20 of 20 seeds (first mismatch at an sltiu).
- Step 2 (forwarding from MEM and WB into the ALU inputs, branch comparator and store data): all five
  directed programs and cosim pass (714 instructions identical). `make fuzz`: 199 of 200 seeds fail.
  In every first mismatch a load is followed by an instruction that uses its result, and the core's value
  is computed from the load ADDRESS (forwarding takes ex_mem.alu_result): seed 1 `sll x20,x28,x28` gave
  0x2c480000 = 0x80000b12 << 18; seed 2 `andi x11,x28,0x6eb` gave 0x2e0 = 0x80000ae0 & 0x6eb; seed 3 stored
  0x0ad3 (low half of the address) instead of the loaded byte 0x9f. This is the load-use hazard.

## 5-stage pipeline (branch `pipeline`)
- Stages IF, ID, EX, MEM, WB; pipeline registers are packed structs in `pipe_pkg.sv`. A bubble is
  the all-zeros value (valid = 0, every control signal 0). Same ports as `core.sv`, so the SoC can
  use either: `CORE=single|pipe` (Makefile) selects it through the `PIPELINED` parameter of soc_top.
  `PIPELINED` is an `int` because Verilator's `-G` passes 32-bit constants.
- Control hazards: branches and jumps resolve in EX, with predict-not-taken. A taken branch flushes
  IF/ID and ID/EX, a 2-cycle penalty. Traps travel with the instruction and are reported in WB;
  a trapped instruction writes no register, and a store is blocked while an older instruction traps.
- Step 1 (no data-hazard handling): all five programs fail. first_loop mismatched at instruction 3
  (`add` read a register written one instruction earlier). Causes seen: stale values in ALU operations,
  in `li` of 32-bit constants (lui+addi on one register), in a branch comparison (wrong path taken),
  and in the exit store (the core ran off the end of the code).
- Step 2 (forwarding from MEM and WB into the ALU inputs, branch comparator and store data): all five
  directed programs and cosim pass. `make fuzz`: 199 of 200 seeds fail. In every first mismatch a load is
  followed by an instruction that uses its result, and the core's value is computed from the load ADDRESS
  (forwarding takes ex_mem.alu_result): seed 1 `sll x20,x28,x28` gave 0x2c480000 = 0x80000b12 << 18;
  seed 2 `andi x11,x28,0x6eb` gave 0x2e0 = 0x80000ae0 & 0x6eb; seed 3 stored 0x0ad3 (low half of the
  address) instead of the loaded byte 0x9f. This is the load-use hazard.
- Step 3 (load-use stall: if the load in EX writes a source of the instruction in ID, hold the PC and
  IF/ID for one cycle and put a bubble in EX; the load data then reaches the consumer by forwarding from WB):
  all five programs and cosim pass; fuzz seeds 1-200 (300 items): 90843 instructions identical to Spike;
  seeds 1000-1499 (600 items): 500 programs, 411006 instructions identical.
- Mutation check on the stall: dropping the rs2 half of the condition fails 15 of 20 seeds, and the first
  mismatch is a store whose data register was loaded by the instruction right above (seed 1: `sh x27` stored
  0x0b2c, the low half of the load address, instead of 0x04cf; seed 5: `sw x3` stored the whole address).

## 5-stage pipeline
- Stages IF, ID, EX, MEM, WB; pipeline registers are packed structs in `pipe_pkg.sv`. A bubble is
  the all-zeros value (valid = 0, every control signal 0). Same ports as `core.sv`, so the SoC can
  use either: `CORE=single|pipe` (Makefile) selects it through the `PIPELINED` parameter of soc_top.
  `PIPELINED` is an `int` because Verilator's `-G` passes 32-bit constants.
- Control hazards: branches and jumps resolve in EX, with predict-not-taken. A taken branch flushes
  IF/ID and ID/EX, a 2-cycle penalty. Traps travel with the instruction and are reported in WB;
  a trapped instruction writes no register, and a store is blocked while an older instruction traps.
- Step 1 (no data-hazard handling): all five programs fail. first_loop mismatched at instruction 3
  (`add` read a register written one instruction earlier). Causes seen: stale values in ALU operations,
  in `li` of 32-bit constants (lui+addi on one register), in a branch comparison (wrong path taken),
  and in the exit store (the core ran off the end of the code).
- Step 2 (forwarding from MEM and WB into the ALU inputs, branch comparator and store data): all five
  directed programs and cosim pass. `make fuzz`: 199 of 200 seeds fail. In every first mismatch a load is
  followed by an instruction that uses its result, and the core's value is computed from the load ADDRESS
  (forwarding takes ex_mem.alu_result): seed 1 `sll x20,x28,x28` gave 0x2c480000 = 0x80000b12 << 18;
  seed 2 `andi x11,x28,0x6eb` gave 0x2e0 = 0x80000ae0 & 0x6eb; seed 3 stored 0x0ad3 (low half of the
  address) instead of the loaded byte 0x9f. This is the load-use hazard.
- Step 3 (load-use stall: if the load in EX writes a source of the instruction in ID, hold the PC and
  IF/ID for one cycle and put a bubble in EX; the load data then reaches the consumer by forwarding from WB):
  all five programs and cosim pass; fuzz seeds 1-200 (300 items): 90843 instructions identical to Spike;
  seeds 1000-1499 (600 items): 500 programs, 411006 instructions identical.
- Mutation check on the stall: dropping the rs2 half of the condition fails 15 of 20 seeds, and the first
  mismatch is a store whose data register was loaded by the instruction right above (seed 1: `sh x27` stored
  0x0b2c, the low half of the load address, instead of 0x04cf; seed 5: `sw x3` stored the whole address).

## Performance accounting (make perf)
The core exposes two event signals, `perf_stall` (a load-use stall cycle) and `perf_flush` (a taken
branch/jump redirect, 2 cycles lost). The harness counts cycles and events and prints
`other = cycles - instructions - stalls - 2*flushes`, which must equal the pipeline fill (4 cycles for
the 5-stage pipeline, 0 for the single-cycle core); it is a consistency check on the counters.
Counts stop at the exit store. Real CSR counters (mcycle, minstret) come with the CSR work.

| Program | single-cycle cycles | pipeline cycles | IPC | load-use stalls | flushes |
|---|---|---|---|---|---|
| first_loop | 19 | 31 | 0.613 | 0 | 4 |
| test_alu | 154 | 240 | 0.642 | 0 | 41 |
| test_branch | 212 | 348 | 0.609 | 0 | 66 |
| test_jump | 80 | 152 | 0.526 | 0 | 34 |
| test_mem | 249 | 369 | 0.675 | 0 | 58 |
| fuzz_1 | 454 | 554 | 0.819 | 4 | 46 |

- other = 4 in every pipeline run and 0 in every single-cycle run.
- The directed programs are dominated by taken branches (every passing CHECK is a taken beq) and none
  has a load-use pair (each load is followed by a CHECK that starts with an independent li), so their
  IPC is not representative. fuzz_1: of 100 lost cycles, 92 are branch/jump flushes, 4 load-use stalls,
  4 pipeline fill. The random generator's instruction mix is for coverage, not realism: use CoreMark/Dhrystone
  for results.

## Compiled C programs
`sw/<name>.c` is linked with `sw/crt0.S` (sets sp to 0x80010000, calls main, stores main's return
value to the exit address). Flags: `-O2 -march=rv32i -mabi=ilp32 -ffreestanding -fno-builtin
-fno-tree-loop-distribute-patterns -mno-relax -msmall-data-limit=0 -nostdlib`: no libc, no multiply or
divide (rv32i has none, so `*` would need libgcc's `__mulsi3`), no compressed instructions, no gp-relative
data. Programs check themselves and return 0 on success.
- `bench_sort`: insertion sort of 128 xorshift32 values, checked by sum and by order. 27,025 instructions,
  identical to Spike. Single-cycle: IPC 1.000. Pipeline: 39,984 cycles, IPC 0.676, 3,983 load-use stalls,
  4,487 flushes (before the crt0 fix below). Of 12,959 lost cycles: 69% flushes, 31% load-use stalls.
  If every flush penalty vanished: 31,012 cycles, IPC about 0.87. This is the headroom of a branch
  predictor on this program; the stalls remain.
- Accounting caveat: `other = 4` holds only if the instructions after the exit store do not redirect.
  crt0 originally ended with `j .`; that jump redirected one cycle before the exit store retired, so its
  flush was counted but its penalty cycles lay after the exit, giving other = 2. Fixed by ending crt0 with
  `ebreak` (never reached; illegal in our decoder, so it cannot redirect). The `2 * flushes` formula also
  stops being exact once predictors make the penalty vary.
- Bug found in my own linker script: `*(COMMON)` was written inside the parentheses of another pattern
  (syntax error, which broke every program build). It was caught immediately because every program uses the
  same script.
- After the crt0 fix (ebreak at the end of crt0): bench_sort cycles=39984, flushes=4486, other=4.

## Baseline: pipeline with predict-not-taken, flush in EX (2-cycle penalty)
All benchmark kernels pass on both cores and are identical to Spike (sort 27025, sieve 14704, calls 108713,
collatz 17714 instructions). Single-cycle IPC is 1.000 everywhere. Pipeline:

| Program | Instr. | Cycles | IPC | Load-use stalls | Flushes | Lost to flushes | Lost to stalls | IPC if flushes free | IPC if flush = 1 cycle |
|---|---|---|---|---|---|---|---|---|---|
| bench_sort | 27025 | 39984 | 0.676 | 3983 | 4486 | 69% | 31% | 0.871 | 0.761 |
| bench_sieve | 14704 | 21432 | 0.686 | 998 | 2863 | 85% | 15% | 0.936 | 0.792 |
| bench_calls | 108713 | 135529 | 0.802 | 300 | 13256 | 99% | 1% | 0.997 | 0.889 |
| bench_collatz | 17714 | 24436 | 0.725 | 0 | 3359 | 100% | 0% | 1.000 | 0.840 |

- cycles = instructions + stalls + 2 * flushes + 4 holds exactly for every program.
- The last two columns are upper bounds on what any branch handling can reach, not designs.
- bench_sieve: 998 stalls = number of outer-loop iterations (load of composite[i] feeds a branch).
- bench_calls: almost all lost cycles are call/return flushes; a direction predictor cannot predict returns.
- bench_collatz: hypothesis that gcc if-converted the odd/even choice was doubted afterwards (17714
  instructions for 3142 steps is too few for branch-free code); to be settled by the predictor study.
