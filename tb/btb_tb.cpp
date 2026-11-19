#include <cstdint>
#include <cstdio>
#include <random>
#include "Vbtb.h"
#include "verilated.h"

#ifndef INDEX_BITS
#define INDEX_BITS 6
#endif

static const uint32_t ENTRIES = 1u << INDEX_BITS;
static const uint32_t WMASK   = 0x3FFFFFFFu;     // a word address has 30 bits

static Vbtb* dut;
static int errors = 0, checks = 0;

// ---- Independent model ----
struct Entry { bool valid; uint32_t tag, target; bool uncond; };
static Entry model[1u << INDEX_BITS];

static uint32_t idx_of(uint32_t pcw) { return pcw & (ENTRIES - 1); }
static uint32_t tag_of(uint32_t pcw) { return pcw >> INDEX_BITS; }

static void expect(const char* what, uint32_t pcw, uint32_t got, uint32_t want) {
  checks++;
  if (got != want) {
    errors++;
    if (errors <= 20) printf("FAIL %s: pc=0x%08x got=0x%x expected=0x%x\n", what, pcw, got, want);
  }
}

static void no_update() {
  dut->upd_en = 0; dut->upd_pc = 0; dut->upd_target = 0; dut->upd_uncond = 0;
}
static void edge() { dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval(); }

// Look up pc and compare all three outputs with the model
static void check(const char* what, uint32_t pcw) {
  dut->pc = pcw;
  dut->eval();
  const Entry& e = model[idx_of(pcw)];
  bool hit = e.valid && e.tag == tag_of(pcw);
  expect(what, pcw, dut->hit, hit);
  expect(what, pcw, dut->target, hit ? e.target : 0);
  expect(what, pcw, dut->uncond, hit && e.uncond);
}

static void update(uint32_t pcw, uint32_t target, bool uncond) {
  dut->upd_en = 1; dut->upd_pc = pcw; dut->upd_target = target; dut->upd_uncond = uncond;
  edge();
  no_update();
  model[idx_of(pcw)] = {true, tag_of(pcw), target, uncond};
}

static void reset() {
  no_update();
  dut->rst = 1; edge(); edge(); dut->rst = 0;
  for (auto& e : model) e = {false, 0, 0, false};
  dut->eval();
}

// ---- Directed tests: expected values worked out by hand ----
static void directed() {
  reset();
  const uint32_t A = 0x0012345;
  const uint32_t B = A ^ (1u << INDEX_BITS);   // same index as A, different tag
  const uint32_t C = A ^ 1u;                   // a different index
  const uint32_t D = A ^ (1u << 29);           // same index, differs only in the top tag bit
  const uint32_t T1 = 0x0200111, T2 = 0x0155AAA, T3 = 0x0000042, T4 = 0x3FFFFFF;

  check("after reset: miss", A);
  expect("after reset: target 0", A, dut->target, 0);

  // An update is not visible before the clock edge (no bypass)
  dut->pc = A; dut->upd_en = 1; dut->upd_pc = A; dut->upd_target = T1; dut->upd_uncond = 0;
  dut->eval();
  expect("no bypass: still a miss", A, dut->hit, 0);
  edge(); no_update();
  model[idx_of(A)] = {true, tag_of(A), T1, false};
  dut->pc = A; dut->eval();
  expect("hit after the edge", A, dut->hit, 1);
  expect("stored target", A, dut->target, T1);
  expect("conditional branch: uncond 0", A, dut->uncond, 0);

  check("other index: miss", C);
  expect("same index, other tag: miss", B, (dut->pc = B, dut->eval(), dut->hit), 0);

  update(B, T2, true);                         // replaces A
  dut->pc = B; dut->eval();
  expect("B hits", B, dut->hit, 1);
  expect("B target", B, dut->target, T2);
  expect("B is unconditional", B, dut->uncond, 1);
  dut->pc = A; dut->eval();
  expect("A was replaced", A, dut->hit, 0);

  update(C, T3, false);                        // another index: B must stay
  dut->pc = C; dut->eval();
  expect("C target", C, dut->target, T3);
  dut->pc = B; dut->eval();
  expect("B unaffected by C", B, dut->hit, 1);

  update(B, T4, false);                        // refresh with a new target and no uncond flag
  dut->pc = B; dut->eval();
  expect("refreshed target", B, dut->target, T4);
  expect("refreshed uncond", B, dut->uncond, 0);

  dut->pc = D; dut->eval();
  expect("top tag bit differs: miss (full tag)", D, dut->hit, 0);

  reset();
  dut->pc = B; dut->eval();
  expect("reset clears B", B, dut->hit, 0);
  dut->pc = C; dut->eval();
  expect("reset clears C", C, dut->hit, 0);
}

// ---- Random test: few indexes and few tags, so conflicts are constant ----
static uint32_t pick(std::mt19937& rng) {
  static const uint32_t tags[4] = {0, 1, 0x155, WMASK >> INDEX_BITS};
  uint32_t idx = (rng() % 4 == 0) ? (rng() % ENTRIES) : (rng() % 3 % ENTRIES);
  return ((tags[rng() % 4] << INDEX_BITS) | idx) & WMASK;
}

static void test_random(std::mt19937& rng) {
  reset();
  for (int n = 0; n < 200000; n++) {
    if (n == 100000) reset();                 // a reset in the middle of use
    uint32_t pcw = pick(rng);
    check("random lookup", pcw);
    if (rng() % 3 == 0) {
      uint32_t upc = (rng() % 2) ? pcw : pick(rng);
      // The update happens at the next edge, with the lookup still on the input
      dut->upd_en = 1; dut->upd_pc = upc;
      dut->upd_target = rng() & WMASK; dut->upd_uncond = rng() & 1;
      uint32_t t = dut->upd_target; bool u = dut->upd_uncond;
      check("random lookup during an update (no bypass)", pcw);
      edge(); no_update();
      model[idx_of(upc)] = {true, tag_of(upc), t, u};
    }
  }
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vbtb;
  dut->clk = 0;
  std::mt19937 rng(1);   // fixed seed, so failures are reproducible

  directed();
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
