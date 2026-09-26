/* Firmware RAM: 16 KiB at 0 (rtl/soc/soc.v MEM_WORDS = 4096); PicoRV32 starts sp at the top.
 * The top 704 bytes are reserved for the stack (measured worst case ~340 bytes: gcc
 * -fcallgraph-info, main -> on_event -> edit_step -> set_channel -> send), so code, data and bss
 * that grow into it are a link error. Before this reserve the bss had grown to the very top and
 * every call overwrote variables (phantom button presses, reboot loops, garbled numbers). */
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 16K - 704
         STACK (rw) : ORIGIN = 16K - 704, LENGTH = 704 }
SECTIONS {
    .text : { KEEP(*(.text.start)) *(.text*) *(.rodata*) *(.srodata*) } > RAM
    .data : { *(.data*) *(.sdata*) } > RAM
    .bss (NOLOAD) : { __bss_start = .; *(.bss*) *(.sbss*) *(COMMON) . = ALIGN(4); __bss_end = .; } > RAM
    __ram_used = .;
    __stack_bottom = ORIGIN(STACK);
    __stack_top = ORIGIN(STACK) + LENGTH(STACK);
}
