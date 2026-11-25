# Return-stack stress test. The branch in h is a coin flip, and its wrong path contains a call (jal t0, f)
# or a return (ret): a wrong push or a wrong pop of the speculative return stack, which only the repair on
# a redirect can undo. f is a call/return pair that uses x5 as its link register.
# Self-check: f runs once for every set bit of 1000 xorshift32 outputs (510 times, computed in Python).
    .include "sw/test_macros.inc"
    .globl _start
_start:
    li   s0, 0x92d68ca2        # xorshift32 state
    li   s1, 0                 # number of times f ran
    li   s2, 1000              # iterations
loop:
    slli t2, s0, 13
    xor  s0, s0, t2
    srli t2, s0, 17
    xor  s0, s0, t2
    slli t2, s0, 5
    xor  s0, s0, t2
    jal  ra, h
    addi s2, s2, -1
    bnez s2, loop
    CHECK s1, 510, 1
    TEST_END

h:
    andi t1, s0, 1
    beqz t1, h_end             # a coin flip
    jal  t0, f                 # a call that uses x5 as its link register
h_end:
    ret
f:
    addi s1, s1, 1
    jr   t0                    # a return through x5
