# Control CPU firmware (PicoRV32, RV32I). Toolchain: PlatformIO's riscv32-esp-elf GCC, which
# ships an rv32i/ilp32 multilib (override with CROSS=...). Output: build/fw.hex, one 32-bit
# word per line, padded to the RAM size, for $readmemh in rtl/soc/soc.v.
CROSS    ?= $(HOME)/.platformio/packages/toolchain-riscv32-esp/bin/riscv32-esp-elf-
CC       := $(CROSS)gcc
OBJCOPY  := $(CROSS)objcopy
SIZE     := $(CROSS)size
NM       := $(CROSS)nm
MEM_WORDS := 4096
CFLAGS   := -march=rv32i_zicsr_zifencei -mabi=ilp32 -Os -msave-restore -ffreestanding -fno-builtin -nostdlib \
            -Wall -Wextra -Wno-unused-parameter -std=gnu11 -I. -I../../src -ffunction-sections -fdata-sections
# Diagnostic recorders that stream over the link, left out of normal builds (they cost RAM and
# block the main loop while sending):
#   make DIAG_CAPTURE=1: raw link capture every 20 s (fpga/bringup/link_sniff.py --capture)
#   make DIAG_CLOG=1:    colour-lock log every 10 s (link_sniff.py --clog, MEASUREMENTS M79)
#   make CLOG_AB=1:      DIAG_CLOG, alternating the burst lock (new / old) every 10 s; never for
#                        normal use (bands every other period)
ifeq ($(DIAG_CAPTURE),1)
CFLAGS   += -DDIAG_CAPTURE
endif
ifeq ($(CLOG_AB),1)
CFLAGS   += -DCLOG_AB -DDIAG_CLOG
else ifeq ($(DIAG_CLOG),1)
CFLAGS   += -DDIAG_CLOG
endif
LDFLAGS  := -T link.ld -Wl,--no-warn-rwx-segments -Wl,--gc-sections -Wl,-Map,build/fw.map

build/fw.hex: build/fw.bin
	python3 -c "import sys; d=open('build/fw.bin','rb').read(); d+=b'\0'*(-len(d)%4); \
n=len(d)//4; assert n<=$(MEM_WORDS), 'firmware too big: %d words' % n; \
w=[int.from_bytes(d[4*i:4*i+4],'little') for i in range(n)]+[0]*($(MEM_WORDS)-n); \
open('$@','w').write(''.join('%08x\n'%x for x in w)); print('fw: %d of $(MEM_WORDS) words' % n)"

build/fw.bin: build/fw.elf
	$(OBJCOPY) -O binary $< $@

# the flags are a dependency too: switching DIAG / CLOG_AB rebuilds instead of reusing a stale image
build/cflags: FORCE | build
	@echo '$(CFLAGS)' | cmp -s - $@ || echo '$(CFLAGS)' > $@

build/fw.elf: start.S main.c hw.h link.ld ../../src/link_proto.h build/cflags | build
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ start.S main.c -lgcc
	$(SIZE) $@
	@$(NM) $@ | awk '/ __ram_used$$/ { printf "RAM: %d of 15680 bytes used (code, data, bss; the top 704 are the stack)\n", strtonum("0x" $$1) }'

build:
	mkdir -p $@

clean:
	rm -rf build

FORCE:
.PHONY: clean FORCE
