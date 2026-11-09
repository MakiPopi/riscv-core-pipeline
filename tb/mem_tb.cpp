#include <cstdint>
#include <cstdio>
#include <random>
#include "Vmem.h"
#include "verilated.h"

static const uint32_t WORDS  = 16384;              // must match the module default
static const uint32_t BASE_W = 0x80000000u >> 2;   // word address of the first word

static Vmem* dut;
static int errors = 0;
static int checks = 0;
static uint32_t model[WORDS];                      // what memory should contain

static void expect(const char* what, uint32_t got, uint32_t want) {
  checks++;
  if (got != want) {
    errors++;
    if (errors <= 20) printf("FAIL %s: got=0x%08x expected=0x%08x\n", what, got, want);
  }
}

static void drive(uint32_t ia, uint32_t da, uint32_t be, uint32_t wdata) {
  dut->iaddr = ia;
  dut->daddr = da;
  dut->dbe = be;
  dut->dwdata = wdata;
  dut->eval();
}

static void clock_edge() {
  dut->clk = 1;
  dut->eval();
  dut->clk = 0;
  dut->eval();
}

static uint32_t wa(uint32_t idx) { return BASE_W + idx; }   // word index -> word address

static uint32_t model_read(uint32_t a) {
  uint32_t off = a - BASE_W;                        // wraps for addresses below the base
  return off < WORDS ? model[off] : 0;
}

static void model_write(uint32_t a, uint32_t be, uint32_t data) {
  uint32_t off = a - BASE_W;
  if (off >= WORDS) return;                         // outside memory: ignored
  for (int i = 0; i < 4; i++)
    if ((be >> i) & 1) {
      uint32_t mask = 0xFFu << (8 * i);
      model[off] = (model[off] & ~mask) | (data & mask);
    }
}

int main() {
  // Hex file: words 0 and 1, then "@A" jumps to word address 0xA (= 10)
  FILE* f = fopen("build/mem/test.hex", "w");
  if (!f) { printf("cannot write build/mem/test.hex (run from the repo root)\n"); return 1; }
  fprintf(f, "11111111\n22222222\n@A\nDEADBEEF\n");
  fclose(f);
  model[0] = 0x11111111;
  model[1] = 0x22222222;
  model[10] = 0xDEADBEEF;

  const char* args[] = {"mem_tb", "+hex=build/mem/test.hex"};
  Verilated::commandArgs(2, args);
  dut = new Vmem;
  dut->clk = 0;

  // ---- 1. Contents loaded from the hex file; the two ports are independent ----
  drive(wa(0), wa(0), 0, 0);
  expect("hex word 0 (inst port)", dut->irdata, 0x11111111);
  expect("hex word 0 (data port)", dut->drdata, 0x11111111);
  drive(wa(1), wa(10), 0, 0);
  expect("hex word 1 (inst port)",  dut->irdata, 0x22222222);
  expect("hex word 10 (data port)", dut->drdata, 0xDEADBEEF);
  drive(wa(5), wa(11), 0, 0);                       // never written: zero
  expect("unwritten word 5",  dut->irdata, 0);
  expect("unwritten word 11", dut->drdata, 0);

  // ---- 2. Byte-enable writes. A write lands on the clock edge, not before. ----
  drive(wa(100), wa(100), 0xF, 0xAABBCCDD);
  expect("write not visible before the edge", dut->drdata, 0);
  clock_edge();
  drive(wa(100), wa(100), 0, 0);
  expect("full word written (data port)", dut->drdata, 0xAABBCCDD);
  expect("full word written (inst port)", dut->irdata, 0xAABBCCDD);

  drive(wa(100), wa(100), 0x4, 0x00EE0000);         // only byte lane 2
  clock_edge();
  drive(wa(100), wa(100), 0, 0);
  expect("one lane written", dut->drdata, 0xAAEECCDD);

  drive(wa(100), wa(100), 0x0, 0x12345678);         // no lanes: nothing changes
  clock_edge();
  drive(wa(100), wa(100), 0, 0);
  expect("be=0 writes nothing", dut->drdata, 0xAAEECCDD);

  drive(wa(100), wa(100), 0x9, 0x11FFFF22);         // lanes 0 and 3 only
  clock_edge();
  drive(wa(100), wa(100), 0, 0);
  expect("lanes 0 and 3", dut->drdata, 0x11EECC22);
  model[100] = 0x11EECC22;                          // keep the model in sync

  // ---- 3. Out-of-range accesses ----
  const uint32_t below = BASE_W - 1;                // last word before memory
  drive(wa(WORDS), below, 0, 0);
  expect("read past the end",  dut->irdata, 0);
  expect("read below the base", dut->drdata, 0);
  drive(0, 0x3FFFFFFF, 0, 0);
  expect("read at address 0",              dut->irdata, 0);
  expect("read at top of address space",   dut->drdata, 0);

  // Writes outside memory must be ignored and must NOT wrap onto a valid word
  drive(wa(0), wa(WORDS), 0xF, 0xDEAD0001);
  clock_edge();
  drive(wa(0), below, 0xF, 0xDEAD0002);
  clock_edge();
  drive(wa(0), wa(WORDS - 1), 0, 0);
  expect("write past end did not wrap to word 0",   dut->irdata, 0x11111111);
  expect("write below base did not alias last word", dut->drdata, 0);

  // ---- 4. Random cycles against the C++ model ----
  std::mt19937 rng(1);   // fixed seed, so failures are reproducible
  auto pick = [&]() -> uint32_t {
    if (rng() % 4 == 0) return BASE_W + rng() % 16;                // hot spot: many collisions
    return BASE_W - 32 + rng() % (WORDS + 64);                     // all of memory, 32 words beyond each end
  };
  for (int i = 0; i < 200000; i++) {
    uint32_t ia = pick(), da = pick(), data = rng();
    uint32_t be = (rng() % 4 == 0) ? 0 : (rng() & 0xF);
    drive(ia, da, be, data);
    expect("random inst read", dut->irdata, model_read(ia));
    expect("random data read", dut->drdata, model_read(da));
    clock_edge();
    model_write(da, be, data);
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
