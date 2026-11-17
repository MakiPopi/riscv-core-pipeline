/* Memory layout for programs running on the core.
   Code starts at 0x80000000, the same base as the memory model and as Spike.
   The memory is 64 KiB, so the stack starts at the top, 0x80010000, and grows down. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;

  .text   : { *(.text.init) *(.text .text.*) }
  .rodata : { *(.rodata .rodata.*) }
  .data   : { *(.data .data.* .sdata .sdata.*) }
  .bss    : { *(.bss .bss.* .sbss .sbss.*) *(COMMON) }

  _end = .;
  _stack_top = 0x80010000;
}
