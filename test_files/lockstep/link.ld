/* Lockstep test layout.
 *
 * Spike maps its debug module and boot ROM over [0x0000, 0x2000), so lockstep
 * programs start at 0x2000. tools/lockstep.py patches a "j 0x2000" trampoline
 * into word 0 of the RTL memory image, and both traces ignore PCs below 0x2000.
 * Everything must stay inside the core's 64 KB RAM.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
    . = 0x2000;
    .text : { *(.text.init) *(.text .text.*) }

    . = ALIGN(16);
    .data : { *(.data .data.* .rodata .rodata.*) }
    .bss  : { *(.bss .bss.*) }

    . = 0xF000;
    .tohost : { *(.tohost) }

    ASSERT(. <= 0x10000, "lockstep image does not fit in the 64 KB RAM")
}
