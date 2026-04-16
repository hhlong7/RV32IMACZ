#include "platform.h"

/* Keep the MMIO addresses in one place so the rest of the port can use small
 * helper functions instead of open-coded volatile pointer arithmetic. */
static volatile uint32_t * const leds_reg = (volatile uint32_t *) OTTER_MMIO_LEDS_ADDR;
static volatile uint32_t * const sseg_reg = (volatile uint32_t *) OTTER_MMIO_SSEG_ADDR;
static volatile uint32_t * const mtime_lo_reg = (volatile uint32_t *) 0x0200BFF8UL;
static volatile uint32_t * const mtime_hi_reg = (volatile uint32_t *) 0x0200BFFCUL;

void platform_write_leds(uint32_t value)
{
    *leds_reg = value;
}

void platform_write_sseg(uint32_t value)
{
    *sseg_reg = value;
}

uint64_t platform_read_mtime(void)
{
    uint32_t hi_before;
    uint32_t lo;
    uint32_t hi_after;

    /* Read the split 64-bit timer atomically by retrying if the high word
     * changes while the low word is sampled. */
    do {
        hi_before = *mtime_hi_reg;
        lo = *mtime_lo_reg;
        hi_after = *mtime_hi_reg;
    } while (hi_before != hi_after);

    return ((uint64_t) hi_after << 32) | lo;
}

void platform_install_trap_vector(void *handler)
{
    uintptr_t base = (uintptr_t) handler;
    /* The FreeRTOS RISC-V port expects mtvec to point at its trap entry shim. */
    __asm volatile ("csrw mtvec, %0" :: "r"(base));
}

void platform_signal_failure(uint32_t code)
{
    /* Publish the failure code before halting so both the seven-segment display
     * and the simulation transcript show the terminal status. */
    platform_write_sseg(code);
    platform_write_leds(code);
    __asm volatile ("csrc mstatus, 8");

    for (;;) {
    }
}