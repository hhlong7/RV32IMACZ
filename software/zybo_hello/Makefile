# Board demo for the Zybo Z7-20. `make` builds build/zybo_hello.mem and
# copies it to board/zybo/zybo_hello.mem, the image the board build uses
# (checked in, so the Vivado machine needs no RISC-V compiler).
CROSS ?= riscv64-unknown-elf
CC := $(CROSS)-gcc
OBJCOPY := $(CROSS)-objcopy
OBJDUMP := $(CROSS)-objdump

ROOT := $(abspath ../..)
BUILD := $(CURDIR)/build
# Same startup code and memory map as the FreeRTOS + CoreMark build.
COMMON := $(ROOT)/software/freertos_coremark

CFLAGS := -march=rv32imac_zicsr_zifencei -mabi=ilp32 -O2 -ffreestanding -fno-builtin -fdata-sections -ffunction-sections -Wall -Wextra -msmall-data-limit=0
LDFLAGS := $(CFLAGS) -nostartfiles -Wl,--gc-sections -Wl,-Map,$(BUILD)/zybo_hello.map -T $(COMMON)/linker.ld
LDLIBS := -lgcc

all: $(ROOT)/board/zybo/zybo_hello.mem

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/zybo_hello.elf: $(CURDIR)/main.c $(COMMON)/startup.S | $(BUILD)
	$(CC) $(LDFLAGS) $^ $(LDLIBS) -o $@
	$(OBJDUMP) -d $@ > $(BUILD)/zybo_hello.disasm
	$(OBJCOPY) -O binary $@ $(BUILD)/zybo_hello.bin

$(BUILD)/zybo_hello.mem: $(BUILD)/zybo_hello.elf $(ROOT)/tools/elf_to_mem.py
	python3 $(ROOT)/tools/elf_to_mem.py $(BUILD)/zybo_hello.bin $@

$(ROOT)/board/zybo/zybo_hello.mem: $(BUILD)/zybo_hello.mem
	cp $< $@

clean:
	rm -rf $(BUILD)

.PHONY: all clean
