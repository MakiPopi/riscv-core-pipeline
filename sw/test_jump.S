# Self-checking test: jal, jalr, link values, bit-0 clearing, call/return.
# The exit code is the number of the first failing check: grep for ", <code>$" in this file.
# A jalr that fails to clear bit 0 makes the core trap on a misaligned target
# (the harness prints "TRAP: ..." instead of an exit code).
    .include "sw/test_macros.inc"

# Compare two registers (CHECK compares a register with a constant)
.macro CHECK_EQ ra, rb, num
    beq  \ra, \rb, 1f
    li   x29, \num
    j    test_fail
1:
.endm

    .globl _start
_start:
    # ---- jal forward: jumps, and rd = address of the instruction after the jal ----
    auipc x1, 0                  # x1 = P, the address of this auipc
    jal   x2, jal_f1             # at P+4, so the link must be P+8
    li    x29, 1                 # reached only if the jal did not jump
    j     test_fail
jal_f1:
    addi  x3, x1, 8
    CHECK_EQ x2, x3, 2

    # ---- jal with rd = x0: jumps, writes nothing ----
    jal   x0, jal_f2
    li    x29, 3
    j     test_fail
jal_f2:
    CHECK x0, 0, 4

    # ---- jal backward ----
    li    x4, 0
    j     jal_b_setup
jal_b_target:
    li    x4, 77                 # reached only through the backward jal
    j     jal_b_done
jal_b_setup:
    auipc x6, 0
    jal   x5, jal_b_target       # backward; link = (auipc address) + 8
    li    x29, 5
    j     test_fail
jal_b_done:
    CHECK x4, 77, 6
    addi  x6, x6, 8
    CHECK_EQ x5, x6, 7

    # ---- jal far forward: offset +8012, uses the upper immediate bits ----
    auipc x8, 0
    jal   x7, jal_far_f
    li    x29, 8
    j     test_fail
    .rept 2000
    nop
    .endr
jal_far_f:
    addi  x8, x8, 8
    CHECK_EQ x7, x8, 9

    # ---- jal far backward: offset -8008, sign bit and upper bits in use ----
    li    x9, 0
    j     jal_far_b_setup
jal_far_b_target:
    li    x9, 99
    j     jal_far_b_done
    .rept 2000
    nop
    .endr
jal_far_b_setup:
    jal   x0, jal_far_b_target
    li    x29, 10
    j     test_fail
jal_far_b_done:
    CHECK x9, 99, 11

    # ---- jalr: target = rs1 + imm, link = address of the next instruction ----
    la    x10, jalr_t1
    auipc x6, 0
    jalr  x11, 0(x10)            # at P+4, so the link must be P+8
    li    x29, 12
    j     test_fail
jalr_t1:
    addi  x6, x6, 8
    CHECK_EQ x11, x6, 13

    # ---- jalr with positive and negative offsets, rd = x0 ----
    la    x10, jalr_t2
    addi  x10, x10, -8
    jalr  x0, 8(x10)             # (jalr_t2 - 8) + 8
    li    x29, 14
    j     test_fail
jalr_t2:
    la    x10, jalr_t3
    addi  x10, x10, 12
    jalr  x0, -12(x10)           # (jalr_t3 + 12) - 12
    li    x29, 15
    j     test_fail
jalr_t3:
    CHECK x0, 0, 16

    # ---- jalr must clear bit 0 of the target (three ways to get an odd sum) ----
    la    x10, jalr_b0a
    addi  x10, x10, 1            # odd register value
    jalr  x0, 0(x10)
    li    x29, 17
    j     test_fail
jalr_b0a:
    la    x10, jalr_b0b
    jalr  x0, 1(x10)             # odd offset
    li    x29, 18
    j     test_fail
jalr_b0b:
    la    x10, jalr_b0c
    addi  x10, x10, 5
    jalr  x0, -4(x10)            # (target + 5) - 4 = target + 1
    li    x29, 19
    j     test_fail
jalr_b0c:

    # ---- jalr with rd == rs1: the target uses the OLD x10, then x10 gets the link ----
    la    x10, jalr_t4
    auipc x6, 0
    jalr  x10, 0(x10)
    li    x29, 20
    j     test_fail
jalr_t4:
    addi  x6, x6, 8
    CHECK_EQ x10, x6, 21

    # ---- call and return, as compiled code does it ----
    li    x20, 0
    jal   ra, func_leaf
    CHECK x20, 123, 22
    li    x22, 0
    jal   ra, func_outer         # outer saves ra, calls inner, restores ra, returns
    CHECK x22, 1, 23
    j     calls_done

func_leaf:
    li    x20, 123
    ret                          # jalr x0, 0(ra)
func_outer:
    mv    x21, ra
    jal   ra, func_inner
    mv    ra, x21
    ret
func_inner:
    addi  x22, x22, 1
    ret
calls_done:

    TEST_END
