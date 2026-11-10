# Self-checking test: ALU instructions, lui/auipc, x0, read-and-write of one register.
    .include "sw/test_macros.inc"
    .globl _start
_start:
    # ---- x0 is hardwired to zero ----
    addi x0, x0, 5               # writing x0 must do nothing
    CHECK x0, 0, 1
    addi x1, x0, 5               # x0 still reads as zero: x1 = 5
    CHECK x1, 5, 2

    # ---- an instruction reads the OLD value of the register it writes ----
    addi x1, x1, 1               # 5 -> 6
    CHECK x1, 6, 3
    add  x1, x1, x1              # 6 + 6 = 12
    CHECK x1, 12, 4

    # ---- OP-IMM ----
    li   x1, 10
    addi x2, x1, 5
    CHECK x2, 15, 5
    addi x2, x1, -20
    CHECK x2, -10, 6
    slti x2, x1, 11              # 10 < 11
    CHECK x2, 1, 7
    slti x2, x1, 10              # 10 < 10 is false
    CHECK x2, 0, 8
    li   x1, -5
    slti x2, x1, -4              # -5 < -4 signed
    CHECK x2, 1, 9
    sltiu x2, x1, 1              # 0xFFFFFFFB < 1 unsigned: false
    CHECK x2, 0, 10
    sltiu x2, x0, 1              # 0 < 1: the "seqz" idiom
    CHECK x2, 1, 11
    li   x1, 5
    sltiu x2, x1, -1             # imm sign-extends to 0xFFFFFFFF, so 5 < it
    CHECK x2, 1, 12
    li   x1, 0xFF
    xori x2, x1, 0x0F
    CHECK x2, 0xF0, 13
    xori x2, x1, -1              # bitwise NOT
    CHECK x2, 0xFFFFFF00, 14
    li   x1, 0xF0
    ori  x2, x1, 0x0F
    CHECK x2, 0xFF, 15
    li   x1, 0xFF
    andi x2, x1, 0x3C
    CHECK x2, 0x3C, 16
    li   x1, 1
    slli x2, x1, 31
    CHECK x2, 0x80000000, 17
    li   x1, 3
    slli x2, x1, 4               # 3 * 16
    CHECK x2, 48, 18
    li   x1, 0x80000000
    srli x2, x1, 31              # zeros shifted in
    CHECK x2, 1, 19
    srli x2, x1, 4
    CHECK x2, 0x08000000, 20
    srai x2, x1, 4               # sign bit copied in
    CHECK x2, 0xF8000000, 21
    srai x2, x1, 31
    CHECK x2, -1, 22
    li   x1, 0x40000000
    srai x2, x1, 4               # positive value: zeros shifted in
    CHECK x2, 0x04000000, 23

    # ---- LUI / AUIPC ----
    lui  x2, 0x12345
    CHECK x2, 0x12345000, 24
    lui  x2, 0xFFFFF
    CHECK x2, 0xFFFFF000, 25
    auipc x2, 1                  # P + 0x1000, where P is this instruction's address
    auipc x3, 0                  # P + 4
    sub  x4, x2, x3              # 0x1000 - 4
    CHECK x4, 0xFFC, 26

    # ---- OP (register-register) ----
    li   x1, 7
    li   x2, 3
    add  x3, x1, x2
    CHECK x3, 10, 27
    sub  x3, x1, x2
    CHECK x3, 4, 28
    sub  x3, x2, x1
    CHECK x3, -4, 29
    li   x1, 1
    li   x2, 33                  # only the low 5 bits count: shift by 1
    sll  x3, x1, x2
    CHECK x3, 2, 30
    li   x1, -1
    li   x2, 1
    slt  x3, x1, x2              # -1 < 1 signed
    CHECK x3, 1, 31
    sltu x3, x1, x2              # 0xFFFFFFFF < 1 unsigned: false
    CHECK x3, 0, 32
    slt  x3, x2, x1              # 1 < -1 signed: false
    CHECK x3, 0, 33
    sltu x3, x2, x1              # 1 < 0xFFFFFFFF unsigned
    CHECK x3, 1, 34
    li   x1, 0xFF00FF00
    li   x2, 0x0FF00FF0
    xor  x3, x1, x2
    CHECK x3, 0xF0F0F0F0, 35
    and  x3, x1, x2
    CHECK x3, 0x0F000F00, 36
    or   x3, x1, x2
    CHECK x3, 0xFFF0FFF0, 37
    li   x1, 0x80000000
    li   x2, 4
    srl  x3, x1, x2
    CHECK x3, 0x08000000, 38
    sra  x3, x1, x2
    CHECK x3, 0xF8000000, 39
    li   x2, 36                  # low 5 bits = 4
    srl  x3, x1, x2
    CHECK x3, 0x08000000, 40
    sra  x3, x1, x2
    CHECK x3, 0xF8000000, 41

    TEST_END
