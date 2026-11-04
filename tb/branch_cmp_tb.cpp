#include <cstdint>
#include <cstdio>
#include <random>
#include "Vbranch_cmp.h"
#include "verilated.h"

enum { BEQ = 0, BNE = 1, BLT = 4, BGE = 5, BLTU = 6, BGEU = 7 };

static Vbranch_cmp* dut;
static int errors = 0;
static int checks = 0;

// Independent C++ model
static bool ref_taken(int f3, uint32_t a, uint32_t b) {
  switch (f3) {
    case BEQ:  return a == b;
    case BNE:  return a != b;
    case BLT:  return (int32_t)a <  (int32_t)b;
    case BGE:  return (int32_t)a >= (int32_t)b;
    case BLTU: return a <  b;
    case BGEU: return a >= b;
  }
  return false;   // funct3 = 2 or 3
}

static void check(int f3, uint32_t a, uint32_t b, bool expected) {
  dut->funct3 = f3;
  dut->a = a;
  dut->b = b;
  dut->eval();
  checks++;
  if (dut->taken != expected) {
    printf("FAIL f3=%d a=0x%08x b=0x%08x got=%d expected=%d\n",
           f3, a, b, dut->taken, expected);
    errors++;
  }
}

static uint32_t pick(std::mt19937& rng) {
  static const uint32_t special[] = {0, 1, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF};
  if (rng() % 4 == 0) return special[rng() % 5];
  return rng();
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vbranch_cmp;

  // Directed tests: expected values worked out by hand
  check(BEQ,  5, 5, true);
  check(BEQ,  5, 6, false);
  check(BNE,  5, 6, true);
  check(BNE,  5, 5, false);
  check(BLT,  0xFFFFFFFF, 1, true);         // -1 < 1 signed
  check(BLTU, 0xFFFFFFFF, 1, false);        // 4294967295 < 1 unsigned: false
  check(BLT,  0x80000000, 1, true);         // most negative < 1
  check(BLTU, 0x80000000, 1, false);        // 2147483648 < 1: false
  check(BGE,  1, 0xFFFFFFFF, true);         // 1 >= -1 signed
  check(BGEU, 1, 0xFFFFFFFF, false);        // 1 >= 4294967295: false
  check(BGE,  7, 7, true);                  // equal counts as >=
  check(BGEU, 7, 7, true);
  check(BLT,  7, 7, false);                 // equal is not <
  check(BLTU, 7, 7, false);
  check(2, 5, 5, false);                    // funct3=010 is not a branch
  check(3, 5, 6, false);                    // funct3=011 is not a branch

  // Random tests: all 8 funct3 values (including the two invalid ones)
  std::mt19937 rng(1);   // fixed seed, so failures are reproducible
  for (int i = 0; i < 100000; i++) {
    int f3 = rng() & 7;
    uint32_t a = pick(rng);
    uint32_t b = (rng() % 4 == 0) ? a : pick(rng);   // force a == b sometimes
    check(f3, a, b, ref_taken(f3, a, b));
  }

  dut->final();
  delete dut;

  if (errors) {
    printf("FAILED: %d of %d checks\n", errors, checks);
    return 1;
  }
  printf("PASSED: %d checks\n", checks);
  return 0;
}
