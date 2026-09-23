# FPGA regression: RTL against the Python host models (bit-exact) and self-checking
# testbenches. Test vectors are generated into data/ (not committed).
#
#   make            all regressions
#   make fe chroma sdram fb
#
OSS ?= $(HOME)/.local/opt/oss-cad-suite
export PATH := $(OSS)/bin:$(PATH)
IV  := iverilog -g2012 -DSIM
PY  := python3
M   := ../model
D   := data
FB_SRC := sdram_model.v ../rtl/fb/fb_ctrl.v ../rtl/mem/async_fifo.v ../rtl/mem/sdram_ctrl.v ../rtl/out/out_path.v

.PHONY: all fe chroma sdram fb clean
all: fe chroma sdram fb

$(D):
	mkdir -p $@

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

# ---- frame buffer: triple buffering, bob mapping, rate mismatch in both directions ----
fb: | $(D)
	$(IV) -o fb_ntsc50.vvp tb_fb.v $(FB_SRC)
	$(IV) -Ptb_fb.IN_PAL=1 -Ptb_fb.OUT50=0 -o fb_pal60.vvp tb_fb.v $(FB_SRC)
	vvp -n fb_ntsc50.vvp > $(D)/fb_ntsc50.log & vvp -n fb_pal60.vvp > $(D)/fb_pal60.log & wait
	grep -h '^IN ' $(D)/fb_ntsc50.log $(D)/fb_pal60.log
	grep -qx PASS $(D)/fb_ntsc50.log && grep -qx PASS $(D)/fb_pal60.log

clean:
	rm -rf $(D) *.vvp
