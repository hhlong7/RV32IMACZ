CROSS ?= riscv64-unknown-elf
CC := $(CROSS)-gcc
OBJCOPY := $(CROSS)-objcopy
OBJDUMP := $(CROSS)-objdump

ROOT := $(abspath ../..)
BUILD := $(CURDIR)/build

CFLAGS := -march=rv32imac_zicsr_zifencei -mabi=ilp32 -O2 -ffreestanding -fno-builtin -fdata-sections -ffunction-sections -Wall -Wextra -Wno-unused-parameter -msmall-data-limit=0
CPPFLAGS := \
	-I$(CURDIR) \
	-I$(ROOT)/third_party/FreeRTOS-Kernel/include \
	-I$(ROOT)/third_party/FreeRTOS-Kernel/portable/GCC/RISC-V \
	-I$(ROOT)/third_party/coremark \
	-DITERATIONS=10 \
	-DTOTAL_DATA_SIZE=2000 \
	-DPERFORMANCE_RUN=1 \
	-DMAIN_HAS_NOARGC=1
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

clean:
	rm -rf $(BUILD)

.PHONY: all clean