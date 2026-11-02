#include <cstdint>
#include <cstdio>
#include <random>
#include "Vregfile.h"
#include "verilated.h"

static Vregfile* dut;
static int errors = 0;
static int checks = 0;

// Software model of the register file: what the hardware SHOULD contain.
static uint32_t model[32];

// Set all inputs and let the combinational logic settle (no clock edge).
static void drive(int we, int waddr, uint32_t wdata, int ra1, int ra2) {
  dut->we = we;
  dut->waddr = waddr;
  dut->wdata = wdata;
  dut->raddr1 = ra1;
  dut->raddr2 = ra2;
  dut->eval();
}

// One full clock pulse: rising edge (the write happens here), then back low.
static void clock_edge() {
  dut->clk = 1;
  dut->eval();
  dut->clk = 0;
  dut->eval();
}

static void check_val(const char* what, uint32_t got, uint32_t expected) {
  checks++;
  if (got != expected) {
    printf("FAIL %s: got=0x%08x expected=0x%08x\n", what, got, expected);
    errors++;
  }
}

// What a read of 'addr' must return, given a write that may be happening now.
static uint32_t expect_read(int we, int waddr, uint32_t wdata, int addr) {
  if (addr == 0) return 0;
  if (we && waddr == addr) return wdata;   // same-cycle bypass
  return model[addr];
}

// Write one register through the hardware, and mirror it in the model.
static void write_reg(int addr, uint32_t data) {
  drive(1, addr, data, 0, 0);
  clock_edge();
  if (addr != 0) model[addr] = data;
  drive(0, 0, 0, 0, 0);
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vregfile;
  dut->clk = 0;

  // ---- Directed tests: expected values written by hand ----

  // Give every register a known, distinct value: x_i = 0xA5A50000 + i
  for (int i = 1; i < 32; i++) write_reg(i, 0xA5A50000u + i);

  // Both read ports work and are independent (different address on each)
  for (int i = 1; i < 32; i++) {
    drive(0, 0, 0, i, 32 - i);
    check_val("port1 readback", dut->rdata1, 0xA5A50000u + i);
    check_val("port2 readback", dut->rdata2, 0xA5A50000u + (32 - i));
  }

  // x0 ignores writes and always reads zero
  write_reg(0, 0xFFFFFFFF);
  drive(0, 0, 0, 0, 0);
  check_val("x0 port1", dut->rdata1, 0);
  check_val("x0 port2", dut->rdata2, 0);

  // we=0 must not write, even if waddr and wdata are set
  drive(0, 5, 0x00BADBAD, 5, 5);
  check_val("no-write before edge", dut->rdata1, 0xA5A50005u);
  clock_edge();
  drive(0, 0, 0, 5, 5);
  check_val("no-write after edge", dut->rdata1, 0xA5A50005u);

  // Same-cycle bypass: reading the address being written returns the NEW value
  // before the clock edge. Reading a different address still returns old data.
  drive(1, 9, 0x99999999, 10, 9);
  check_val("bypass other addr", dut->rdata1, 0xA5A5000Au);
  check_val("bypass same addr",  dut->rdata2, 0x99999999u);
  clock_edge();
  model[9] = 0x99999999;
  drive(0, 0, 0, 9, 9);
  check_val("write landed", dut->rdata1, 0x99999999u);

  // Bypass must never leak into x0
  drive(1, 0, 0x12345678, 0, 0);
  check_val("bypass x0 port1", dut->rdata1, 0);
  check_val("bypass x0 port2", dut->rdata2, 0);
  clock_edge();

  // ---- Random tests: compared against the software model ----
  std::mt19937 rng(1);   // fixed seed, so failures are reproducible
  for (int i = 0; i < 100000; i++) {
    int we = rng() & 1;
    int waddr = rng() % 32;
    uint32_t wdata = rng();
    // One time in three, read the address being written, to hit the bypass
    int ra1 = (rng() % 3 == 0) ? waddr : rng() % 32;
    int ra2 = (rng() % 3 == 0) ? waddr : rng() % 32;

    // Before the edge: includes bypass
    drive(we, waddr, wdata, ra1, ra2);
    check_val("random pre-edge port1", dut->rdata1, expect_read(we, waddr, wdata, ra1));
    check_val("random pre-edge port2", dut->rdata2, expect_read(we, waddr, wdata, ra2));

    // Clock the write in, update the model the same way
    clock_edge();
    if (we && waddr != 0) model[waddr] = wdata;

    // After the edge, with we=0: proves the write really got stored
    drive(0, 0, 0, ra1, ra2);
    check_val("random post-edge port1", dut->rdata1, expect_read(0, 0, 0, ra1));
    check_val("random post-edge port2", dut->rdata2, expect_read(0, 0, 0, ra2));
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
