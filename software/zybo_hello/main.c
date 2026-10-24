// Board demo for the Zybo Z7-20 (board/zybo/zybo_top.sv).
//
// Prints a banner over the UART (115200 8N1), then:
//   - echoes every character typed (Enter starts a new line),
//   - shows the switches on LD3..LD0 and reports when they change,
//   - lights LD5 green once running and blinks LD6 blue as a heartbeat.
// Typing 'i' prints the cycle and retired-instruction counters.

#include <stdint.h>

#define MMIO32(addr) (*(volatile uint32_t *)(addr))

#define SWITCHES    MMIO32(0x11000000UL)
#define LEDS        MMIO32(0x11000020UL)
#define UART_DATA   MMIO32(0x11000080UL)
#define UART_STATUS MMIO32(0x11000084UL)

#define UART_TX_READY 0x1u
#define UART_RX_VALID 0x2u

#define LED5_GREEN (1u << 5)
#define LED6_BLUE  (1u << 9)

static void uart_putc(char c) {
    while (!(UART_STATUS & UART_TX_READY))
        ;
    UART_DATA = (uint8_t)c;
}

static void uart_puts(const char *s) {
    while (*s) {
        if (*s == '\n')
            uart_putc('\r');
        uart_putc(*s++);
    }
}

static int uart_getc(void) {
    if (!(UART_STATUS & UART_RX_VALID))
        return -1;
    int c = (int)(UART_DATA & 0xFF);
    UART_STATUS = 0;            // acknowledge
    return c;
}

static void put_dec(uint64_t v) {
    char buf[21];
    int i = 0;
    do {
        buf[i++] = (char)('0' + v % 10);
        v /= 10;
    } while (v);
    while (i)
        uart_putc(buf[--i]);
}

static void put_hex(uint32_t v, int digits) {
    for (int i = digits - 1; i >= 0; i--)
        uart_putc("0123456789abcdef"[(v >> (4 * i)) & 0xF]);
}

static uint64_t read_counter_cycle(void) {
    uint32_t hi, lo, hi2;
    do {
        __asm__ volatile("csrr %0, mcycleh" : "=r"(hi));
        __asm__ volatile("csrr %0, mcycle" : "=r"(lo));
        __asm__ volatile("csrr %0, mcycleh" : "=r"(hi2));
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

static uint64_t read_counter_instret(void) {
    uint32_t hi, lo, hi2;
    do {
        __asm__ volatile("csrr %0, minstreth" : "=r"(hi));
        __asm__ volatile("csrr %0, minstret" : "=r"(lo));
        __asm__ volatile("csrr %0, minstreth" : "=r"(hi2));
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

int main(void) {
    uint32_t leds = LED5_GREEN;
    uint32_t last_switches = 0xFFFFFFFFu;
    uint64_t next_beat = 0;

    LEDS = leds;
    uart_puts("\n\nOTTER RV32IMAC out-of-order core on a Zybo Z7-20\n");
    uart_puts("Type to echo; 'i' prints the cycle and instruction counters.\n> ");

    for (;;) {
        uint32_t switches = SWITCHES & 0x7F;
        if (switches != last_switches) {
            last_switches = switches;
            leds = (leds & ~0xFu) | (switches & 0xFu);
            LEDS = leds;
            uart_puts("\n[switches ");
            put_hex(switches & 0xF, 1);
            uart_puts(", buttons ");
            put_hex(switches >> 4, 1);
            uart_puts("]\n> ");
        }

        int c = uart_getc();
        if (c == 'i') {
            uint64_t cycles = read_counter_cycle();
            uint64_t instret = read_counter_instret();
            uart_puts("\ncycles ");
            put_dec(cycles);
            uart_puts(", instructions ");
            put_dec(instret);
            uart_puts("\n> ");
        } else if (c == '\r' || c == '\n') {
            uart_puts("\n> ");
        } else if (c >= 0) {
            uart_putc((char)c);
        }

        uint64_t now = read_counter_cycle();
        if (now >= next_beat) {
            next_beat = now + 18750000u;    // half a second at 37.5 MHz
            leds ^= LED6_BLUE;
            LEDS = leds;
        }
    }
}
