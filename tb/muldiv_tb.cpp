#include <cstdint>
#include <cstdio>
#include <random>
#include "Vmuldiv.h"
#include "verilated.h"

#ifndef MUL_BITS
#define MUL_BITS 4
#endif
#ifndef DIV_BITS
#define DIV_BITS 2
#endif

static const int ITER_MUL = 32 / MUL_BITS;
static const int ITER_DIV = 32 / DIV_BITS;

static Vmuldiv* dut;
static int errors = 0, checks = 0;

static void expect(const char* what, uint32_t got, uint32_t want, int f3, uint32_t a, uint32_t b) {
  checks++;
  if (got != want) {
    errors++;
    if (errors <= 20)
      printf("FAIL %s: f3=%d a=0x%08x b=0x%08x got=0x%08x expected=0x%08x\n", what, f3, a, b, got, want);
  }
}

// ---- Independent model, with the special cases of the RISC-V spec ----
static uint32_t ref(int f3, uint32_t a, uint32_t b) {
  int32_t sa = (int32_t)a, sb = (int32_t)b;
  switch (f3) {
    case 0: return a * b;
    case 1: return (uint32_t)(((int64_t)sa * (int64_t)sb) >> 32);
    case 2: return (uint32_t)(((int64_t)sa * (int64_t)b) >> 32);
    case 3: return (uint32_t)(((uint64_t)a * (uint64_t)b) >> 32);
    case 4:
      if (b == 0) return 0xFFFFFFFFu;
      if (sa == INT32_MIN && sb == -1) return a;
      return (uint32_t)(sa / sb);
    case 5: return b == 0 ? 0xFFFFFFFFu : a / b;
    case 6:
      if (b == 0) return a;
      if (sa == INT32_MIN && sb == -1) return 0;
      return (uint32_t)(sa % sb);
    default: return b == 0 ? a : a % b;
  }
}

static void edge() { dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval(); }

static void garbage(std::mt19937& rng) {
  dut->funct3 = rng() & 7; dut->a = rng(); dut->b = rng();
  dut->eval();
}

// One operation the way the core uses it. Half the time start is held while waiting (as the core does), half the
// time it is a one-cycle pulse. After the first edge the inputs are garbage: the operands must have been latched.
static void run_op(int f3, uint32_t a, uint32_t b, uint32_t want, std::mt19937& rng) {
  const bool hold_start = rng() & 1;
  dut->start = 1; dut->funct3 = f3; dut->a = a; dut->b = b;
  dut->eval();
  expect("idle before start: done", dut->done, 0, f3, a, b);
  expect("idle before start: busy", dut->busy, 0, f3, a, b);

  const int iter = (f3 & 4) ? ITER_DIV : ITER_MUL;
  int edges = 0;
  while (edges < iter + 4) {
    edge(); edges++;
    dut->start = hold_start;
    if (dut->done) break;
    expect("busy while working", dut->busy, 1, f3, a, b);
    garbage(rng);
  }
  expect("edges from start to done", edges, iter + 1, f3, a, b);

  garbage(rng);                            // in the done cycle the result must not depend on the inputs
  expect("done", dut->done, 1, f3, a, b);
  expect("busy in the done cycle", dut->busy, 1, f3, a, b);
  expect("result", dut->result, want, f3, a, b);

  edge();                                  // the done cycle ends; a held start is ignored in it
  expect("idle after done: done", dut->done, 0, f3, a, b);
  expect("idle after done: busy", dut->busy, 0, f3, a, b);
}

// ---- Directed tests: expected values worked out by hand from the spec ----
struct D { const char* name; int f3; uint32_t a, b, want; };
static const D directed[] = {
  {"mul 6*7",                      0, 6, 7, 42},
  {"mul -1 * -1 (low word)",       0, 0xFFFFFFFF, 0xFFFFFFFF, 1},
  {"mul wraps",                    0, 0x10000, 0x10000, 0},
  {"mulh -1 * -1",                 1, 0xFFFFFFFF, 0xFFFFFFFF, 0},
  {"mulh INT_MIN * INT_MIN",       1, 0x80000000, 0x80000000, 0x40000000},
  {"mulh INT_MIN * 1",             1, 0x80000000, 1, 0xFFFFFFFF},
  {"mulh 0x7FFFFFFF * 2",          1, 0x7FFFFFFF, 2, 0},
  {"mulh 0x40000000 * 4",          1, 0x40000000, 4, 1},
  {"mulhsu -1 * 0xFFFFFFFF",       2, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF},
  {"mulhsu INT_MIN * 2",           2, 0x80000000, 2, 0xFFFFFFFF},
  {"mulhsu 1 * 0xFFFFFFFF",        2, 1, 0xFFFFFFFF, 0},
  {"mulhu max * max",              3, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFE},
  {"mulhu 0x80000000 * 2",         3, 0x80000000, 2, 1},
  {"div 20/3",                     4, 20, 3, 6},
  {"div -20/3",                    4, (uint32_t)-20, 3, (uint32_t)-6},
  {"div 20/-3",                    4, 20, (uint32_t)-3, (uint32_t)-6},
  {"div -20/-3",                   4, (uint32_t)-20, (uint32_t)-3, 6},
  {"div -1/2 rounds toward zero",  4, 0xFFFFFFFF, 2, 0},
  {"div 7/7",                      4, 7, 7, 1},
  {"div by zero",                  4, 5, 0, 0xFFFFFFFF},
  {"div negative by zero",         4, (uint32_t)-5, 0, 0xFFFFFFFF},
  {"div INT_MIN / -1 overflow",    4, 0x80000000, 0xFFFFFFFF, 0x80000000},
  {"divu max/2",                   5, 0xFFFFFFFF, 2, 0x7FFFFFFF},
  {"divu by zero",                 5, 5, 0, 0xFFFFFFFF},
  {"rem 20%3",                     6, 20, 3, 2},
  {"rem -20%3",                    6, (uint32_t)-20, 3, (uint32_t)-2},
  {"rem 20%-3",                    6, 20, (uint32_t)-3, 2},
  {"rem -20%-3",                   6, (uint32_t)-20, (uint32_t)-3, (uint32_t)-2},
  {"rem -1%2",                     6, 0xFFFFFFFF, 2, 0xFFFFFFFF},
  {"rem by zero",                  6, 5, 0, 5},
  {"rem negative by zero",         6, (uint32_t)-5, 0, (uint32_t)-5},
  {"rem INT_MIN % -1",             6, 0x80000000, 0xFFFFFFFF, 0},
  {"remu max%2",                   7, 0xFFFFFFFF, 2, 1},
  {"remu by zero",                 7, 5, 0, 5},
};

static uint32_t pick(std::mt19937& rng) {
  static const uint32_t special[] = {0, 1, 2, 3, 10, 0xFFFFFFFF, 0xFFFFFFFE, 0x80000000, 0x7FFFFFFF,
                                     0x80000001, 0x0000FFFF, 0xFFFF0000};
  switch (rng() % 4) {
    case 0:  return special[rng() % 12];
    case 1:  return rng() & 0xFF;                               // small
    case 2:  return (uint32_t)(int32_t)(int8_t)(rng() & 0xFF);  // small, either sign
    default: return rng();
  }
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vmuldiv;
  dut->clk = 0; dut->rst = 1; dut->start = 0; dut->funct3 = 0; dut->a = 0; dut->b = 0;
  edge(); edge();
  dut->rst = 0;
  dut->eval();
  std::mt19937 rng(1);   // fixed seed, so failures are reproducible

  for (const D& d : directed) run_op(d.f3, d.a, d.b, d.want, rng);

  // The unit stays idle while nothing is requested, whatever the operands do
  dut->start = 0;
  for (int i = 0; i < 6; i++) {
    garbage(rng);
    edge();
    expect("idle: done", dut->done, 0, -1, 0, 0);
    expect("idle: busy", dut->busy, 0, -1, 0, 0);
  }

  // Random operations back to back, with the edge cases forced often
  for (int n = 0; n < 120000; n++) {
    int f3 = rng() & 7;
    uint32_t a = pick(rng), b = pick(rng);
    switch (rng() % 8) {
      case 0: b = 0; break;
      case 1: a = 0x80000000; b = 0xFFFFFFFF; break;
      case 2: b = a; break;
      default: break;
    }
    run_op(f3, a, b, ref(f3, a, b), rng);
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
