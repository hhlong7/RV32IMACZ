#include "core_portme.h"

#include <stdarg.h>

#include "platform.h"

ee_u32 default_num_contexts = 1;
volatile ee_s32 seed1_volatile = 0;
volatile ee_s32 seed2_volatile = 0;
volatile ee_s32 seed3_volatile = 0x66;
/* CoreMark reads its iteration count from seed 4 (0 = calibrate to a run of
 * at least 10 seconds). */
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

static uint64_t start_time_val;
static uint64_t stop_time_val;

void start_time(void)
{
    start_time_val = platform_read_mtime();
}

void stop_time(void)
{
    stop_time_val = platform_read_mtime();
}

CORE_TICKS get_time(void)
{
    return (CORE_TICKS) (stop_time_val - start_time_val);
}

ee_u32 time_in_secs(CORE_TICKS ticks)
{
    return (ee_u32) (ticks / OTTER_CPU_CLOCK_HZ);
}

void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void) argc;
    (void) argv;

    p->portable_id = 1;
}

void portable_fini(core_portable *p)
{
    p->portable_id = 0;
}

void *portable_malloc(ee_size_t size)
{
    (void) size;
    return NULL;
}

void portable_free(void *p)
{
    (void) p;
}

#ifdef OTTER_BOARD_ZYBO
/* What CoreMark reported, for the board's pass/fail LEDs (main.c). */
volatile int otter_coremark_validated = 0;   /* "Correct operation validated" */
volatile int otter_coremark_errors = 0;      /* "Errors detected" or "ERROR!" */
volatile ee_u32 otter_coremark_iterations = 0;
/* Which error CoreMark reported, for the board's diagnostic LEDs. */
volatile int otter_coremark_crc_error = 0;   /* "[n]ERROR! list/matrix/state crc ..." */
volatile int otter_coremark_time_error = 0;  /* "ERROR! Must execute for at least 10 secs" */
volatile int otter_coremark_type_error = 0;  /* "ERROR! Please define ..." (data types) */

static int starts_with(const char *s, const char *prefix)
{
    while (*prefix) {
        if (*s++ != *prefix++) {
            return 0;
        }
    }
    return 1;
}

static void out_char(char c)
{
    if (c == '\n') {
        platform_uart_putc('\r');
    }
    platform_uart_putc(c);
}

static void out_unsigned(ee_u32 v, unsigned base, int width, char pad)
{
    char buf[12];
    int n = 0;

    do {
        buf[n++] = "0123456789abcdef"[v % base];
        v /= base;
    } while (v != 0U);
    while (n < width--) {
        out_char(pad);
    }
    while (n > 0) {
        out_char(buf[--n]);
    }
}

/* The subset of printf CoreMark uses: %d %u %lu %x %s %c, with a width and
 * zero padding (%04x). */
int ee_printf(const char *fmt, ...)
{
    va_list args;

    if (starts_with(fmt, "Correct operation validated")) {
        otter_coremark_validated = 1;
    }
    if (starts_with(fmt, "Errors detected") || starts_with(fmt, "ERROR")) {
        otter_coremark_errors = 1;
    }
    if (starts_with(fmt, "[%d]ERROR") || starts_with(fmt, "[%u]ERROR")) {
        otter_coremark_errors = 1;
        otter_coremark_crc_error = 1;
    }
    if (starts_with(fmt, "ERROR! Must execute")) {
        otter_coremark_time_error = 1;
    }
    if (starts_with(fmt, "ERROR! Please define")) {
        otter_coremark_type_error = 1;
    }

    va_start(args, fmt);
    if (starts_with(fmt, "Iterations       :")) {
        va_list copy;
        va_copy(copy, args);
        otter_coremark_iterations = va_arg(copy, ee_u32);
        va_end(copy);
    }
    for (const char *p = fmt; *p; p++) {
        char pad = ' ';
        int width = 0;

        if (*p != '%') {
            out_char(*p);
            continue;
        }
        p++;
        if (*p == '0') {
            pad = '0';
            p++;
        }
        while (*p >= '0' && *p <= '9') {
            width = width * 10 + (*p++ - '0');
        }
        while (*p == 'l') {
            p++;
        }
        switch (*p) {
        case 'd': {
            ee_s32 v = va_arg(args, ee_s32);
            if (v < 0) {
                out_char('-');
                v = -v;
            }
            out_unsigned((ee_u32) v, 10U, width, pad);
            break;
        }
        case 'u':
            out_unsigned(va_arg(args, ee_u32), 10U, width, pad);
            break;
        case 'x':
            out_unsigned(va_arg(args, ee_u32), 16U, width, pad);
            break;
        case 's':
            for (const char *s = va_arg(args, const char *); *s; s++) {
                out_char(*s);
            }
            break;
        case 'c':
            out_char((char) va_arg(args, int));
            break;
        case '\0':
            p--;
            break;
        default:
            out_char(*p);
            break;
        }
    }
    va_end(args);
    return 0;
}
#else
/* The simulation build has no UART; CoreMark's report is dropped, which also
 * keeps this workload's cycle count comparable across snapshots. */
int ee_printf(const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    va_end(args);
    (void) fmt;
    return 0;
}
#endif
