# Sum 5+4+3+2+1 in a loop, then store the result to the exit address.
# first_loop.mem is this program assembled by hand.
    .globl _start
_start:
    addi x1, x0, 0        # sum = 0
    addi x2, x0, 5        # i = 5
loop:
    add  x1, x1, x2       # sum += i
    addi x2, x2, -1       # i -= 1
    bne  x2, x0, loop     # repeat while i != 0
    lui  x5, 0x10000      # x5 = 0x10000000, the exit address
    sw   x1, 0(x5)        # report the sum (expected: 15)
