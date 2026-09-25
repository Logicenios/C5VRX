# C5VRX FPGA build (Sipeed Tang Nano 20K, GW2AR-18) with the open-source flow:
# yosys (synth_gowin) -> nextpnr-himbaechel -> gowin_pack (apicula) -> openFPGALoader.
# Toolchain: OSS CAD Suite 2026-09-23 (fpga/README.md).
#
#   make top                full receiver bitstream (link -> decode -> SDRAM -> 720p)
#   make prog-top           load it to SRAM (volatile)
#   make pattern            720p HDMI colour-bar bring-up bitstream
#   make prog-pattern       load it to SRAM (volatile)
#   make sim                run the testbenches
#
OSS      ?= $(HOME)/.local/opt/oss-cad-suite
export PATH := $(OSS)/bin:$(PATH)

DEVICE   := GW2AR-LV18QN88C8/I7
FAMILY   := GW2A-18C
CST      := tangnano20k.cst
SDC      := tangnano20k.sdc
BUILD    := build
NPROC    ?= $(shell nproc)

HDMI_SRC := rtl/hdmi/tmds_encoder.v rtl/hdmi/hdmi_tx.v rtl/hdmi/hdmi_phy.v
PATTERN_SRC := rtl/top_pattern.v rtl/clocks/pll_tmds_60.v $(HDMI_SRC)
TOP_SRC  := rtl/top.v rtl/clocks/clk_gen.v rtl/clocks/pll_tmds_60.v $(HDMI_SRC) \
            rtl/dsp/fm_frontend.v rtl/dsp/video_timing.v rtl/dsp/chroma_dec.v rtl/dsp/test_src.v \
            rtl/fb/fb_format.v rtl/fb/fb_ctrl.v rtl/mem/async_fifo.v rtl/mem/sdram_ctrl.v \
            rtl/out/out_path.v rtl/osd/osd.v rtl/soc/soc.v rtl/soc/uart.v rtl/soc/cdc_bus.v rtl/link/link_mon.v rtl/link/link_cap.v \
            third_party/picorv32/picorv32.v
# Yosys 0.69 leaves $$buf cells for register bits whose low bits were trimmed (their
# input is undriven); nextpnr has no BEL for them. Tie undriven bits to 0 and map the
# buffers to wires.
POST_SYNTH := setundef -undriven -zero; techmap -map +/techmap.v t:\$$buf; opt_clean
# Signed DSP multiplies return wrong products with this flow (MEASUREMENTS M68): rewrite every
# signed $$mul as an unsigned multiply plus sign corrections before synthesis (tools/smul_map.v).
PRE_SYNTH := read_verilog -lib -specify +/gowin/cells_sim.v +/gowin/cells_xtra_gw2a.v; hierarchy -top top; proc; flatten; opt; wreduce; opt_clean; techmap -map tools/smul_map.v t:\$$mul; opt
TOP_HEX  := rtl/dsp/phase_lut.hex rtl/dsp/sin_lut.hex rtl/dsp/cos_lut.hex rtl/out/cr_coef.vh \
            rtl/osd/font.hex firmware/build/fw.hex

.PHONY: all top prog-top pattern prog-pattern sim sim-quick lint clean
all: top

top: $(BUILD)/top.fs

$(BUILD)/top-synth.json: $(TOP_SRC) $(TOP_HEX) tools/smul_map.v | $(BUILD)
	yosys -q -l $(BUILD)/top-yosys.log -p "read_verilog -sv $(if $(SINGLE_PLL),-DSINGLE_PLL) -I rtl/out $(TOP_SRC); $(PRE_SYNTH); synth_gowin -top top -family gw2a; $(POST_SYNTH); write_json $@; tee -o $(BUILD)/top-stat.txt stat"

# timing: tangnano20k.sdc states the pclk / sclk / lclk periods (nextpnr does not derive
# them from the PLLs). fclk (371.25 MHz) only clocks the OSER10 serialisers.
# Do not use --vopt ireg_in_iob: pad input registers read a constant 0 (MEASUREMENTS M61).
# --threads + router2: placer ~180 s (was ~306 s), router ~25 s (was 127 s). The Gowin global/
# segment routing pass (~290 s) has no option to skip, so a full place-and-route is ~10 min:
# run `make lint` and the simulations first.
# Seeds: with the DSP blocks ~90 % full (the scaler's 9x9 multipliers), the HeAP legaliser often
# cannot place a MULT9X9 and, with the default attempt limit (cells^2 / 8 ~ 1e8), spins for
# hours. A timeout of 20000 makes such a seed fail within seconds naming the cell, and the next
# seed is tried. The `static` placer is not supported for Gowin and `sa` crashes.
PNR_SEEDS ?= 1 7 2 3 4 5
$(BUILD)/top-pnr.json: $(BUILD)/top-synth.json $(CST) $(SDC)
	@for s in $(PNR_SEEDS); do \
	  echo "place-and-route: seed $$s"; \
	  nextpnr-himbaechel --json $< --write $@ --device $(DEVICE) --vopt family=$(FAMILY) --vopt cst=$(CST) \
	    --sdc $(SDC) --threads $(NPROC) --router router2 --seed $$s --placer-heap-cell-placement-timeout 20000 \
	    $(PNR_OPTS) --report $(BUILD)/top-report.json -l $(BUILD)/top-pnr.log > /dev/null 2>&1 && exit 0; \
	  grep -m1 '^ERROR' $(BUILD)/top-pnr.log; \
	done; echo "place-and-route failed for seeds $(PNR_SEEDS)"; exit 1

$(BUILD)/top.fs: $(BUILD)/top-pnr.json
	gowin_pack -d $(FAMILY) -o $@ $<

# prog-* only load an existing bitstream (seconds); they never start a rebuild
prog-top:
	@test -f $(BUILD)/top.fs || { echo "no $(BUILD)/top.fs: run 'make top' first"; exit 1; }
	openFPGALoader -b tangnano20k $(BUILD)/top.fs

pattern: $(BUILD)/pattern.fs

$(BUILD)/pattern-synth.json: $(PATTERN_SRC) | $(BUILD)
	yosys -q -l $(BUILD)/pattern-yosys.log -p "read_verilog -sv $(PATTERN_SRC); synth_gowin -top top_pattern -family gw2a -json $@"

$(BUILD)/pattern-pnr.json: $(BUILD)/pattern-synth.json $(CST)
	nextpnr-himbaechel --json $< --write $@ --device $(DEVICE) --vopt family=$(FAMILY) --vopt cst=$(CST) \
		--report $(BUILD)/pattern-report.json -l $(BUILD)/pattern-pnr.log

$(BUILD)/pattern.fs: $(BUILD)/pattern-pnr.json
	gowin_pack -d $(FAMILY) -o $@ $<

prog-pattern:
	@test -f $(BUILD)/pattern.fs || { echo "no $(BUILD)/pattern.fs: run 'make pattern' first"; exit 1; }
	openFPGALoader -b tangnano20k $(BUILD)/pattern.fs

firmware/build/fw.hex: firmware/*.c firmware/*.h firmware/*.S firmware/link.ld ../src/link_proto.h
	$(MAKE) -C firmware

rtl/out/cr_coef.vh: model/scaler_coef.py
	python3 model/scaler_coef.py

rtl/osd/font.hex: model/font_rom.py third_party/spleen/spleen-8x16.bdf
	python3 model/font_rom.py

$(BUILD):
	mkdir -p $@

# seconds: Verilator lint of the whole top level; run it before starting a place-and-route
lint: firmware/build/fw.hex rtl/out/cr_coef.vh rtl/osd/font.hex
	verilator --lint-only -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
		-Wno-PINCONNECTEMPTY -Wno-GENUNNAMED -Wno-VARHIDDEN -Irtl/out --top-module top \
		$(TOP_SRC) sim/gowin_prims.v 2>&1 | grep -E '%(Error|Warning-(CASEINCOMPLETE|LATCH|MULTIDRIVEN|UNDRIVEN|BLKSEQ|COMBDLY))' | grep -v third_party | head -40; true

sim:
	$(MAKE) -C sim

sim-quick:
	$(MAKE) -C sim quick

clean:
	rm -rf $(BUILD)
