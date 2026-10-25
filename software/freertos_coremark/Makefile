CROSS ?= riscv64-unknown-elf
CC := $(CROSS)-gcc
OBJCOPY := $(CROSS)-objcopy
OBJDUMP := $(CROSS)-objdump

ROOT := $(abspath ../..)
BUILD := $(CURDIR)/build

# `make` builds the simulation image (one iteration, about 325,000 cycles;
# tools/run_freertos_coremark.sh).
# `make zybo` builds board/zybo/coremark.mem for the Zybo Z7-20: CoreMark
# calibrates itself to a valid timed run of at least 10 seconds (ITERATIONS=0), prints
# its report on the UART, and blinks the LEDs when done (main.c).
ITERATIONS ?= 1
BOARD_CPPFLAGS :=
ifeq ($(BOARD),zybo)
BUILD := $(CURDIR)/build-zybo
ITERATIONS := 0
ZYBO_CLOCK_HZ ?= 35714286
BOARD_CPPFLAGS := -DOTTER_BOARD_ZYBO -DOTTER_CPU_CLOCK_HZ=$(ZYBO_CLOCK_HZ)ULL
endif

CFLAGS := -march=rv32imac_zicsr_zifencei -mabi=ilp32 -O2 -ffreestanding -fno-builtin -fdata-sections -ffunction-sections -Wall -Wextra -Wno-unused-parameter -msmall-data-limit=0
CPPFLAGS := \
	-I$(CURDIR) \
	-I$(ROOT)/third_party/FreeRTOS-Kernel/include \
	-I$(ROOT)/third_party/FreeRTOS-Kernel/portable/GCC/RISC-V \
	-I$(ROOT)/third_party/coremark \
	-DITERATIONS=$(ITERATIONS) \
	-DTOTAL_DATA_SIZE=2000 \
	-DPERFORMANCE_RUN=1 \
	-DMAIN_HAS_NOARGC=1 \
	$(BOARD_CPPFLAGS)
ASFLAGS := $(CFLAGS) -x assembler-with-cpp -I$(ROOT)/third_party/FreeRTOS-Kernel/portable/GCC/RISC-V/chip_specific_extensions/RISCV_MTIME_CLINT_no_extensions
LDFLAGS := $(CFLAGS) -nostartfiles -Wl,--gc-sections -Wl,-Map,$(BUILD)/freertos_coremark.map -T $(CURDIR)/linker.ld
LDLIBS := -lgcc

FREERTOS_SRC := \
	$(ROOT)/third_party/FreeRTOS-Kernel/tasks.c \
	$(ROOT)/third_party/FreeRTOS-Kernel/list.c \
	$(ROOT)/third_party/FreeRTOS-Kernel/queue.c \
	$(ROOT)/third_party/FreeRTOS-Kernel/portable/GCC/RISC-V/port.c \
	$(ROOT)/third_party/FreeRTOS-Kernel/portable/MemMang/heap_4.c

COREMARK_SRC := \
	$(ROOT)/third_party/coremark/core_list_join.c \
	$(ROOT)/third_party/coremark/core_main.c \
	$(ROOT)/third_party/coremark/core_matrix.c \
	$(ROOT)/third_party/coremark/core_state.c \
	$(ROOT)/third_party/coremark/core_util.c

APP_SRC := \
	$(CURDIR)/core_portme.c \
	$(CURDIR)/main.c \
	$(CURDIR)/platform.c \
	$(CURDIR)/startup.S \
	$(ROOT)/third_party/FreeRTOS-Kernel/portable/GCC/RISC-V/portASM.S

APP_OBJS := $(addprefix $(BUILD)/,$(notdir $(APP_SRC:.c=.o)))
APP_OBJS := $(APP_OBJS:.S=.o)
FREERTOS_OBJS := $(addprefix $(BUILD)/,$(notdir $(FREERTOS_SRC:.c=.o)))
COREMARK_OBJS := $(addprefix $(BUILD)/,$(notdir $(COREMARK_SRC:.c=.o)))
OBJS := $(APP_OBJS) $(FREERTOS_OBJS) $(COREMARK_OBJS)

all: $(BUILD)/freertos_coremark.mem

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/core_main.o: CPPFLAGS += -Dmain=coremark_main

$(BUILD)/%.o: $(CURDIR)/%.c | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD)/%.o: $(CURDIR)/%.S | $(BUILD)
	$(CC) $(CPPFLAGS) $(ASFLAGS) -c $< -o $@

$(BUILD)/%.o: $(ROOT)/third_party/FreeRTOS-Kernel/%.c | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD)/%.o: $(ROOT)/third_party/FreeRTOS-Kernel/portable/GCC/RISC-V/%.c | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD)/%.o: $(ROOT)/third_party/FreeRTOS-Kernel/portable/GCC/RISC-V/%.S | $(BUILD)
	$(CC) $(CPPFLAGS) $(ASFLAGS) -c $< -o $@

$(BUILD)/%.o: $(ROOT)/third_party/FreeRTOS-Kernel/portable/MemMang/%.c | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD)/%.o: $(ROOT)/third_party/coremark/%.c | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD)/freertos_coremark.elf: $(OBJS)
	$(CC) $(LDFLAGS) $^ $(LDLIBS) -o $@
	$(OBJDUMP) -d $@ > $(BUILD)/freertos_coremark.disasm
	$(OBJCOPY) -O binary $@ $(BUILD)/freertos_coremark.bin

$(BUILD)/freertos_coremark.mem: $(BUILD)/freertos_coremark.elf $(ROOT)/tools/elf_to_mem.py
	python3 $(ROOT)/tools/elf_to_mem.py $(BUILD)/freertos_coremark.bin $@

zybo:
	$(MAKE) BOARD=zybo all
	cp $(CURDIR)/build-zybo/freertos_coremark.mem $(ROOT)/board/zybo/coremark.mem

clean:
	rm -rf $(CURDIR)/build $(CURDIR)/build-zybo

.PHONY: all zybo clean