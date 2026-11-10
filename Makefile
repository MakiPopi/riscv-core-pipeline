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

SOC_RTL := $(CORE_RTL) rtl/mem.sv rtl/soc_top.sv
SOC_BIN := $(BUILD)/soc_top/soc_top_tb

.PHONY: soc run-first

soc:
> @mkdir -p $(BUILD)/soc_top
> @$(VERILATOR) $(VFLAGS) --top-module soc_top --Mdir $(BUILD)/soc_top -o soc_top_tb \
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

$(BUILD)/prog/%.elf: sw/%.S sw/link.ld
> @mkdir -p $(BUILD)/prog
> $(RVAS) $(RVFLAGS) $< -o $(BUILD)/prog/$*.o
> $(RVLD) -m elf32lriscv -T sw/link.ld -o $@ $(BUILD)/prog/$*.o

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
PROGRAMS := first_loop test_alu test_branch
EXPECT_first_loop := 15

.PHONY: programs
programs: $(PROGRAMS:%=prog-%)

prog-%: soc $(BUILD)/prog/%.mem
> @if out=$$(./$(SOC_BIN) +hex=$(BUILD)/prog/$*.mem +notrace +expect=$(or $(EXPECT_$*),0)); then \
>     echo "PASS  $*"; \
>   else \
>     echo "FAIL  $*"; echo "$$out"; exit 1; \
>   fi
