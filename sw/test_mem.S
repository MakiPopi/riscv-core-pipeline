# Self-checking test: every load and store at every byte offset.
# The exit code is the number of the first failing check: grep for ", <code>$" in this file.
    .include "sw/test_macros.inc"

# Load with <insn> from <off>(x1) into x2 and compare with a hand-computed value.
.macro LOADCHK insn, off, expected, num
    \insn x2, \off(x1)
    CHECK x2, \expected, \num
.endm

# Put a known word into scratch word 0 (x1 must point at scratch).
.macro INIT_WORD value
    li   x7, \value
    sw   x7, 0(x1)
.endm

    .globl _start
_start:
    # Sentinels: a store has imm[4:0] in the rd field and must never write a register
    li   x12, 0x5A5A5A5A
    li   x8,  0x3C3C3C3C

    # ================= Loads from initialised data =================
    # data_w0 = 0xF1E2D3C4 -> bytes C4 D3 E2 F1 (every sign bit set)
    # data_w1 = 0x7F6E5D4C -> bytes 4C 5D 6E 7F (every sign bit clear)
    # data_w2 = 0x80FF7F01 -> bytes 01 7F FF 80 (mixed)
    la   x1, data_w0
    LOADCHK lw,  0, 0xF1E2D3C4, 1
    LOADCHK lw,  4, 0x7F6E5D4C, 2
    LOADCHK lw,  8, 0x80FF7F01, 3

    LOADCHK lb,  0, 0xFFFFFFC4, 4        # sign-extended
    LOADCHK lb,  1, 0xFFFFFFD3, 5
    LOADCHK lb,  2, 0xFFFFFFE2, 6
    LOADCHK lb,  3, 0xFFFFFFF1, 7
    LOADCHK lbu, 0, 0x000000C4, 8        # zero-extended
    LOADCHK lbu, 1, 0x000000D3, 9
    LOADCHK lbu, 2, 0x000000E2, 10
    LOADCHK lbu, 3, 0x000000F1, 11
    LOADCHK lh,  0, 0xFFFFD3C4, 12       # bytes C4,D3 -> 0xD3C4
    LOADCHK lh,  2, 0xFFFFF1E2, 13       # bytes E2,F1 -> 0xF1E2
    LOADCHK lhu, 0, 0x0000D3C4, 14
    LOADCHK lhu, 2, 0x0000F1E2, 15

    LOADCHK lb,  4, 0x0000004C, 16       # sign bit clear: zeros
    LOADCHK lb,  5, 0x0000005D, 17
    LOADCHK lb,  6, 0x0000006E, 18
    LOADCHK lb,  7, 0x0000007F, 19
    LOADCHK lbu, 7, 0x0000007F, 20
    LOADCHK lh,  4, 0x00005D4C, 21
    LOADCHK lh,  6, 0x00007F6E, 22
    LOADCHK lhu, 6, 0x00007F6E, 23

    LOADCHK lb,  9, 0x0000007F, 24       # bytes 01 7F FF 80
    LOADCHK lb, 10, 0xFFFFFFFF, 25
    LOADCHK lbu,10, 0x000000FF, 26
    LOADCHK lb, 11, 0xFFFFFF80, 27
    LOADCHK lbu,11, 0x00000080, 28
    LOADCHK lh,  8, 0x00007F01, 29       # halves 0x7F01 and 0x80FF
    LOADCHK lh, 10, 0xFFFF80FF, 30
    LOADCHK lhu,10, 0x000080FF, 31
    LOADCHK lb,  8, 0x00000001, 32

    # ---- negative offsets (base = data_w0 + 8) ----
    addi x3, x1, 8
    lw   x2, -8(x3)                      # data_w0
    CHECK x2, 0xF1E2D3C4, 33
    lb   x2, -5(x3)                      # byte at data_w0 + 3
    CHECK x2, 0xFFFFFFF1, 34
    lhu  x2, -2(x3)                      # half at data_w0 + 6
    CHECK x2, 0x00007F6E, 35
    lh   x2, -6(x3)                      # half at data_w0 + 2
    CHECK x2, 0xFFFFF1E2, 36

    # ---- rd == rs1: the address uses the OLD value of the register ----
    la   x4, data_w0
    lw   x4, 0(x4)
    CHECK x4, 0xF1E2D3C4, 37

    # ---- loads into x0 write nothing ----
    lw   x0, 0(x1)
    CHECK x0, 0, 38
    lb   x0, 0(x1)
    CHECK x0, 0, 39

    # ================= Stores =================
    la   x1, scratch                     # scratch words: 11223344 55667788 99AABBCC DDEEFF00
    li   x4, 0xAABBCCDD
    li   x5, 0x99887766
    li   x6, 0xFEDCBAA5

    sw   x4, 0(x1)
    LOADCHK lw, 0, 0xAABBCCDD, 40
    LOADCHK lw, 4, 0x55667788, 41        # the next word is untouched

    # ---- sb: only the low byte of rs2, only the addressed lane ----
    INIT_WORD 0x11223344
    sb   x4, 0(x1)                       # byte 0 = DD
    LOADCHK lw, 0, 0x112233DD, 42
    sb   x5, 1(x1)                       # byte 1 = 66
    LOADCHK lw, 0, 0x112266DD, 43
    sb   x6, 2(x1)                       # byte 2 = A5
    LOADCHK lw, 0, 0x11A566DD, 44
    sb   x4, 3(x1)                       # byte 3 = DD
    LOADCHK lw, 0, 0xDDA566DD, 45

    # ---- sh: only the low half of rs2, only the addressed half ----
    INIT_WORD 0x11223344
    sh   x4, 0(x1)                       # low half = CCDD
    LOADCHK lw, 0, 0x1122CCDD, 46
    sh   x5, 2(x1)                       # high half = 7766
    LOADCHK lw, 0, 0x7766CCDD, 47
    INIT_WORD 0x11223344
    sh   x6, 2(x1)                       # high half = BAA5, low half untouched
    LOADCHK lw, 0, 0xBAA53344, 48

    # ---- negative store offsets (base = scratch + 16) ----
    addi x3, x1, 16
    sw   x4, -16(x3)                     # scratch word 0
    LOADCHK lw, 0, 0xAABBCCDD, 49
    sb   x5, -15(x3)                     # scratch byte 1 = 66
    LOADCHK lw, 0, 0xAABB66DD, 50

    # ---- stores whose rd field (imm[4:0]) is x12 and x8: sentinels must survive ----
    sw   x4, 12(x1)
    LOADCHK lw, 12, 0xAABBCCDD, 51
    sw   x5, 8(x1)
    LOADCHK lw, 8, 0x99887766, 52
    CHECK x12, 0x5A5A5A5A, 53
    CHECK x8,  0x3C3C3C3C, 54

    # ---- nothing outside the addressed words changed ----
    LOADCHK lw,  4, 0x55667788, 55       # untouched scratch word
    LOADCHK lw, -4, 0xAAAA5555, 56       # guard before scratch
    LOADCHK lw, 16, 0x5555AAAA, 57       # guard after scratch

    # ---- fence is a no-op: it must not trap or change anything ----
    li   x9, 7
    fence
    CHECK x9, 7, 58

    TEST_END

    .data
    .balign 4
data_w0:  .word 0xF1E2D3C4
data_w1:  .word 0x7F6E5D4C
data_w2:  .word 0x80FF7F01
guard_lo: .word 0xAAAA5555
scratch:  .word 0x11223344, 0x55667788, 0x99AABBCC, 0xDDEEFF00
guard_hi: .word 0x5555AAAA
