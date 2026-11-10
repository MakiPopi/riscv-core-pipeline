#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "Vsoc_top.h"
#include "verilated.h"

// A store to this address ends the simulation. The stored value is the exit code.
static const uint32_t EXIT_ADDR = 0x10000000u;

static Vsoc_top* dut;

// One full clock pulse. The core's state (PC, registers, memory) updates on the rising edge.
static void tick() {
  dut->clk = 1; dut->eval();
  dut->clk = 0; dut->eval();
}

// Look for "+name=value" on the command line. Returns true and sets 'out' if found.
static bool plusarg(int argc, char** argv, const char* prefix, long& out) {
  size_t n = strlen(prefix);
  for (int i = 1; i < argc; i++)
    if (strncmp(argv[i], prefix, n) == 0) {
      out = strtol(argv[i] + n, nullptr, 0);   // base 0: accepts decimal or 0x...
      return true;
    }
  return false;
}

static int finish(int status) {
  dut->final();
  delete dut;
  return status;
}

// One trace line per retired instruction:
//   pc (inst) [x<rd> value] [mem addr [store data]]
static void print_trace() {
  printf("0x%08x (0x%08x)", dut->ret_pc, dut->ret_inst);
  if (dut->ret_rd) printf(" x%-2d 0x%08x", dut->ret_rd, dut->ret_rd_data);
  if (dut->ret_mem_we) {
    int size = (dut->ret_inst >> 12) & 3;   // 0 = byte, 1 = half, 2 = word
    uint32_t mask = (size == 2) ? 0xFFFFFFFFu : ((1u << (8 << size)) - 1);
    printf(" mem 0x%08x 0x%0*x", dut->ret_mem_addr, 2 << size, dut->ret_mem_data & mask);
  } else if (dut->ret_mem_re) {
    printf(" mem 0x%08x", dut->ret_mem_addr);
  }
  printf("\n");
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);   // must come before the model is created: memory reads +hex=
  dut = new Vsoc_top;

  long max_cycles = 1000000, expect = 0;
  plusarg(argc, argv, "+maxcycles=", max_cycles);
  bool has_expect = plusarg(argc, argv, "+expect=", expect);
  bool trace = true;
  for (int i = 1; i < argc; i++)
    if (strcmp(argv[i], "+notrace") == 0) trace = false;

  // Reset: hold rst high for two clock pulses, then release it.
  dut->clk = 0;
  dut->rst = 1;
  dut->eval();
  tick();
  tick();
  dut->rst = 0;
  dut->eval();

  long retired = 0;
  for (long cycle = 0; cycle < max_cycles; cycle++) {
    // The outputs now describe the instruction at the current PC. Read them,
    // THEN clock, because the clock edge moves on to the next instruction.
    if (dut->trap) {
      printf("TRAP: pc=0x%08x inst=0x%08x after %ld instructions\n",
             dut->ret_pc, dut->ret_inst, retired);
      return finish(3);
    }
    if (dut->ret_valid) {
      retired++;
      if (trace) print_trace();
      if (dut->ret_mem_we && dut->ret_mem_addr == EXIT_ADDR) {
        uint32_t code = dut->ret_mem_data;
        printf("EXIT: code=%u (0x%x) after %ld instructions\n", code, code, retired);
        if (has_expect) {
          if ((long)code != expect) {
            printf("FAIL: expected %ld\n", expect);
            return finish(1);
          }
          printf("PASS\n");
        }
        return finish(0);
      }
    }
    tick();
  }

  printf("TIMEOUT after %ld cycles (%ld instructions retired)\n", max_cycles, retired);
  return finish(2);
}
