#include <cstdint>
#include <cstdio>
#include <random>
#include <vector>
#include "Vras.h"
#include "verilated.h"

#ifndef DEPTH_LOG2
#define DEPTH_LOG2 3
#endif

static const int DEPTH = 1 << DEPTH_LOG2;
static const uint32_t WMASK = 0x3FFFFFFFu;     // a word address has 30 bits

static Vras* dut;
static int errors = 0, checks = 0;

// ---- Independent model of the two copies ----
static uint32_t s_ent[DEPTH], c_ent[DEPTH];
static int s_ptr, c_ptr;

static int inc(int p) { return (p + 1) % DEPTH; }
static int dec(int p) { return (p + DEPTH - 1) % DEPTH; }

enum { NONE = 0, PUSH = 1, POP = 2 };
struct Ops { int spec; uint32_t spec_val; int com; uint32_t com_val; bool restore; };
static Ops mk(int spec, uint32_t sv, int com, uint32_t cv, bool restore) {
  Ops o; o.spec = spec; o.spec_val = sv; o.com = com; o.com_val = cv; o.restore = restore;
  return o;
}

static void drive(const Ops& o) {
  dut->push = (o.spec == PUSH); dut->push_val = o.spec_val; dut->pop = (o.spec == POP);
  dut->c_push = (o.com == PUSH); dut->c_push_val = o.com_val; dut->c_pop = (o.com == POP);
  dut->restore = o.restore;
}
static void edge() { dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval(); }

static void model_step(const Ops& o) {
  uint32_t cn[DEPTH];
  for (int i = 0; i < DEPTH; i++) cn[i] = c_ent[i];
  int pn = c_ptr;
  if (o.com == PUSH)     { pn = inc(c_ptr); cn[pn] = o.com_val; }
  else if (o.com == POP) { pn = dec(c_ptr); }
  if (o.restore) {
    for (int i = 0; i < DEPTH; i++) s_ent[i] = cn[i];
    s_ptr = pn;
  } else if (o.spec == PUSH) {
    s_ptr = inc(s_ptr); s_ent[s_ptr] = o.spec_val;
  } else if (o.spec == POP) {
    s_ptr = dec(s_ptr);
  }
  for (int i = 0; i < DEPTH; i++) c_ent[i] = cn[i];
  c_ptr = pn;
}

static void expect_top(const char* what, uint32_t want) {
  dut->eval();
  checks++;
  if (dut->top_addr != want) {
    errors++;
    if (errors <= 20) printf("FAIL %s: top=0x%x expected=0x%x\n", what, dut->top_addr, want);
  }
}

// One clock cycle on the DUT and the model; the top must always agree with the model
static void step(const Ops& o) {
  drive(o); edge(); model_step(o);
  drive(mk(NONE, 0, NONE, 0, false));
  expect_top("model comparison", s_ent[s_ptr]);
}

static void reset() {
  drive(mk(NONE, 0, NONE, 0, false));
  dut->rst = 1; edge(); edge(); dut->rst = 0;
  for (int i = 0; i < DEPTH; i++) s_ent[i] = c_ent[i] = 0;
  s_ptr = c_ptr = 0;
  dut->eval();
}

// ---- Directed tests: expected values worked out by hand ----
static void directed() {
  reset();
  expect_top("after reset", 0);

  for (int v = 1; v <= DEPTH; v++) { step(mk(PUSH, v, NONE, 0, false)); expect_top("push", v); }
  for (int v = DEPTH - 1; v >= 1; v--) { step(mk(POP, 0, NONE, 0, false)); expect_top("LIFO order", v); }

  // Wrap-around: after DEPTH+1 pushes the oldest value (1) is lost; the newest DEPTH values remain
  reset();
  for (int v = 1; v <= DEPTH + 1; v++) step(mk(PUSH, v, NONE, 0, false));
  expect_top("newest entry", DEPTH + 1);
  for (int k = 1; k <= DEPTH - 1; k++) step(mk(POP, 0, NONE, 0, false));
  expect_top("oldest surviving entry", 2);

  // A call is fetched (speculative push) and executes (committed push). Then wrong-path pushes and pops
  // spoil the speculative copy. A redirect must restore the committed state.
  reset();
  step(mk(PUSH, 10, NONE, 0, false));
  step(mk(NONE, 0, PUSH, 10, false));
  expect_top("both copies hold 10", 10);
  step(mk(PUSH, 20, NONE, 0, false));
  step(mk(POP, 0, NONE, 0, false));
  step(mk(POP, 0, NONE, 0, false));
  step(mk(NONE, 0, NONE, 0, true));
  expect_top("restore undoes wrong-path ops", 10);

  // The redirecting instruction is itself a call (EX pushes 30 in the same cycle as the restore)
  step(mk(NONE, 0, PUSH, 30, true));
  expect_top("restore includes this cycle's commit", 30);
  step(mk(POP, 0, NONE, 0, false));
  expect_top("entry below", 10);

  // Restore wins over a speculative push in the same cycle
  reset();
  step(mk(NONE, 0, PUSH, 5, false));
  expect_top("spec copy unaffected by commits", 0);
  step(mk(PUSH, 99, NONE, 0, true));
  expect_top("restore beats push", 5);
  step(mk(POP, 0, NONE, 0, false));
  expect_top("below", 0);

  // The redirecting instruction is a return (EX pops in the same cycle as the restore)
  reset();
  step(mk(NONE, 0, PUSH, 7, false));
  step(mk(NONE, 0, PUSH, 8, false));
  step(mk(NONE, 0, POP, 0, true));
  expect_top("restore includes this cycle's pop", 7);
}

// ---- Semantic test: the stack must predict like the software's real call stack ----
static void test_semantic(std::mt19937& rng) {
  reset();
  std::vector<uint32_t> truth;                   // the program's real return addresses
  for (int n = 0; n < 200000; n++) {
    int r = rng() % 10;
    if (r < 4 && (int)truth.size() < DEPTH) {    // a correctly predicted call: IF and EX both push
      uint32_t v = rng() & WMASK;
      truth.push_back(v);
      step(mk(PUSH, v, PUSH, v, false));
    } else if (r < 8 && !truth.empty()) {        // a return: the top must be its return address
      expect_top("return prediction", truth.back());
      step(mk(POP, 0, POP, 0, false));
      truth.pop_back();
    } else {                                     // wrong-path noise, then a redirect
      int k = 1 + rng() % 5;
      for (int j = 0; j < k; j++) step(mk(rng() % 2 ? PUSH : POP, rng() & WMASK, NONE, 0, false));
      step(mk(NONE, 0, NONE, 0, true));
      if (!truth.empty()) expect_top("top after the redirect", truth.back());
    }
  }
}

// ---- Random test: any mix of operations, compared with the model every cycle ----
static void test_random(std::mt19937& rng) {
  reset();
  for (int n = 0; n < 300000; n++)
    step(mk(rng() % 3, rng() & WMASK, rng() % 3, rng() & WMASK, rng() % 6 == 0));
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vras;
  dut->clk = 0;
  std::mt19937 rng(1);   // fixed seed, so failures are reproducible

  directed();
  test_semantic(rng);
  test_random(rng);

  dut->final();
  delete dut;

  if (errors) {
    printf("FAILED: %d of %d checks\n", errors, checks);
    return 1;
  }
  printf("PASSED: %d checks\n", checks);
  return 0;
}
