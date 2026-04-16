#include "core_portme.h"

#include <stdarg.h>

#include "platform.h"

ee_u32 default_num_contexts = 1;
volatile ee_s32 seed1_volatile = 0;
volatile ee_s32 seed2_volatile = 0;
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = 1;
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

int ee_printf(const char *fmt, ...)
{
    va_list args;

    va_start(args, fmt);
    va_end(args);
    (void) fmt;
    return 0;
}