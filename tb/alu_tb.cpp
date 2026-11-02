#include <cstdint>
#include <cstdio>
#include <random>
#include "Valu.h"
#include "verilated.h"

// Must match the codes in rtl/alu_pkg.sv
enum AluOp { ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND };

static Valu* dut;
static int errors = 0;
static int checks = 0;

// Independent C++ model of what the ALU should do
static uint32_t ref_alu(int op, uint32_t a, uint32_t b) {
  switch (op) {
    case ADD:  return a + b;
    case SUB:  return a - b;
    case SLL:  return a << (b & 31);
    case SLT:  return (int32_t)a < (int32_t)b;
    case SLTU: return a < b;
    case XOR:  return a ^ b;
    case SRL:  return a >> (b & 31);
    case SRA:  return (uint32_t)((int32_t)a >> (b & 31));
    case OR:   return a | b;
    case AND:  return a & b;
  }
  return 0;
}

// Drive the inputs, let the logic settle, compare to the expected value
static void check(int op, uint32_t a, uint32_t b, uint32_t expected) {
  dut->op = op;
  dut->a = a;
  dut->b = b;
  dut->eval();
  checks++;
  if (dut->result != expected) {
    printf("FAIL op=%d a=0x%08x b=0x%08x got=0x%08x expected=0x%08x\n",
           op, a, b, dut->result, expected);
    errors++;
  }
}

// Random value, but one time in four an "interesting" edge-case value
static uint32_t pick(std::mt19937& rng) {
  static const uint32_t special[] = {0, 1, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF};
  if (rng() % 4 == 0) return special[rng() % 5];
  return rng();
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Valu;

  // Directed tests: expected values written by hand from the RISC-V spec
  check(ADD,  0xFFFFFFFF, 1, 0x00000000);   // wraps around
  check(SUB,  0, 1, 0xFFFFFFFF);            // 0 - 1 wraps to all ones
  check(SLL,  1, 33, 2);                    // only low 5 bits: shift by 1
  check(SLT,  0xFFFFFFFF, 1, 1);            // -1 < 1 (signed)
  check(SLTU, 0xFFFFFFFF, 1, 0);            // 4294967295 < 1 is false
  check(SRL,  0x80000000, 4, 0x08000000);   // zeros shifted in
  check(SRA,  0x80000000, 4, 0xF8000000);   // sign bit copied in
  check(XOR,  0xFF00FF00, 0x0FF00FF0, 0xF0F0F0F0);
  check(OR,   0xF0F0F0F0, 0x0F0F0F0F, 0xFFFFFFFF);
  check(AND,  0xFF00FF00, 0x0FF00FF0, 0x0F000F00);

  // Random tests: many inputs, compared against the C++ model
  std::mt19937 rng(1);   // fixed seed, so any failure is reproducible
  for (int i = 0; i < 100000; i++) {
    int op = rng() % 10;
    uint32_t a = pick(rng);
    uint32_t b = pick(rng);
    check(op, a, b, ref_alu(op, a, b));
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
