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

HDMI_SRC := rtl/hdmi/tmds_encoder.v rtl/hdmi/hdmi_tx.v rtl/hdmi/hdmi_phy.v
PATTERN_SRC := rtl/top_pattern.v rtl/clocks/pll_tmds_60.v $(HDMI_SRC)
TOP_SRC  := rtl/top.v rtl/clocks/pll_tmds_60.v rtl/clocks/pll_sys.v $(HDMI_SRC) \
            rtl/dsp/fm_frontend.v rtl/dsp/video_timing.v rtl/dsp/chroma_dec.v \
            rtl/fb/fb_format.v rtl/fb/fb_ctrl.v rtl/mem/async_fifo.v rtl/mem/sdram_ctrl.v \
            rtl/out/out_path.v
# Yosys 0.69 leaves $$buf cells for register bits whose low bits were trimmed (their
# input is undriven); nextpnr has no BEL for them. Tie undriven bits to 0 and map the
# buffers to wires.
POST_SYNTH := setundef -undriven -zero; techmap -map +/techmap.v t:\$$buf; opt_clean
TOP_HEX  := rtl/dsp/phase_lut.hex rtl/dsp/sin_lut.hex rtl/dsp/cos_lut.hex

.PHONY: all top prog-top pattern prog-pattern sim clean
all: top

top: $(BUILD)/top.fs

$(BUILD)/top-synth.json: $(TOP_SRC) $(TOP_HEX) Makefile | $(BUILD)
	yosys -q -l $(BUILD)/top-yosys.log -p "read_verilog -sv $(TOP_SRC); synth_gowin -top top -family gw2a; $(POST_SYNTH); write_json $@; tee -o $(BUILD)/top-stat.txt stat"

# timing: tangnano20k.sdc states the pclk / sclk / lclk periods (nextpnr does not derive
# them from the PLLs). fclk (371.25 MHz) only clocks the OSER10 serialisers.
# ireg_in_iob puts the link capture registers in the pad (fixed, minimal input delay).
$(BUILD)/top-pnr.json: $(BUILD)/top-synth.json $(CST) $(SDC)
	nextpnr-himbaechel --json $< --write $@ --device $(DEVICE) --vopt family=$(FAMILY) --vopt cst=$(CST) \
		--vopt ireg_in_iob --sdc $(SDC) --report $(BUILD)/top-report.json -l $(BUILD)/top-pnr.log

$(BUILD)/top.fs: $(BUILD)/top-pnr.json
	gowin_pack -d $(FAMILY) -o $@ $<

prog-top: $(BUILD)/top.fs
	openFPGALoader -b tangnano20k $<

pattern: $(BUILD)/pattern.fs

$(BUILD)/pattern-synth.json: $(PATTERN_SRC) | $(BUILD)
	yosys -q -l $(BUILD)/pattern-yosys.log -p "read_verilog -sv $(PATTERN_SRC); synth_gowin -top top_pattern -family gw2a -json $@"

$(BUILD)/pattern-pnr.json: $(BUILD)/pattern-synth.json $(CST)
	nextpnr-himbaechel --json $< --write $@ --device $(DEVICE) --vopt family=$(FAMILY) --vopt cst=$(CST) \
		--report $(BUILD)/pattern-report.json -l $(BUILD)/pattern-pnr.log

$(BUILD)/pattern.fs: $(BUILD)/pattern-pnr.json
	gowin_pack -d $(FAMILY) -o $@ $<

prog-pattern: $(BUILD)/pattern.fs
	openFPGALoader -b tangnano20k $<

$(BUILD):
	mkdir -p $@

sim:
	$(MAKE) -C sim

clean:
	rm -rf $(BUILD)
