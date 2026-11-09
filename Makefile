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
