ENTRY(_start)
OUTPUT_FORMAT("binary")

SECTIONS
{
    . = 0x600;
    .text : {
        /* start.o (.text) */
        *(.text)
        *(.data)
        . = 510;
        BYTE(0x55);
        BYTE(0xaa);
    }
    .bss : {
        *(.bss)
    }
}
