#include <cstdint>
#include <cstdio>
#include <random>
#include "Vdecoder.h"
#include "verilated.h"

// Must match rtl/alu_pkg.sv and rtl/decode_pkg.sv
enum AluOp { ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND };
enum ASel  { A_RS1, A_PC, A_ZERO };
enum BSel  { B_RS2, B_IMM };
enum WbSel { WB_ALU, WB_MEM, WB_PC4 };
enum Fmt   { FMT_R, FMT_I, FMT_S, FMT_B, FMT_U, FMT_J };

static Vdecoder* dut;
static int errors = 0;
static int checks = 0;
static const char* cur_name = "";

static void drive(uint32_t inst) {
  dut->inst = inst;
  dut->eval();
}

static void expect(const char* what, uint32_t inst, uint32_t got, uint32_t want) {
  checks++;
  if (got != want) {
    errors++;
    if (errors <= 20)
      printf("FAIL [%s] %s: inst=0x%08x got=0x%x expected=0x%x\n",
             cur_name, what, inst, got, want);
  }
}

// ---------------------------------------------------------------------------
// Instruction encoders, written from the format diagrams in the spec.
// They build an instruction from its fields; the decoder must undo this.
// ---------------------------------------------------------------------------
static uint32_t enc_r(uint32_t f7, uint32_t rs2, uint32_t rs1, uint32_t f3,
                      uint32_t rd, uint32_t opc) {
  return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | opc;
}
static uint32_t enc_i(int32_t imm, uint32_t rs1, uint32_t f3, uint32_t rd, uint32_t opc) {
  uint32_t u = (uint32_t)imm;
  return ((u & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | opc;
}
static uint32_t enc_s(int32_t imm, uint32_t rs2, uint32_t rs1, uint32_t f3, uint32_t opc) {
  uint32_t u = (uint32_t)imm;
  return (((u >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) |
         ((u & 0x1F) << 7) | opc;
}
static uint32_t enc_b(int32_t imm, uint32_t rs2, uint32_t rs1, uint32_t f3, uint32_t opc) {
  uint32_t u = (uint32_t)imm;
  return (((u >> 12) & 1) << 31) | (((u >> 5) & 0x3F) << 25) | (rs2 << 20) |
         (rs1 << 15) | (f3 << 12) | (((u >> 1) & 0xF) << 8) | (((u >> 11) & 1) << 7) | opc;
}
static uint32_t enc_u(uint32_t imm20, uint32_t rd, uint32_t opc) {
  return (imm20 << 12) | (rd << 7) | opc;
}
static uint32_t enc_j(int32_t imm, uint32_t rd, uint32_t opc) {
  uint32_t u = (uint32_t)imm;
  return (((u >> 20) & 1) << 31) | (((u >> 1) & 0x3FF) << 21) | (((u >> 11) & 1) << 20) |
         (((u >> 12) & 0xFF) << 12) | (rd << 7) | opc;
}

// ---------------------------------------------------------------------------
// The instruction table: the "spec" the decoder is checked against.
// funct3/funct7 = -1 means that field is not part of the decode.
// dp = the alu_op / a_sel / b_sel signals are meaningful for this instruction.
// ---------------------------------------------------------------------------
struct Entry {
  const char* name;
  Fmt fmt;
  int opcode, funct3, funct7;
  AluOp alu_op; ASel a_sel; BSel b_sel;
  int reg_write; WbSel wb_sel;
  int mem_read, mem_write, is_branch, is_jal, is_jalr, uses_rs1, uses_rs2;
  bool dp;
};

static const Entry table[] = {
  // name     fmt    opcode f3 f7    alu   a_sel   b_sel  rw wb      mr mw br jal jalr rs1 rs2 dp
  {"lui",   FMT_U, 0x37, -1, -1,   ADD,  A_ZERO, B_IMM, 1, WB_ALU, 0,0,0,0,0, 0,0, true},
  {"auipc", FMT_U, 0x17, -1, -1,   ADD,  A_PC,   B_IMM, 1, WB_ALU, 0,0,0,0,0, 0,0, true},
  {"jal",   FMT_J, 0x6F, -1, -1,   ADD,  A_PC,   B_IMM, 1, WB_PC4, 0,0,0,1,0, 0,0, true},
  {"jalr",  FMT_I, 0x67,  0, -1,   ADD,  A_RS1,  B_IMM, 1, WB_PC4, 0,0,0,0,1, 1,0, true},

  {"beq",   FMT_B, 0x63,  0, -1,   ADD,  A_PC,   B_IMM, 0, WB_ALU, 0,0,1,0,0, 1,1, true},
  {"bne",   FMT_B, 0x63,  1, -1,   ADD,  A_PC,   B_IMM, 0, WB_ALU, 0,0,1,0,0, 1,1, true},
  {"blt",   FMT_B, 0x63,  4, -1,   ADD,  A_PC,   B_IMM, 0, WB_ALU, 0,0,1,0,0, 1,1, true},
  {"bge",   FMT_B, 0x63,  5, -1,   ADD,  A_PC,   B_IMM, 0, WB_ALU, 0,0,1,0,0, 1,1, true},
  {"bltu",  FMT_B, 0x63,  6, -1,   ADD,  A_PC,   B_IMM, 0, WB_ALU, 0,0,1,0,0, 1,1, true},
  {"bgeu",  FMT_B, 0x63,  7, -1,   ADD,  A_PC,   B_IMM, 0, WB_ALU, 0,0,1,0,0, 1,1, true},

  {"lb",    FMT_I, 0x03,  0, -1,   ADD,  A_RS1,  B_IMM, 1, WB_MEM, 1,0,0,0,0, 1,0, true},
  {"lh",    FMT_I, 0x03,  1, -1,   ADD,  A_RS1,  B_IMM, 1, WB_MEM, 1,0,0,0,0, 1,0, true},
  {"lw",    FMT_I, 0x03,  2, -1,   ADD,  A_RS1,  B_IMM, 1, WB_MEM, 1,0,0,0,0, 1,0, true},
  {"lbu",   FMT_I, 0x03,  4, -1,   ADD,  A_RS1,  B_IMM, 1, WB_MEM, 1,0,0,0,0, 1,0, true},
  {"lhu",   FMT_I, 0x03,  5, -1,   ADD,  A_RS1,  B_IMM, 1, WB_MEM, 1,0,0,0,0, 1,0, true},

  {"sb",    FMT_S, 0x23,  0, -1,   ADD,  A_RS1,  B_IMM, 0, WB_ALU, 0,1,0,0,0, 1,1, true},
  {"sh",    FMT_S, 0x23,  1, -1,   ADD,  A_RS1,  B_IMM, 0, WB_ALU, 0,1,0,0,0, 1,1, true},
  {"sw",    FMT_S, 0x23,  2, -1,   ADD,  A_RS1,  B_IMM, 0, WB_ALU, 0,1,0,0,0, 1,1, true},

  {"addi",  FMT_I, 0x13,  0, -1,   ADD,  A_RS1,  B_IMM, 1, WB_ALU, 0,0,0,0,0, 1,0, true},
  {"slti",  FMT_I, 0x13,  2, -1,   SLT,  A_RS1,  B_IMM, 1, WB_ALU, 0,0,0,0,0, 1,0, true},
  {"sltiu", FMT_I, 0x13,  3, -1,   SLTU, A_RS1,  B_IMM, 1, WB_ALU, 0,0,0,0,0, 1,0, true},
  {"xori",  FMT_I, 0x13,  4, -1,   XOR,  A_RS1,  B_IMM, 1, WB_ALU, 0,0,0,0,0, 1,0, true},
  {"ori",   FMT_I, 0x13,  6, -1,   OR,   A_RS1,  B_IMM, 1, WB_ALU, 0,0,0,0,0, 1,0, true},
  {"andi",  FMT_I, 0x13,  7, -1,   AND,  A_RS1,  B_IMM, 1, WB_ALU, 0,0,0,0,0, 1,0, true},
  {"slli",  FMT_I, 0x13,  1, 0x00, SLL,  A_RS1,  B_IMM, 1, WB_ALU, 0,0,0,0,0, 1,0, true},
  {"srli",  FMT_I, 0x13,  5, 0x00, SRL,  A_RS1,  B_IMM, 1, WB_ALU, 0,0,0,0,0, 1,0, true},
  {"srai",  FMT_I, 0x13,  5, 0x20, SRA,  A_RS1,  B_IMM, 1, WB_ALU, 0,0,0,0,0, 1,0, true},

  {"add",   FMT_R, 0x33,  0, 0x00, ADD,  A_RS1,  B_RS2, 1, WB_ALU, 0,0,0,0,0, 1,1, true},
  {"sub",   FMT_R, 0x33,  0, 0x20, SUB,  A_RS1,  B_RS2, 1, WB_ALU, 0,0,0,0,0, 1,1, true},
  {"sll",   FMT_R, 0x33,  1, 0x00, SLL,  A_RS1,  B_RS2, 1, WB_ALU, 0,0,0,0,0, 1,1, true},
  {"slt",   FMT_R, 0x33,  2, 0x00, SLT,  A_RS1,  B_RS2, 1, WB_ALU, 0,0,0,0,0, 1,1, true},
  {"sltu",  FMT_R, 0x33,  3, 0x00, SLTU, A_RS1,  B_RS2, 1, WB_ALU, 0,0,0,0,0, 1,1, true},
  {"xor",   FMT_R, 0x33,  4, 0x00, XOR,  A_RS1,  B_RS2, 1, WB_ALU, 0,0,0,0,0, 1,1, true},
  {"srl",   FMT_R, 0x33,  5, 0x00, SRL,  A_RS1,  B_RS2, 1, WB_ALU, 0,0,0,0,0, 1,1, true},
  {"sra",   FMT_R, 0x33,  5, 0x20, SRA,  A_RS1,  B_RS2, 1, WB_ALU, 0,0,0,0,0, 1,1, true},
  {"or",    FMT_R, 0x33,  6, 0x00, OR,   A_RS1,  B_RS2, 1, WB_ALU, 0,0,0,0,0, 1,1, true},
  {"and",   FMT_R, 0x33,  7, 0x00, AND,  A_RS1,  B_RS2, 1, WB_ALU, 0,0,0,0,0, 1,1, true},

  // fence is a no-op: valid, but touches nothing
  {"fence", FMT_I, 0x0F,  0, -1,   ADD,  A_RS1,  B_IMM, 0, WB_ALU, 0,0,0,0,0, 0,0, false},
};

// Which table entry (if any) does this instruction word match?
static const Entry* lookup(uint32_t inst) {
  int opc = inst & 0x7F;
  int f3  = (inst >> 12) & 7;
  int f7  = (inst >> 25) & 0x7F;
  for (const Entry& e : table) {
    if (e.opcode == opc && (e.funct3 < 0 || e.funct3 == f3) &&
        (e.funct7 < 0 || e.funct7 == f7))
      return &e;
  }
  return nullptr;
}

// Check every control signal of a legal instruction against its table entry
static void check_controls(const Entry& e, uint32_t inst) {
  cur_name = e.name;
  expect("illegal",   inst, dut->illegal,   0);
  expect("reg_write", inst, dut->reg_write, e.reg_write);
  expect("mem_read",  inst, dut->mem_read,  e.mem_read);
  expect("mem_write", inst, dut->mem_write, e.mem_write);
  expect("is_branch", inst, dut->is_branch, e.is_branch);
  expect("is_jal",    inst, dut->is_jal,    e.is_jal);
  expect("is_jalr",   inst, dut->is_jalr,   e.is_jalr);
  expect("uses_rs1",  inst, dut->uses_rs1,  e.uses_rs1);
  expect("uses_rs2",  inst, dut->uses_rs2,  e.uses_rs2);
  if (e.dp) {
    expect("alu_op", inst, dut->alu_op, e.alu_op);
    expect("a_sel",  inst, dut->a_sel,  e.a_sel);
    expect("b_sel",  inst, dut->b_sel,  e.b_sel);
  }
  if (e.reg_write) expect("wb_sel", inst, dut->wb_sel, e.wb_sel);
  if (e.funct3 >= 0) expect("funct3", inst, dut->funct3, e.funct3);
}

// ---------------------------------------------------------------------------
// Test 1: directed. Real encodings, expected values worked out by hand.
// ---------------------------------------------------------------------------
struct Known { const char* name; uint32_t inst; uint32_t imm; };

static void test_directed() {
  static const Known known[] = {
    {"addi x1,x0,5",   0x00500093, 0x00000005},
    {"addi x1,x1,-1",  0xFFF08093, 0xFFFFFFFF},
    {"lw x5,8(x2)",    0x00812283, 0x00000008},
    {"sw x5,8(x2)",    0x00512423, 0x00000008},
    {"beq x1,x2,8",    0x00208463, 0x00000008},
    {"beq x1,x2,-4",   0xFE208EE3, 0xFFFFFFFC},
    {"lui x5,0x12345", 0x123452B7, 0x12345000},
    {"auipc x5,1",     0x00001297, 0x00001000},
    {"jal x1,8",       0x008000EF, 0x00000008},
    {"jal x1,-4",      0xFFDFF0EF, 0xFFFFFFFC},
    {"srai x5,x6,3",   0x40335293, 0x00000403},
  };
  for (const Known& k : known) {
    cur_name = k.name;
    drive(k.inst);
    expect("imm",     k.inst, dut->imm,     k.imm);
    expect("illegal", k.inst, dut->illegal, 0);
  }

  // add x3,x1,x2 and sub x3,x1,x2 differ only in instruction bit 30
  cur_name = "add x3,x1,x2";
  drive(0x002081B3);
  expect("rd", 0x002081B3, dut->rd, 3);
  expect("rs1", 0x002081B3, dut->rs1, 1);
  expect("rs2", 0x002081B3, dut->rs2, 2);
  expect("alu_op", 0x002081B3, dut->alu_op, ADD);
  cur_name = "sub x3,x1,x2";
  drive(0x402081B3);
  expect("alu_op", 0x402081B3, dut->alu_op, SUB);

  // addi must never become a subtraction, even with bit 30 set in its immediate
  cur_name = "addi x1,x1,-1";
  drive(0xFFF08093);
  expect("alu_op", 0xFFF08093, dut->alu_op, ADD);

  cur_name = "srai x5,x6,3";
  drive(0x40335293);
  expect("alu_op", 0x40335293, dut->alu_op, SRA);

  // jalr x0,0(x1)  (the "ret" instruction)
  cur_name = "ret";
  drive(0x00008067);
  expect("is_jalr", 0x00008067, dut->is_jalr, 1);
  expect("wb_sel",  0x00008067, dut->wb_sel,  WB_PC4);

  // Illegal / special words
  cur_name = "all zeros";  drive(0x00000000);
  expect("illegal", 0, dut->illegal, 1);
  cur_name = "all ones";   drive(0xFFFFFFFF);
  expect("illegal", 0xFFFFFFFF, dut->illegal, 1);
  cur_name = "ecall (illegal until CSR support)"; drive(0x00000073);
  expect("illegal", 0x73, dut->illegal, 1);
  cur_name = "fence iorw,iorw"; drive(0x0FF0000F);
  expect("illegal",   0x0FF0000F, dut->illegal,   0);
  expect("reg_write", 0x0FF0000F, dut->reg_write, 0);
}

// ---------------------------------------------------------------------------
// Test 2: round trip. Encode random fields, decoder must give them back.
// ---------------------------------------------------------------------------
static void test_roundtrip(std::mt19937& rng) {
  for (const Entry& e : table) {
    for (int n = 0; n < 2000; n++) {
      uint32_t rd = rng() & 31, rs1 = rng() & 31, rs2 = rng() & 31;
      uint32_t f3 = e.funct3 < 0 ? 0 : e.funct3;
      uint32_t inst = 0, exp_imm = 0;

      switch (e.fmt) {
        case FMT_R:
          inst = enc_r(e.funct7, rs2, rs1, f3, rd, e.opcode);
          break;
        case FMT_I: {
          int32_t imm = (int32_t)(rng() % 4096) - 2048;
          if (e.funct7 >= 0) imm = (e.funct7 << 5) | (rng() & 31);  // shift: funct7 + shamt
          inst = enc_i(imm, rs1, f3, rd, e.opcode);
          exp_imm = (uint32_t)imm;
          break;
        }
        case FMT_S: {
          int32_t imm = (int32_t)(rng() % 4096) - 2048;
          inst = enc_s(imm, rs2, rs1, f3, e.opcode);
          exp_imm = (uint32_t)imm;
          break;
        }
        case FMT_B: {
          int32_t imm = ((int32_t)(rng() % 4096) - 2048) * 2;   // even, 13-bit signed
          inst = enc_b(imm, rs2, rs1, f3, e.opcode);
          exp_imm = (uint32_t)imm;
          break;
        }
        case FMT_U: {
          uint32_t u = rng() & 0xFFFFF;
          inst = enc_u(u, rd, e.opcode);
          exp_imm = u << 12;
          break;
        }
        case FMT_J: {
          int32_t imm = ((int32_t)(rng() % 1048576) - 524288) * 2;  // even, 21-bit signed
          inst = enc_j(imm, rd, e.opcode);
          exp_imm = (uint32_t)imm;
          break;
        }
      }

      drive(inst);
      check_controls(e, inst);
      if (e.fmt == FMT_R || e.fmt == FMT_I || e.fmt == FMT_U || e.fmt == FMT_J)
        expect("rd",  inst, dut->rd,  rd);
      if (e.fmt == FMT_R || e.fmt == FMT_I || e.fmt == FMT_S || e.fmt == FMT_B)
        expect("rs1", inst, dut->rs1, rs1);
      if (e.fmt == FMT_R || e.fmt == FMT_S || e.fmt == FMT_B)
        expect("rs2", inst, dut->rs2, rs2);
      if (e.fmt != FMT_R && e.dp)
        expect("imm", inst, dut->imm, exp_imm);
    }
  }
}

// ---------------------------------------------------------------------------
// Test 3: sweep every (opcode, funct3, funct7) combination.
// Legal ones must match the table. Everything else must be illegal and inert.
// ---------------------------------------------------------------------------
static void test_sweep(std::mt19937& rng) {
  for (uint32_t opc = 0; opc < 128; opc++)
    for (uint32_t f3 = 0; f3 < 8; f3++)
      for (uint32_t f7 = 0; f7 < 128; f7++)
        for (int rep = 0; rep < 2; rep++) {
          // random values in all the bits that are not opcode/funct3/funct7
          uint32_t inst = (f7 << 25) | (f3 << 12) | opc | (rng() & 0x01FF8F80);
          drive(inst);
          const Entry* e = lookup(inst);
          if (e) {
            check_controls(*e, inst);
          } else {
            cur_name = "illegal word";
            expect("illegal",   inst, dut->illegal,   1);
            expect("reg_write", inst, dut->reg_write, 0);
            expect("mem_read",  inst, dut->mem_read,  0);
            expect("mem_write", inst, dut->mem_write, 0);
            expect("is_branch", inst, dut->is_branch, 0);
            expect("is_jal",    inst, dut->is_jal,    0);
            expect("is_jalr",   inst, dut->is_jalr,   0);
            expect("uses_rs1",  inst, dut->uses_rs1,  0);
            expect("uses_rs2",  inst, dut->uses_rs2,  0);
          }
        }
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vdecoder;
  std::mt19937 rng(1);   // fixed seed, so failures are reproducible

  test_directed();
  test_roundtrip(rng);
  test_sweep(rng);

  dut->final();
  delete dut;

  if (errors) {
    printf("FAILED: %d of %d checks\n", errors, checks);
    return 1;
  }
  printf("PASSED: %d checks\n", checks);
  return 0;
}
