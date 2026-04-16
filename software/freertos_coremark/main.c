#include <stdint.h>

#include "FreeRTOS.h"
#include "task.h"

#include "platform.h"

extern void freertos_risc_v_trap_handler(void);
extern int coremark_main(void);

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

    start_cycles = platform_read_mtime();
    result = coremark_main();
    end_cycles = platform_read_mtime();

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