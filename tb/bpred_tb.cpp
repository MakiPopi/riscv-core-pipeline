#include <cstdint>
#include <cstdio>
#include <deque>
#include <random>
#include <vector>
#include "Vbpred.h"
#include "verilated.h"

// Set by the Makefile for each tested configuration
#ifndef INDEX_BITS
#define INDEX_BITS 8
#endif
#ifndef HIST_BITS
#define HIST_BITS 0
#endif

static const uint32_t IMASK = (1u << INDEX_BITS) - 1;
static const uint32_t HMASK = HIST_BITS ? ((1u << HIST_BITS) - 1) : 0;

static Vbpred* dut;
static int errors = 0, checks = 0;

// ---- Independent model (same rules as scripts/bp_sim.py) ----
static uint8_t  ctr[1u << INDEX_BITS];
static uint32_t mhist;

static uint32_t idx(uint32_t pcw, uint32_t h) { return (pcw ^ h) & IMASK; }
static uint32_t shift_in(uint32_t h, int bit) { return ((h << 1) | (uint32_t)bit) & HMASK; }
static void train(uint32_t pcw, uint32_t h, int taken) {
  uint8_t& c = ctr[idx(pcw, h)];
  if (taken) { if (c < 3) c++; }
  else       { if (c > 0) c--; }
}

static void expect(const char* what, uint32_t got, uint32_t want) {
  checks++;
  if (got != want) {
    errors++;
    if (errors <= 20) printf("FAIL %s: got=%u expected=%u\n", what, got, want);
  }
}

static void idle() {
  dut->spec_en = 0; dut->spec_taken = 0;
  dut->fix_en = 0;  dut->fix_hist = 0;
  dut->upd_en = 0;  dut->upd_pc = 0;   dut->upd_hist = 0; dut->upd_taken = 0;
}
static void edge() { dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval(); }
static void lookup(uint32_t pcw) { dut->pc = pcw & 0x3FFFFFFFu; dut->eval(); }
static uint32_t look(uint32_t pcw) { lookup(pcw); return dut->taken; }

static void reset() {
  idle();
  dut->rst = 1; edge(); edge(); dut->rst = 0;
  for (auto& c : ctr) c = 1;
  mhist = 0;
  dut->eval();
}

// Train one counter; the history is not touched
static void update(uint32_t pcw, int taken) {
  idle();
  dut->upd_en = 1; dut->upd_pc = pcw; dut->upd_hist = 0; dut->upd_taken = taken;
  edge();
  idle();
}

// ---- Directed tests: expected values worked out by hand ----
static void directed() {
  reset();
  const uint32_t A = 0x12345;
  expect("after reset: not taken", look(A), 0);
  expect("after reset: history 0", dut->hist, 0);

  update(A, 1); expect("1 -> 2: taken", look(A), 1);
  update(A, 0); expect("2 -> 1: not taken", look(A), 0);
  update(A, 1); update(A, 1); update(A, 1);                 // 1 -> 2 -> 3 -> 3
  expect("saturated at 3: taken", look(A), 1);
  update(A, 0); expect("3 -> 2: still taken (hysteresis)", look(A), 1);
  update(A, 0); expect("2 -> 1: not taken", look(A), 0);
  update(A, 0); update(A, 0); update(A, 0);                 // 1 -> 0 -> 0 -> 0
  expect("saturated at 0: not taken", look(A), 0);
  update(A, 1); expect("0 -> 1: still not taken", look(A), 0);
  update(A, 1); expect("1 -> 2: taken", look(A), 1);         // the counter for A is now 2

  // Addresses that differ only above the index bits share a counter; another index bit does not
  expect("alias above the index bits", look(A ^ (1u << INDEX_BITS)), 1);
  expect("different index bit, own counter", look(A ^ 1u), 0);

  if (HIST_BITS > 0) {
    idle(); dut->spec_en = 1; dut->spec_taken = 1; edge(); idle();
    expect("history after one taken", dut->hist, 1);
    expect("history selects another counter", look(A), 0);   // index A^1: its counter is still 1

    idle(); dut->fix_en = 1; dut->fix_hist = 0; edge(); idle();
    expect("fix restores history 0", dut->hist, 0);
    expect("first counter visible again", look(A), 1);

    idle();                                                  // fix and spec together: fix wins
    dut->fix_en = 1; dut->fix_hist = 0;
    dut->spec_en = 1; dut->spec_taken = 1;
    edge(); idle();
    expect("fix wins over spec", dut->hist, 0);
  }
}

// ---- Random tests ----
static std::vector<uint32_t> make_pool(std::mt19937& rng) {
  std::vector<uint32_t> p;
  for (int i = 0; i < 12; i++) p.push_back(0x20000 + 3 * i);       // branches close together
  for (int i = 0; i < 12; i++) p.push_back(rng() & 0x3FFFFFFF);    // scattered branches
  return p;
}
static int outcome(std::mt19937& rng, size_t pi) {                 // each branch has its own bias
  static const int per_mille[3] = {50, 500, 950};
  return (int)(rng() % 1000) < per_mille[pi % 3];
}

// Predict, train and shift each branch at once: exactly what bp_sim.py does
static void test_in_order(std::mt19937& rng) {
  reset();
  auto pool = make_pool(rng);
  for (int n = 0; n < 100000; n++) {
    size_t pi = rng() % pool.size();
    uint32_t pcw = pool[pi];
    int t = outcome(rng, pi);
    lookup(pcw);
    expect("in-order: prediction", dut->taken, ctr[idx(pcw, mhist)] >= 2);
    expect("in-order: history", dut->hist, mhist);
    idle();
    dut->upd_en = 1; dut->upd_pc = pcw; dut->upd_hist = mhist; dut->upd_taken = t;
    dut->spec_en = 1; dut->spec_taken = t;
    edge();
    train(pcw, mhist, t);
    mhist = shift_in(mhist, t);
  }
}

// Up to three branches in flight, resolved in order. A misprediction restores the history
// and discards every younger branch (they were fetched on the wrong path).
struct Br { uint32_t pcw, h; int pred, actual; };

static void test_pipeline(std::mt19937& rng) {
  reset();
  auto pool = make_pool(rng);
  std::deque<Br> q;
  for (int n = 0; n < 200000; n++) {
    size_t pi = rng() % pool.size();
    uint32_t pcw = pool[pi];
    lookup(pcw);
    expect("pipeline: prediction", dut->taken, ctr[idx(pcw, mhist)] >= 2);
    expect("pipeline: history", dut->hist, mhist);
    int pred = dut->taken;
    uint32_t hseen = dut->hist;

    bool do_pred = q.size() < 3 && (rng() % 10) < 6;
    bool do_res  = !q.empty() && (rng() % 2);
    idle();
    Br x{};
    bool mis = false;
    if (do_res) {
      x = q.front(); q.pop_front();
      mis = (x.pred != x.actual);
      dut->upd_en = 1; dut->upd_pc = x.pcw; dut->upd_hist = x.h; dut->upd_taken = x.actual;
      if (mis) { dut->fix_en = 1; dut->fix_hist = shift_in(x.h, x.actual); }
    }
    if (do_pred) { dut->spec_en = 1; dut->spec_taken = pred; }
    edge();

    if (do_res) train(x.pcw, x.h, x.actual);
    if (do_res && mis) {                                   // restore; the new prediction is wrong-path too
      mhist = shift_in(x.h, x.actual);
      q.clear();
    } else if (do_pred) {
      mhist = shift_in(mhist, pred);
      q.push_back({pcw, hseen, pred, outcome(rng, pi)});
    }
  }
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vbpred;
  dut->clk = 0;
  std::mt19937 rng(1);   // fixed seed, so failures are reproducible

  directed();
  test_in_order(rng);
  test_pipeline(rng);

  dut->final();
  delete dut;

  if (errors) {
    printf("FAILED: %d of %d checks\n", errors, checks);
    return 1;
  }
  printf("PASSED: %d checks\n", checks);
  return 0;
}
