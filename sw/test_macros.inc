# Shared macros for self-checking test programs.
# x29, x30 and x31 are reserved for the framework; tests may use x1..x28.
# Exit code 0 means every check passed; any other code is the number of the
# first CHECK that failed.

.macro CHECK reg, expected, num
    li   x30, \expected          # expected value, worked out by hand
    beq  \reg, x30, 1f           # equal: skip over the failure path
    li   x29, \num               # not equal: remember which check failed
    j    test_fail
1:
.endm

# Put this as the last line of the test. Both paths store to the exit address.
.macro TEST_END
    lui  x31, 0x20000            # x31 = 0x20000000, the exit address
    sw   x0, 0(x31)              # success: exit code 0
test_fail:
    lui  x31, 0x20000
    sw   x29, 0(x31)             # failure: exit code = check number
.endm
