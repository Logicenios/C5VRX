# FPGA regression: RTL against the Python host models (bit-exact) and self-checking
# testbenches. Test vectors are generated into data/ (not committed).
#
#   make quick      every block once, ~3 min on 8 cores (use this while iterating)
#   make            all configurations incl. the RF -> pixel full chain, ~6 min
#   make fe chroma sdram uart fb scaler soc full
#
# Long testbenches run under Verilator (--binary --timing): 30-70x faster than Icarus
# (e.g. the control-CPU test: 60 s instead of ~90 min). Icarus stays for the short
# bit-exact DSP tests.
OSS ?= $(HOME)/.local/opt/oss-cad-suite
export PATH := $(OSS)/bin:$(PATH)
IV  := iverilog -g2012 -DSIM
PY  := python3
M   := ../model
D   := data
FB_SRC := sdram_model.v ../rtl/fb/fb_ctrl.v ../rtl/mem/async_fifo.v ../rtl/mem/sdram_ctrl.v ../rtl/out/out_path.v
VL     := verilator --binary --timing -j $(shell nproc) -O3 -Wno-fatal -Wno-lint -Wno-style -DSIM -I../rtl/out
# vl_run <name> <top> <verilator args> <sources>: build into vobj/<name> and run, log to data/<name>.log
define vl_run
	$(VL) --top-module $(2) $(3) --Mdir vobj/$(1) $(4) > vobj/$(1).build.log 2>&1 || (tail -20 vobj/$(1).build.log; false)
	./vobj/$(1)/V$(2) > $(D)/$(1).log 2>&1
endef

.PHONY: all quick soc-faults fe chroma sdram uart clkgen linkmon real fb fb-quick fb-short scaler scaler-quick soc full testsrc clean
all: fe chroma sdram uart clkgen linkmon real fb fb-short scaler soc soc-faults full testsrc
quick: fe chroma sdram uart clkgen linkmon real fb-quick scaler-quick soc testsrc

$(D):
	mkdir -p $@ vobj

# ---- synthetic FM I/Q (model/iqsynth.py) ----
$(D)/ntsc_bars.hex: | $(D)
	cd .. && $(PY) model/iqsynth.py --std ntsc --seconds 0.0021 --out sim/$(D)/ntsc_bars
$(D)/weak.hex: | $(D)
	cd .. && $(PY) model/iqsynth.py --std pal --seconds 0.0021 --radius 110 --noise 45 --seed 7 --out sim/$(D)/weak
$(D)/ntsc_field.hex: | $(D)
	cd .. && $(PY) model/iqsynth.py --std ntsc --seconds 0.035 --out sim/$(D)/ntsc_field
$(D)/pal_field.hex: | $(D)
	cd .. && $(PY) model/iqsynth.py --std pal --seconds 0.035 --out sim/$(D)/pal_field

# ---- FM front end: bit-exact vs model/ref.py (strong NTSC and weak, clicky PAL) ----
fe: $(D)/ntsc_bars.hex $(D)/weak.hex
	$(IV) -o fe.vvp tb_fm_frontend.v ../rtl/dsp/fm_frontend.v
	vvp -n fe.vvp > /dev/null
	$(IV) -Ptb_fm_frontend.HEX='"$(D)/weak.hex"' -Ptb_fm_frontend.OUT='"$(D)/weak_fe_rtl.txt"' -o fe_weak.vvp tb_fm_frontend.v ../rtl/dsp/fm_frontend.v
	vvp -n fe_weak.vvp > /dev/null
	cd .. && $(PY) model/ref.py frontend sim/$(D)/ntsc_bars.hex sim/$(D)/ntsc_bars_fe_ref.txt
	cd .. && $(PY) model/ref.py frontend sim/$(D)/weak.hex sim/$(D)/weak_fe_ref.txt
	$(PY) cmp_prefix.py $(D)/ntsc_bars_fe_rtl.txt $(D)/ntsc_bars_fe_ref.txt
	$(PY) cmp_prefix.py $(D)/weak_fe_rtl.txt $(D)/weak_fe_ref.txt

# ---- sync/levels/resampler on one field, then chroma: bit-exact vs model/chroma_ref.py ----
$(D)/%_field_cv.txt: $(D)/%_field.hex
	$(IV) -Ptb_chain_a.HEX='"$<"' -Ptb_chain_a.OUT='"$@"' -o chain_$*.vvp tb_chain_a.v ../rtl/dsp/fm_frontend.v ../rtl/dsp/video_timing.v
	vvp -n chain_$*.vvp > $(D)/$*_chain.log
$(D)/chroma_in.txt: $(D)/ntsc_field_cv.txt
	head -n 256000 $< | awk '{print $$1, $$2}' > $@
$(D)/chroma_in_pal.txt: $(D)/pal_field_cv.txt
	head -n 256000 $< | awk '{print $$1, $$2}' > $@
chroma: $(D)/chroma_in.txt $(D)/chroma_in_pal.txt
	$(IV) -o chroma.vvp tb_chroma.v ../rtl/dsp/chroma_dec.v && vvp -n chroma.vvp > /dev/null
	$(IV) -Ptb_chroma.COMB=0 -Ptb_chroma.OUT='"$(D)/chroma_rtl_notch.txt"' -o chroma_n.vvp tb_chroma.v ../rtl/dsp/chroma_dec.v && vvp -n chroma_n.vvp > /dev/null
	$(IV) -Ptb_chroma_pal.IN='"$(D)/chroma_in_pal.txt"' -Ptb_chroma_pal.OUT='"$(D)/chroma_rtl_pal.txt"' -o chroma_p.vvp tb_chroma_pal.v ../rtl/dsp/chroma_dec.v && vvp -n chroma_p.vvp > /dev/null
	cd .. && $(PY) model/chroma_ref.py decode sim/$(D)/chroma_in.txt sim/$(D)/chroma_ref.txt
	cd .. && $(PY) model/chroma_ref.py decode sim/$(D)/chroma_in.txt sim/$(D)/chroma_ref_notch.txt ntsc notch
	cd .. && $(PY) model/chroma_ref.py decode sim/$(D)/chroma_in_pal.txt sim/$(D)/chroma_ref_pal.txt pal
	$(PY) cmp_prefix.py $(D)/chroma_rtl.txt $(D)/chroma_ref.txt
	$(PY) cmp_prefix.py $(D)/chroma_rtl_notch.txt $(D)/chroma_ref_notch.txt
	$(PY) cmp_prefix.py $(D)/chroma_rtl_pal.txt $(D)/chroma_ref_pal.txt

# ---- SDRAM controller vs behavioural model (protocol + data) ----
sdram:
	$(IV) -o sdram.vvp tb_sdram.v sdram_model.v ../rtl/mem/sdram_ctrl.v
	vvp -n sdram.vvp | tee $(D)/sdram.log | tail -n 1
	grep -q ' 0 mismatches, model errors 0' $(D)/sdram.log

# ---- UART loopback (1 Mbaud from 27 MHz, back-to-back bytes) ----
uart: | $(D)
	$(IV) -o uart.vvp tb_uart.v ../rtl/soc/uart.v
	vvp -n uart.vvp | tee $(D)/uart.log | grep tb_uart
	grep -q PASS $(D)/uart.log

# ---- clk_gen: PLL LOCK debouncing against a chattering-LOCK rPLL model ----
clkgen: | $(D)
	$(IV) -o clkgen.vvp tb_clkgen.v ../rtl/clocks/clk_gen.v
	vvp -n clkgen.vvp | tee $(D)/clkgen.log | grep tb_clkgen
	grep -q PASS $(D)/clkgen.log

# ---- link monitor: edge-placement statistic mid-eye vs on the data transitions ----
linkmon: | $(D)
	$(IV) -Ptb_link_mon.PHASE_PS=6250 -o lm_eye.vvp tb_link_mon.v ../rtl/link/link_mon.v
	$(IV) -Ptb_link_mon.PHASE_PS=12200 -Ptb_link_mon.EXPECT_BAD=1 -o lm_edge.vvp tb_link_mon.v ../rtl/link/link_mon.v
	vvp -n lm_eye.vvp | tee $(D)/linkmon.log | grep tb_link_mon
	vvp -n lm_edge.vvp | tee -a $(D)/linkmon.log | grep tb_link_mon
	[ $$(grep -c PASS $(D)/linkmon.log) -eq 2 ]

# ---- recorded Tank II PAL signal (vectors/README.md): fm_frontend + video_timing must lock ----
real: | $(D)
	$(PY) -c "b=[l for l in open('vectors/tank2_pal_10lines.hex') if l.strip()]; open('$(D)/tank2_x5.hex','w').write(''.join(b*5))"
	$(IV) -Ptb_chain_a.N=128000 -Ptb_chain_a.HEX='"$(D)/tank2_x5.hex"' -Ptb_chain_a.OUT='"$(D)/tank2_cv.txt"' \
	  -o real.vvp tb_chain_a.v ../rtl/dsp/fm_frontend.v ../rtl/dsp/video_timing.v
	vvp -n real.vvp | tee $(D)/real.log | grep '^end'
	grep -q 'locked=1 pal=1' $(D)/real.log

# ---- frame buffer: field buffering, no tearing, tap lines, rate mismatch both ways ----
FB_CFG := n50b:-GWEAVE=0 n50w:-GWEAVE=1 p60b:-GIN_PAL=1+-GOUT50=0 p60w:-GIN_PAL=1+-GOUT50=0+-GWEAVE=1
fb: | $(D)
	for c in $(FB_CFG); do n=$${c%%:*}; a=$$(echo $${c#*:} | tr + ' '); \
	  ( $(VL) --top-module tb_fb $$a --Mdir vobj/fb_$$n tb_fb.v $(FB_SRC) > vobj/fb_$$n.build.log 2>&1 && \
	    ./vobj/fb_$$n/Vtb_fb > $(D)/fb_$$n.log 2>&1 ) & done; wait
	grep -h '^IN ' $(D)/fb_*.log
	for c in $(FB_CFG); do grep -qx PASS $(D)/fb_$${c%%:*}.log || exit 1; done
fb-quick: | $(D)
	$(call vl_run,fb_p60w,tb_fb,-GIN_PAL=1 -GOUT50=0 -GWEAVE=1,tb_fb.v $(FB_SRC))
	grep '^IN ' $(D)/fb_p60w.log && grep -qx PASS $(D)/fb_p60w.log

# ---- short lines (a real line cut early): fb_ctrl must keep publishing fields. 296 words (a
# multiple of 8) put the next descriptor at the FIFO head on a burst boundary, which wedged the
# writer before the fix (MEASUREMENTS M71); 300 words make a burst swallow the descriptor ----
fb-short: | $(D)
	$(call vl_run,fb_short296,tb_fb,-GIN_PAL=1 -GOUT50=1 -GSHORT=296,tb_fb.v $(FB_SRC))
	$(call vl_run,fb_short300,tb_fb,-GIN_PAL=1 -GOUT50=1 -GSHORT=300,tb_fb.v $(FB_SRC))
	grep -h '^SHORT' $(D)/fb_short296.log $(D)/fb_short300.log
	grep -qx PASS $(D)/fb_short296.log && grep -qx PASS $(D)/fb_short300.log

# ---- internal test source (menu "Test pattern") through fb_format: line/field structure, bar codes ----
testsrc: | $(D)
	$(call vl_run,testsrc,tb_testsrc,,tb_testsrc.v ../rtl/dsp/test_src.v ../rtl/fb/fb_format.v)
	grep tb_testsrc $(D)/testsrc.log && grep -q PASS $(D)/testsrc.log

# ---- output path: deinterlace + 4-tap scaler + RGB vs model/scaler_ref.py, bit-exact ----
# config PAL_WEAVE_ASPECT_CAPTURE; c5 captures an even newest field (PAL)
SC_CFG := 1_0_0_4 1_1_1_4 0_0_1_4 0_1_0_4 1_0_0_5
define sc_one
	set -- $$(echo $(1) | tr _ ' '); n=sc_p$$1w$$2a$$3c$$4; \
	$(VL) --top-module tb_scaler -GPAL=$$1 -GWEAVE=$$2 -GASPECT=$$3 -GCAPTURE=$$4 -GOUT='"$(D)/'$$n'.txt"' \
	  --Mdir vobj/$$n tb_scaler.v $(FB_SRC) > vobj/$$n.build.log 2>&1 && ./vobj/$$n/Vtb_scaler > $(D)/$$n.log 2>&1 && \
	(cd ../model && $(PY) scaler_ref.py compare x ../sim/$(D)/$$n.txt ../sim/$(D)/$$n $$(grep META ../sim/$(D)/$$n.log | cut -d' ' -f2-))
endef
scaler: | $(D)
	$(PY) ../model/scaler_ref.py pattern $(D)/scaler_fields.hex
	for c in $(SC_CFG); do ( $(call sc_one,$$c) ) > $(D)/sc_$$c.result 2>&1 & done; wait
	cat $(D)/sc_*.result | grep -E 'PASS|FAIL'
	! grep -q FAIL $(D)/sc_*.result && [ $$(cat $(D)/sc_*.result | grep -c PASS) -eq $(words $(SC_CFG)) ]
scaler-quick: | $(D)
	$(PY) ../model/scaler_ref.py pattern $(D)/scaler_fields.hex
	$(call sc_one,1_1_1_4)

# ---- control CPU + firmware against a scripted C5, button presses and the wiring test ----
# soc: correct wiring. soc-faults: D2<->D5 swapped, D3 open, STROBE open (expected fault masks).
SOC_SRC := tb_soc.v ../rtl/soc/soc.v ../rtl/soc/uart.v ../third_party/picorv32/picorv32.v
define soc_one
	$(VL) --top-module tb_soc -GWFAULT=$(1) -GTXLOG='"$(D)/soc_w$(1).txt"' --Mdir vobj/soc_w$(1) $(SOC_SRC) \
	  > vobj/soc_w$(1).build.log 2>&1 || (tail -20 vobj/soc_w$(1).build.log; false)
	./vobj/soc_w$(1)/Vtb_soc > $(D)/soc_w$(1).log 2>&1
	cp $(D)/soc_w$(1).txt $(D)/soc_tx.txt && $(PY) check_soc.py $(2)
endef
soc: | $(D)
	$(MAKE) -C ../firmware
	$(PY) soc_stimulus.py $(D)/soc_rx.hex
	$(call soc_one,0,0x000)
soc-faults: soc
	$(call soc_one,1,0x024)
	$(call soc_one,2,0x008)
	$(call soc_one,3,0x100)

# ---- full chain RF -> pixels (75 % bars through FM), vs model/chain_ref.py ----
FULL_SRC := sdram_model.v ../rtl/dsp/fm_frontend.v ../rtl/dsp/video_timing.v ../rtl/dsp/chroma_dec.v \
            ../rtl/fb/fb_format.v ../rtl/fb/fb_ctrl.v ../rtl/mem/async_fifo.v ../rtl/mem/sdram_ctrl.v ../rtl/out/out_path.v
full: | $(D)
	for s in ntsc pal; do P=0; [ $$s = pal ] && P=1; ( \
	  $(PY) ../model/iqsynth.py --std $$s --seconds 0.12 --out $(D)/full_$$s > /dev/null && \
	  $(VL) --top-module tb_full -GN=4800000 -GPAL=$$P -GHEX='"$(D)/full_'$$s'.hex"' \
	    -GCV_OUT='"$(D)/full_'$$s'_cv.txt"' -GOUT='"$(D)/full_'$$s'_rgb.txt"' --Mdir vobj/full_$$s tb_full.v $(FULL_SRC) \
	    > vobj/full_$$s.build.log 2>&1 && ./vobj/full_$$s/Vtb_full > $(D)/full_$$s.log 2>&1 ) & done; wait
	for s in ntsc pal; do (cd ../model && $(PY) chain_ref.py ../sim/$(D)/full_$${s}_cv.txt ../sim/$(D)/full_$${s}_rgb.txt \
	  ../sim/$(D)/full_$$s.log ../sim/$(D)/full_$$s) || exit 1; done

clean:
	rm -rf $(D) *.vvp vobj
