#include <stdint.h>

#include "FreeRTOS.h"
#include "task.h"

#include "platform.h"

extern void freertos_risc_v_trap_handler(void);
extern int coremark_main(void);

#ifdef OTTER_BOARD_ZYBO
/* CoreMark's verdict and run length, captured by ee_printf (core_portme.c). */
extern volatile int otter_coremark_validated;
extern volatile int otter_coremark_errors;
extern volatile uint32_t otter_coremark_iterations;
extern volatile int otter_coremark_crc_error;
extern volatile int otter_coremark_time_error;
extern volatile int otter_coremark_type_error;
extern uint32_t get_time(void);

static void print(const char *s)
{
    while (*s) {
        if (*s == '\n') {
            platform_uart_putc('\r');
        }
        platform_uart_putc(*s++);
    }
}

static void print_fixed3(uint64_t thousandths)
{
    char buf[24];
    int n = 0;
    uint64_t whole = thousandths / 1000U;

    do {
        buf[n++] = (char) ('0' + whole % 10U);
        whole /= 10U;
    } while (whole != 0U);
    while (n > 0) {
        platform_uart_putc(buf[--n]);
    }
    platform_uart_putc('.');
    platform_uart_putc((char) ('0' + (thousandths / 100U) % 10U));
    platform_uart_putc((char) ('0' + (thousandths / 10U) % 10U));
    platform_uart_putc((char) ('0' + thousandths % 10U));
}

/* Report the score over the UART, then blink forever.
 *   Passed: every LED blinks, LD5 and LD6 green.
 *   Failed: LD5 and LD6 blink red, and LD0-LD3 hold a steady code saying
 *           what CoreMark reported (for a board without a terminal):
 *             LD0  a CRC check failed (wrong results)
 *             LD1  the timed run was shorter than 10 seconds
 *             LD2  a data-type check failed
 *             LD3  "Correct operation validated" was printed anyway */
static void board_finish(void)
{
    int passed = otter_coremark_validated && !otter_coremark_errors;
    uint32_t ticks = get_time();
    uint32_t code = (otter_coremark_crc_error ? 1U : 0U) | (otter_coremark_time_error ? 2U : 0U) |
                    (otter_coremark_type_error ? 4U : 0U) | (otter_coremark_validated ? 8U : 0U);
    uint32_t blink = passed ? (OTTER_LED_LD0_3 | OTTER_LED5_GREEN | OTTER_LED6_GREEN)
                            : (OTTER_LED5_RED | OTTER_LED6_RED);
    uint32_t steady = passed ? 0U : code;
    uint32_t leds = blink;
    uint64_t next = platform_read_mtime();

    if (ticks != 0U) {
        print("\nCoreMark/MHz    : ");
        print_fixed3((uint64_t) otter_coremark_iterations * 1000000000ULL / ticks);
        print("\nIterations/Sec  : ");
        print_fixed3((uint64_t) otter_coremark_iterations * OTTER_CPU_CLOCK_HZ * 1000ULL / ticks);
        print("\n");
    }
    print(passed ? "CoreMark PASSED on the OTTER core.\n" : "CoreMark FAILED.\n");

    for (;;) {
        platform_write_leds(leds | steady);
        next += OTTER_CPU_CLOCK_HZ / 4U;        /* 4 changes a second */
        while (platform_read_mtime() < next) {
        }
        leds ^= blink;
    }
}
#endif

/* Route unexpected synchronous exceptions to a visible failure code so the
 * RTL testbench can distinguish trap-entry bugs from software failures. */
void freertos_risc_v_application_exception_handler(void)
{
    uint32_t mcause;
    uint32_t mepc;

    __asm volatile ("csrr %0, mcause" : "=r"(mcause));
    __asm volatile ("csrr %0, mepc" : "=r"(mepc));
    platform_write_leds((mcause << 16) | (mepc & 0xffffU));
    platform_signal_failure(OTTER_STATUS_TRAP_EXCEPTION);
}

/* FreeRTOS should consume machine timer interrupts internally, so reaching this
 * handler indicates the platform interrupt plumbing is wrong. */
void freertos_risc_v_application_interrupt_handler(void)
{
    uint32_t mcause;
    uint32_t mepc;

    __asm volatile ("csrr %0, mcause" : "=r"(mcause));
    __asm volatile ("csrr %0, mepc" : "=r"(mepc));
    platform_write_leds((mcause << 16) | (mepc & 0xffffU));
    platform_signal_failure(OTTER_STATUS_TRAP_INTERRUPT);
}

/* Run CoreMark as a normal task so the port is validated through scheduler,
 * trap, and timer-tick paths instead of a bare-metal direct call. */
static void coremark_task(void *context)
{
    uint64_t start_cycles;
    uint64_t end_cycles;
    int result;

    (void) context;

#ifdef OTTER_BOARD_ZYBO
    /* LD6 blue while the benchmark runs: about 10 seconds of calibration, then
     * the timed run of at least 10 seconds (about 30 seconds at 35.7 MHz). */
    platform_write_leds(OTTER_LED6_BLUE);
    print("\n\nOTTER RV32IMAC on a Zybo Z7-20: running CoreMark (about 30 seconds)...\n");
#endif

    start_cycles = platform_read_mtime();
    result = coremark_main();
    end_cycles = platform_read_mtime();

#ifdef OTTER_BOARD_ZYBO
    (void) start_cycles;
    (void) end_cycles;
    (void) result;
    board_finish();
#endif

    /* Reuse LEDs as a cheap cycle-count output for the simulation transcript. */
    platform_write_leds((uint32_t) (end_cycles - start_cycles));

    if (result != 0) {
        platform_signal_failure(OTTER_STATUS_COREMARK_FAIL);
    }

    platform_write_sseg(OTTER_STATUS_COREMARK_DONE);

    for (;;) {
    }
}

/* Heap exhaustion should never occur in this smoke configuration. */
void vApplicationMallocFailedHook(void)
{
    platform_signal_failure(OTTER_STATUS_MALLOC_FAIL);
}

/* Stack overflow is surfaced separately because it often indicates a bad port
 * layer or an undersized task stack rather than an RTL issue. */
void vApplicationStackOverflowHook(TaskHandle_t task, char *task_name)
{
    (void) task;
    (void) task_name;
    platform_signal_failure(OTTER_STATUS_STACK_FAIL);
}

int main(void)
{
    BaseType_t created;

    /* Code 200 marks that reset, C startup, and the early platform layer all
     * completed before the scheduler was started. */
    platform_write_sseg(OTTER_STATUS_BOOTING);
    platform_install_trap_vector(freertos_risc_v_trap_handler);

    /* Create a single benchmarking task; the test is about OS bring-up and
     * timer-driven scheduling rather than application concurrency. */
    created = xTaskCreate(coremark_task,
                          "coremark",
                          4096,
                          NULL,
                          tskIDLE_PRIORITY + 2,
                          NULL);
    if (created != pdPASS) {
        platform_signal_failure(OTTER_STATUS_TASK_CREATE_FAIL);
    }

    /* Any return here means the scheduler could not run correctly. */
    vTaskStartScheduler();
    platform_signal_failure(OTTER_STATUS_TASK_CREATE_FAIL);
    return 0;
}