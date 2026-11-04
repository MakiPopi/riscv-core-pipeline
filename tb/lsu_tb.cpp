#include <cstdint>
#include <cstdio>
#include <random>
#include "Vlsu.h"
#include "verilated.h"

static Vlsu* dut;
static int errors = 0;
static int checks = 0;

static void expect(const char* what, int f3, int off, uint32_t word, uint32_t rs2,
                   uint32_t got, uint32_t want) {
  checks++;
  if (got != want) {
    errors++;
    if (errors <= 20)
      printf("FAIL %s: f3=%d off=%d word=0x%08x rs2=0x%08x got=0x%08x expected=0x%08x\n",
             what, f3, off, word, rs2, got, want);
  }
}

static void drive(int f3, int off, uint32_t word, uint32_t rs2) {
  dut->funct3 = f3;
  dut->addr_lo = off;
  dut->load_raw = word;
  dut->store_data = rs2;
  dut->eval();
}

// ---- Independent model: memory as four separate little-endian bytes ----
static void unpack(uint32_t w, uint8_t b[4]) {
  for (int i = 0; i < 4; i++) b[i] = (w >> (8 * i)) & 0xFF;
}
static uint32_t pack(const uint8_t b[4]) {
  uint32_t w = 0;
  for (int i = 0; i < 4; i++) w |= (uint32_t)b[i] << (8 * i);
  return w;
}

// Access size in bytes from funct3[1:0]; 0 means invalid (size code 3)
static int size_bytes(int f3) {
  switch (f3 & 3) { case 0: return 1; case 1: return 2; case 2: return 4; }
  return 0;
}
static bool ref_misaligned(int f3, int off) {
  int n = size_bytes(f3);
  return n > 1 && (off % n) != 0;
}
static uint32_t ref_be(int f3, int off) {
  int n = size_bytes(f3);
  return n == 0 ? 0 : (((1u << n) - 1) << off);
}
// Store n bytes of rs2 at byte offset 'off' of the word
static uint32_t ref_store(int f3, int off, uint32_t word, uint32_t rs2) {
  uint8_t b[4];
  unpack(word, b);
  int n = size_bytes(f3);
  for (int i = 0; i < n; i++) b[off + i] = (rs2 >> (8 * i)) & 0xFF;
  return pack(b);
}
// Load from byte offset 'off'; only called for aligned accesses
static uint32_t ref_load(int f3, int off, uint32_t word) {
  uint8_t b[4];
  unpack(word, b);
  switch (f3) {
    case 0: return (uint32_t)(int32_t)(int8_t)b[off];                      // lb
    case 4: return b[off];                                                 // lbu
    case 1: return (uint32_t)(int32_t)(int16_t)(b[off] | (b[off + 1] << 8)); // lh
    case 5: return b[off] | (b[off + 1] << 8);                             // lhu
    case 2: return pack(b);                                                // lw
  }
  return 0;
}
// What memory does with a (byte enable, data) write
static uint32_t hw_apply(uint32_t word, uint32_t be, uint32_t wdata) {
  for (int i = 0; i < 4; i++)
    if ((be >> i) & 1) {
      uint32_t mask = 0xFFu << (8 * i);
      word = (word & ~mask) | (wdata & mask);
    }
  return word;
}

// ---- Directed tests: expected values worked out by hand ----
static void d_load(const char* name, int f3, int off, uint32_t word, uint32_t want) {
  (void)name;
  drive(f3, off, word, 0);
  expect("load_data",  f3, off, word, 0, dut->load_data,  want);
  expect("misaligned", f3, off, word, 0, dut->misaligned, 0);
}
static void d_store(const char* name, int f3, int off, uint32_t word, uint32_t rs2,
                    uint32_t want_be, uint32_t want_word) {
  (void)name;
  drive(f3, off, word, rs2);
  expect("store_be", f3, off, word, rs2, dut->store_be, want_be);
  expect("store result", f3, off, word, rs2,
         hw_apply(word, dut->store_be, dut->store_wdata), want_word);
}
static void d_misaligned(int f3, int off, int want) {
  drive(f3, off, 0, 0);
  expect("misaligned", f3, off, 0, 0, dut->misaligned, want);
  if (want && f3 <= 2) expect("store_be (misaligned)", f3, off, 0, 0, dut->store_be, 0);
}

static void directed() {
  // Word 0xF1E2D3C4 is the bytes C4, D3, E2, F1 in memory order (little-endian)
  const uint32_t W = 0xF1E2D3C4;
  d_load("lb  off0",  0, 0, W, 0xFFFFFFC4);   // 0xC4, sign bit set -> extended with ones
  d_load("lbu off0",  4, 0, W, 0x000000C4);
  d_load("lb  off3",  0, 3, W, 0xFFFFFFF1);
  d_load("lbu off2",  4, 2, W, 0x000000E2);
  d_load("lh  off0",  1, 0, W, 0xFFFFD3C4);   // bytes C4,D3 -> 0xD3C4
  d_load("lhu off2",  5, 2, W, 0x0000F1E2);   // bytes E2,F1 -> 0xF1E2
  d_load("lw  off0",  2, 0, W, 0xF1E2D3C4);
  d_load("lb  positive", 0, 3, 0x7F6E5D4C, 0x0000007F);  // sign bit clear -> zeros

  // Memory word 0x11223344 is the bytes 44, 33, 22, 11
  const uint32_t M = 0x11223344;
  d_store("sb off1", 0, 1, M, 0x000000AB, 0x2, 0x1122AB44);
  d_store("sh off2", 1, 2, M, 0x0000BEEF, 0xC, 0xBEEF3344);
  d_store("sw off0", 2, 0, M, 0xCAFEBABE, 0xF, 0xCAFEBABE);
  d_store("sb ignores upper bits of rs2", 0, 3, M, 0xDDCCBBAA, 0x8, 0xAA223344);
  d_store("sh off0", 1, 0, M, 0xFFFF1234, 0x3, 0x11221234);

  // Alignment
  d_misaligned(1, 0, 0);  d_misaligned(1, 2, 0);   // lh/sh at even offsets: fine
  d_misaligned(1, 1, 1);  d_misaligned(1, 3, 1);   // at odd offsets: misaligned
  d_misaligned(2, 0, 0);                           // lw/sw at offset 0: fine
  d_misaligned(2, 1, 1);  d_misaligned(2, 2, 1);  d_misaligned(2, 3, 1);
  for (int off = 0; off < 4; off++) {              // bytes are never misaligned
    d_misaligned(0, off, 0);
    d_misaligned(4, off, 0);
  }
}

// ---- Random tests: every funct3 and offset, compared against the model ----
static void check_all(int f3, int off, uint32_t word, uint32_t rs2) {
  drive(f3, off, word, rs2);
  bool mis      = ref_misaligned(f3, off);
  bool is_store = f3 <= 2;
  bool is_load  = f3 <= 2 || f3 == 4 || f3 == 5;

  expect("misaligned", f3, off, word, rs2, dut->misaligned, mis);

  if ((f3 & 3) == 3)   // invalid size code: never write
    expect("store_be (invalid size)", f3, off, word, rs2, dut->store_be, 0);

  if (is_store) {
    if (mis) {
      expect("store_be (misaligned)", f3, off, word, rs2, dut->store_be, 0);
    } else {
      expect("store_be", f3, off, word, rs2, dut->store_be, ref_be(f3, off));
      expect("store result", f3, off, word, rs2,
             hw_apply(word, dut->store_be, dut->store_wdata),
             ref_store(f3, off, word, rs2));
    }
  }
  if (is_load && !mis)
    expect("load_data", f3, off, word, rs2, dut->load_data, ref_load(f3, off, word));
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vlsu;
  std::mt19937 rng(1);   // fixed seed, so failures are reproducible

  directed();

  for (int f3 = 0; f3 < 8; f3++)
    for (int off = 0; off < 4; off++)
      for (int i = 0; i < 20000; i++)
        check_all(f3, off, rng(), rng());

  dut->final();
  delete dut;

  if (errors) {
    printf("FAILED: %d of %d checks\n", errors, checks);
    return 1;
  }
  printf("PASSED: %d checks\n", checks);
  return 0;
}
