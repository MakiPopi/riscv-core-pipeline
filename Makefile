.RECIPEPREFIX := >

VERILATOR := verilator
VFLAGS    := --cc --exe --build -Wall
BUILD     := build

# Modules that have a unit testbench: tb/<name>_tb.cpp
MODULES := alu regfile decoder branch_cmp lsu mem

# RTL files each module needs (packages must come before the files that import them)
RTL_alu     := rtl/alu_pkg.sv rtl/alu.sv
RTL_regfile := rtl/regfile.sv
RTL_decoder := rtl/alu_pkg.sv rtl/decode_pkg.sv rtl/decoder.sv
RTL_branch_cmp := rtl/branch_cmp.sv
RTL_lsu := rtl/lsu.sv
RTL_mem := rtl/mem.sv

.PHONY: all test clean $(MODULES)

all: test

test: $(MODULES)

$(MODULES):
> @echo "== $@ =="
> @mkdir -p $(BUILD)/$@
> @$(VERILATOR) $(VFLAGS) --top-module $@ --Mdir $(BUILD)/$@ -o $@_tb \
>     $(RTL_$@) tb/$@_tb.cpp > $(BUILD)/$@/build.log 2>&1 \
>     || (cat $(BUILD)/$@/build.log; exit 1)
> @grep '%Warning' $(BUILD)/$@/build.log || true
> @./$(BUILD)/$@/$@_tb

clean:
> rm -rf $(BUILD)

CORE_RTL := rtl/alu_pkg.sv rtl/decode_pkg.sv rtl/alu.sv rtl/decoder.sv rtl/regfile.sv \
            rtl/branch_cmp.sv rtl/lsu.sv rtl/core.sv

.PHONY: lint
lint:
> $(VERILATOR) --lint-only -Wall --top-module core $(CORE_RTL)

SOC_RTL := $(CORE_RTL) rtl/pipe_pkg.sv rtl/bpred.sv rtl/btb.sv rtl/core_pipe.sv rtl/mem.sv rtl/soc_top.sv
SOC_BIN := $(BUILD)/soc_top/soc_top_tb

.PHONY: soc run-first

soc:
> @mkdir -p $(BUILD)/soc_top
> @$(VERILATOR) $(VFLAGS) --top-module soc_top -GPIPELINED=$(PIPELINED) -GBP_ENABLE=$(BP_ENABLE) -GBP_INDEX_BITS=$(BP_INDEX) -GBP_HIST_BITS=$(BP_HIST) -GBTB_INDEX_BITS=$(BTB_BITS) --Mdir $(BUILD)/soc_top -o soc_top_tb \
>     $(SOC_RTL) tb/soc_top_tb.cpp > $(BUILD)/soc_top/build.log 2>&1 \
>     || (cat $(BUILD)/soc_top/build.log; exit 1)
> @grep '%Warning' $(BUILD)/soc_top/build.log || true

run-first: soc
> ./$(SOC_BIN) +hex=sw/first_loop.mem +expect=15

# ---- Building programs from assembly ----
RVAS := riscv64-unknown-elf-as
RVLD := riscv64-unknown-elf-ld
RVOC := riscv64-unknown-elf-objcopy
RVFLAGS := -march=rv32i -mabi=ilp32

$(BUILD)/prog/%.elf: sw/%.S sw/link.ld sw/test_macros.inc
> @mkdir -p $(BUILD)/prog
> $(RVAS) $(RVFLAGS) $< -o $(BUILD)/prog/$*.o
> $(RVLD) --no-warn-rwx-segments -m elf32lriscv -T sw/link.ld -o $@ $(BUILD)/prog/$*.o

$(BUILD)/prog/%.mem: $(BUILD)/prog/%.elf scripts/bin2mem.py
> $(RVOC) -O binary $< $(BUILD)/prog/$*.bin
> python3 scripts/bin2mem.py $(BUILD)/prog/$*.bin $@

# Usage: make run PROG=first_loop ARGS=+expect=15
.PHONY: run
run: soc $(BUILD)/prog/$(PROG).mem
> ./$(SOC_BIN) +hex=$(BUILD)/prog/$(PROG).mem $(ARGS)

# Keep intermediate files (.elf, .o, .bin) so we can disassemble them
.SECONDARY:

# ---- Run every test program: make programs ----
PROGRAMS := first_loop test_alu test_branch test_jump test_mem bench_sort bench_sieve bench_calls bench_collatz
EXPECT_first_loop := 15

.PHONY: programs
programs: $(PROGRAMS:%=prog-%)

prog-%: soc $(BUILD)/prog/%.mem
> @if out=$$(./$(SOC_BIN) +hex=$(BUILD)/prog/$*.mem +notrace +expect=$(or $(EXPECT_$*),0)); then \
>     echo "PASS  $*"; \
>   else \
>     echo "FAIL  $*"; echo "$$out"; exit 1; \
>   fi

# ---- Compare the core's trace with Spike: make cosim ----
.PHONY: cosim
cosim: $(PROGRAMS:%=cosim-%)

cosim-%: soc $(BUILD)/prog/%.mem
> @python3 scripts/cosim.py $*

# ---- Random programs: make fuzz [FUZZ_FIRST=1 FUZZ_COUNT=200 FUZZ_ITEMS=300] ----
FUZZ_FIRST ?= 1
FUZZ_COUNT ?= 200
FUZZ_ITEMS ?= 300

# Generated programs live in build/fuzz/ (see scripts/fuzz.py)
$(BUILD)/prog/fuzz_%.elf: $(BUILD)/fuzz/fuzz_%.S sw/link.ld
> @mkdir -p $(BUILD)/prog
> $(RVAS) $(RVFLAGS) $< -o $(BUILD)/prog/fuzz_$*.o
> $(RVLD) --no-warn-rwx-segments -m elf32lriscv -T sw/link.ld -o $@ $(BUILD)/prog/fuzz_$*.o

.PHONY: fuzz
fuzz:
> python3 scripts/fuzz.py $(FUZZ_FIRST) $(FUZZ_COUNT) $(FUZZ_ITEMS)

# ---- Which core the SoC simulation uses: make programs CORE=single  or  CORE=pipe ----
# (Variables used inside recipes are expanded when the recipe runs, so defining them here is fine.)
CORE ?= pipe
PIPELINED := $(if $(filter pipe,$(CORE)),1,0)

PIPE_RTL := rtl/alu_pkg.sv rtl/decode_pkg.sv rtl/pipe_pkg.sv rtl/alu.sv rtl/decoder.sv \
            rtl/regfile.sv rtl/branch_cmp.sv rtl/lsu.sv rtl/bpred.sv rtl/btb.sv rtl/core_pipe.sv

.PHONY: lint-pipe
lint-pipe:
> $(VERILATOR) --lint-only -Wall --top-module core_pipe $(PIPE_RTL)

# ---- Performance numbers: make perf [CORE=single|pipe] ----
.PHONY: perf
perf: $(PROGRAMS:%=perf-%)

perf-%: soc $(BUILD)/prog/%.mem
> @printf '%-14s' $*; ./$(SOC_BIN) +hex=$(BUILD)/prog/$*.mem +notrace | sed -n 's/^PERF: //p'

# ---- Compiled C programs: sw/<name>.c is linked with sw/crt0.S ----
RVCC := riscv64-unknown-elf-gcc
CFLAGS := -O2 -Wall -Wextra -march=rv32i -mabi=ilp32 -ffreestanding -fno-builtin \
          -fno-tree-loop-distribute-patterns -mno-relax -msmall-data-limit=0

$(BUILD)/prog/%.elf: sw/%.c sw/crt0.S sw/link.ld
> @mkdir -p $(BUILD)/prog
> $(RVCC) $(CFLAGS) -nostdlib -static -T sw/link.ld -Wl,--no-warn-rwx-segments -o $@ sw/crt0.S $<

# ---- Offline branch predictor study on the benchmark kernels: make bp ----
BENCHES := bench_sort bench_sieve bench_calls bench_collatz

.PHONY: bp
bp: soc $(BENCHES:%=$(BUILD)/prog/%.mem)
> python3 scripts/bp_sim.py $(BENCHES)

# ---- Branch direction predictor: unit test in three configurations (INDEX_BITS,HIST_BITS) ----
BPRED_CFGS := 4,0 6,3 10,10

.PHONY: bpred
bpred:
> @for cfg in $(BPRED_CFGS); do \
>   i=$$(echo $$cfg | cut -d, -f1); h=$$(echo $$cfg | cut -d, -f2); \
>   d=$(BUILD)/bpred_$${i}_$${h}; mkdir -p $$d; \
>   echo "== bpred index_bits=$$i hist_bits=$$h =="; \
>   $(VERILATOR) $(VFLAGS) --top-module bpred -GINDEX_BITS=$$i -GHIST_BITS=$$h --Mdir $$d -o bpred_tb \
>     -CFLAGS "-DINDEX_BITS=$$i -DHIST_BITS=$$h" rtl/bpred.sv tb/bpred_tb.cpp > $$d/build.log 2>&1 \
>     || { cat $$d/build.log; exit 1; }; \
>   grep '%Warning' $$d/build.log || true; \
>   ./$$d/bpred_tb || exit 1; \
> done

test: bpred

# ---- Branch target buffer: unit test with 4 entries (many conflicts) and 64 entries ----
BTB_CFGS := 2 6

.PHONY: btb
btb:
> @for i in $(BTB_CFGS); do \
>   d=$(BUILD)/btb_$$i; mkdir -p $$d; \
>   echo "== btb index_bits=$$i =="; \
>   $(VERILATOR) $(VFLAGS) --top-module btb -GINDEX_BITS=$$i --Mdir $$d -o btb_tb \
>     -CFLAGS "-DINDEX_BITS=$$i" rtl/btb.sv tb/btb_tb.cpp > $$d/build.log 2>&1 \
>     || { cat $$d/build.log; exit 1; }; \
>   grep '%Warning' $$d/build.log || true; \
>   ./$$d/btb_tb || exit 1; \
> done

test: btb

# ---- Branch handling in the pipeline: make perf PRED=none|bimodal|gshare (default gshare) ----
PRED     ?= gshare
BTB_BITS ?= 6
BP_ENABLE := $(if $(filter none,$(PRED)),0,1)
BP_INDEX  := $(if $(filter bimodal,$(PRED)),8,10)
BP_HIST   := $(if $(filter bimodal,$(PRED)),0,10)

# ---- Return-address stack: unit test with 2 and 8 entries (log2 = 1, 3) ----
RAS_CFGS := 1 3

.PHONY: ras
ras:
> @for i in $(RAS_CFGS); do \
>   d=$(BUILD)/ras_$$i; mkdir -p $$d; \
>   echo "== ras depth_log2=$$i =="; \
>   $(VERILATOR) $(VFLAGS) --top-module ras -GDEPTH_LOG2=$$i --Mdir $$d -o ras_tb \
>     -CFLAGS "-DDEPTH_LOG2=$$i" rtl/ras.sv tb/ras_tb.cpp > $$d/build.log 2>&1 \
>     || { cat $$d/build.log; exit 1; }; \
>   grep '%Warning' $$d/build.log || true; \
>   ./$$d/ras_tb || exit 1; \
> done

test: ras
