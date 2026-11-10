# Self-checking test: all six branch types, taken and not taken.
# The exit code is the number of the first failing check: grep for ", <code>$" in this file.
    .include "sw/test_macros.inc"

# Registers are already loaded. The branch must be taken / must not be taken.
.macro TAKEN op, ra, rb, num
    \op  \ra, \rb, 1f
    li   x29, \num               # reached only if the branch was NOT taken
    j    test_fail
1:
.endm

.macro NOT_TAKEN op, ra, rb, num
    \op  \ra, \rb, 1f
    j    2f                      # correct: fell through
1:
    li   x29, \num               # reached only if the branch WAS taken
    j    test_fail
2:
.endm

# Load two values into x1 and x2, then check the branch.
.macro BT op, a, b, num
    li   x1, \a
    li   x2, \b
    TAKEN \op, x1, x2, \num
.endm

.macro BN op, a, b, num
    li   x1, \a
    li   x2, \b
    NOT_TAKEN \op, x1, x2, \num
.endm

    .globl _start
_start:
    # Sentinels: a branch must never write a register 
    li   x12, 0x5A5A5A5A
    li   x8,  0x3C3C3C3C
    li   x13, 0x0D0D0D0D
    li   x28, 0x28282828

    # ---- beq ----
    BT beq, 5, 5, 1
    BT beq, 0, 0, 2
    BT beq, -1, -1, 3
    BT beq, 0x80000000, 0x80000000, 4
    BN beq, 5, 6, 5
    BN beq, 6, 5, 6
    BN beq, 0, 0x80000000, 7
    BN beq, 0, 1, 8

    # ---- bne ----
    BT bne, 5, 6, 9
    BT bne, 6, 5, 10
    BT bne, 0, 0x80000000, 11
    BT bne, 0, 1, 12
    BN bne, 5, 5, 13
    BN bne, -1, -1, 14

    # ---- blt (signed) ----
    BT blt, -1, 1, 15
    BT blt, 0x80000000, 1, 16
    BT blt, 0x80000000, 0x7FFFFFFF, 17
    BT blt, -5, -4, 18
    BT blt, 0, 1, 19
    BN blt, 1, -1, 20
    BN blt, 5, 5, 21
    BN blt, 1, 0x80000000, 22
    BN blt, 0x7FFFFFFF, 0x80000000, 23
    BN blt, -4, -5, 24

    # ---- bge (signed) ----
    BT bge, 1, -1, 25
    BT bge, 5, 5, 26
    BT bge, 0x7FFFFFFF, 0x80000000, 27
    BT bge, -4, -5, 28
    BN bge, -1, 1, 29
    BN bge, 0x80000000, 1, 30
    BN bge, -5, -4, 31
    BN bge, 0, 1, 32

    # ---- bltu (unsigned): -1 means 0xFFFFFFFF, the largest value ----
    BT bltu, 1, -1, 33
    BT bltu, 0x7FFFFFFF, 0x80000000, 34
    BT bltu, 0, 1, 35
    BN bltu, -1, 1, 36
    BN bltu, 5, 5, 37
    BN bltu, 0x80000000, 1, 38
    BN bltu, 0x80000000, 0x7FFFFFFF, 39

    # ---- bgeu (unsigned) ----
    BT bgeu, -1, 1, 40
    BT bgeu, 5, 5, 41
    BT bgeu, 0x80000000, 1, 42
    BT bgeu, 0x80000000, 0x7FFFFFFF, 43
    BN bgeu, 1, -1, 44
    BN bgeu, 0x7FFFFFFF, 0x80000000, 45
    BN bgeu, 0, 1, 46

    # ---- x0 as an operand, and the same register on both sides ----
    li   x1, -3
    TAKEN     blt,  x1, x0, 47
    NOT_TAKEN blt,  x0, x1, 48
    TAKEN     bge,  x0, x1, 49
    NOT_TAKEN bltu, x1, x0, 50
    TAKEN     bltu, x0, x1, 51
    li   x1, 7
    TAKEN     bne,  x1, x0, 52
    NOT_TAKEN beq,  x1, x0, 53
    TAKEN     beq,  x1, x1, 54
    NOT_TAKEN bne,  x1, x1, 55
    TAKEN     bge,  x1, x1, 56
    NOT_TAKEN blt,  x1, x1, 57
    TAKEN     beq,  x0, x0, 58

    # ---- far forward branch: offset +4012 uses the high immediate bits ----
    beq  x0, x0, far_fwd
    li   x29, 59
    j    test_fail
    .rept 1000
    nop
    .endr
far_fwd:

    # ---- far backward branch: offset -4004, sign bit set, high bits in use ----
    j    setup_back
back_target:
    j    back_done
    .rept 1000
    nop
    .endr
setup_back:
    beq  x0, x0, back_target
    li   x29, 60
    j    test_fail
back_done:

    # ---- no branch may have written a register ----
    CHECK x12, 0x5A5A5A5A, 61
    CHECK x8,  0x3C3C3C3C, 62
    CHECK x13, 0x0D0D0D0D, 63
    CHECK x28, 0x28282828, 64

    TEST_END
