#ifndef OTTER_PLATFORM_H
#define OTTER_PLATFORM_H

#include <stdint.h>

/* The timer (mtime) counts core clock cycles. The board build passes the
 * board's core clock (make zybo); the simulation build assumes 100 MHz. */
#ifndef OTTER_CPU_CLOCK_HZ
#define OTTER_CPU_CLOCK_HZ 100000000ULL
#endif

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

#ifdef OTTER_BOARD_ZYBO
/* Zybo Z7-20 board (board/zybo/zybo_top.sv): RGB LEDs and the UART. */
#define OTTER_MMIO_UART_DATA_ADDR   0x11000080UL
#define OTTER_MMIO_UART_STATUS_ADDR 0x11000084UL
#define OTTER_LED_LD0_3   0x00FU
#define OTTER_LED5_RED    (1U << 4)
#define OTTER_LED5_GREEN  (1U << 5)
#define OTTER_LED6_RED    (1U << 7)
#define OTTER_LED6_GREEN  (1U << 8)
#define OTTER_LED6_BLUE   (1U << 9)

void platform_uart_putc(char c);
#endif

#endif