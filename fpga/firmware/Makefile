# Control CPU firmware (PicoRV32, RV32I). Toolchain: PlatformIO's riscv32-esp-elf GCC, which
# ships an rv32i/ilp32 multilib (override with CROSS=...). Output: build/fw.hex, one 32-bit
# word per line, padded to the RAM size, for $readmemh in rtl/soc/soc.v.
CROSS    ?= $(HOME)/.platformio/packages/toolchain-riscv32-esp/bin/riscv32-esp-elf-
CC       := $(CROSS)gcc
OBJCOPY  := $(CROSS)objcopy
SIZE     := $(CROSS)size
MEM_WORDS := 4096
CFLAGS   := -march=rv32i_zicsr_zifencei -mabi=ilp32 -Os -ffreestanding -fno-builtin -nostdlib \
            -Wall -Wextra -Wno-unused-parameter -std=gnu11 -I. -I../../src -ffunction-sections -fdata-sections
# make CLOG_AB=1: diagnostic build that alternates the burst lock (new / old) every 10 s and
# records each period (MEASUREMENTS M79); never for normal use (bands every other period)
ifeq ($(CLOG_AB),1)
CFLAGS   += -DCLOG_AB
endif
LDFLAGS  := -T link.ld -Wl,--no-warn-rwx-segments -Wl,--gc-sections -Wl,-Map,build/fw.map

build/fw.hex: build/fw.bin
	python3 -c "import sys; d=open('build/fw.bin','rb').read(); d+=b'\0'*(-len(d)%4); \
n=len(d)//4; assert n<=$(MEM_WORDS), 'firmware too big: %d words' % n; \
w=[int.from_bytes(d[4*i:4*i+4],'little') for i in range(n)]+[0]*($(MEM_WORDS)-n); \
open('$@','w').write(''.join('%08x\n'%x for x in w)); print('fw: %d of $(MEM_WORDS) words' % n)"

build/fw.bin: build/fw.elf
	$(OBJCOPY) -O binary $< $@

build/fw.elf: start.S main.c hw.h link.ld ../../src/link_proto.h | build
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ start.S main.c -lgcc
	$(SIZE) $@

build:
	mkdir -p $@

clean:
	rm -rf build
