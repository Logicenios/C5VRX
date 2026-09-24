/* Firmware RAM: 16 KiB at 0 (rtl/soc/soc.v MEM_WORDS = 4096); stack grows down from the top. */
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 16K }
SECTIONS {
    .text : { KEEP(*(.text.start)) *(.text*) *(.rodata*) *(.srodata*) } > RAM
    .data : { *(.data*) *(.sdata*) } > RAM
    .bss (NOLOAD) : { __bss_start = .; *(.bss*) *(.sbss*) *(COMMON) . = ALIGN(4); __bss_end = .; } > RAM
    __ram_used = .;
}
