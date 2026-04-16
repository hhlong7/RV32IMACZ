#ifndef OTTER_PLATFORM_H
#define OTTER_PLATFORM_H

#include <stdint.h>

#define OTTER_CPU_CLOCK_HZ 100000000ULL

#define OTTER_MMIO_LEDS_ADDR 0x11000020UL
#define OTTER_MMIO_SSEG_ADDR 0x11000040UL

#define OTTER_STATUS_BOOTING          200U
#define OTTER_STATUS_COREMARK_DONE    201U
#define OTTER_STATUS_TASK_CREATE_FAIL 901U
#define OTTER_STATUS_COREMARK_FAIL    902U
#define OTTER_STATUS_MALLOC_FAIL      903U
#define OTTER_STATUS_STACK_FAIL       904U
#define OTTER_STATUS_TRAP_EXCEPTION   905U
#define OTTER_STATUS_TRAP_INTERRUPT   906U

void platform_write_leds(uint32_t value);
void platform_write_sseg(uint32_t value);
uint64_t platform_read_mtime(void);
void platform_install_trap_vector(void *handler);
void platform_signal_failure(uint32_t code);

#endif