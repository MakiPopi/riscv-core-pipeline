# Startup code for compiled C programs: set the stack, call main, report main's return value
# as the exit code (a store to the exit address, like the assembly tests).
    .section .text.init, "ax"
    .globl _start
_start:
    la   sp, _stack_top
    call main
    lui  x31, 0x20000            # x31 = 0x20000000, the exit address
    sw   a0, 0(x31)              # main's return value is the exit code
    ebreak                       # never reached: the harness ends the run at the exit store
