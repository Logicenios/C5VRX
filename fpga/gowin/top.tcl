# Gowin EDA (Education) command-line build of the main design, for comparison with the
# open-source flow. Run from fpga/:  tools/gowin.sh gowin/top.tcl
# The open flow's signed-multiply techmap (tools/smul_map.v) is Yosys-only and not used here.
set_device GW2AR-LV18QN88C8/I7 -device_version C
set_option -top_module top
set_option -verilog_std sysv2017
set_option -include_path {rtl/out}
set_option -output_base_name top
# link_d[2], [3], [6] (pins 56, 54, 55) are SSPI dual-purpose pins
set_option -use_sspi_as_gpio 1
foreach f {
    rtl/top.v rtl/clocks/clk_gen.v rtl/clocks/pll_tmds_60.v
    rtl/hdmi/tmds_encoder.v rtl/hdmi/hdmi_tx.v rtl/hdmi/hdmi_phy.v
    rtl/dsp/fm_frontend.v rtl/dsp/video_timing.v rtl/dsp/chroma_dec.v rtl/dsp/test_src.v
    rtl/fb/fb_format.v rtl/fb/fb_ctrl.v rtl/mem/async_fifo.v rtl/mem/sdram_ctrl.v
    rtl/out/out_path.v rtl/osd/osd.v rtl/soc/soc.v rtl/soc/uart.v rtl/soc/cdc_bus.v
    rtl/link/link_mon.v rtl/link/link_cap.v third_party/picorv32/picorv32.v
} { add_file $f }
add_file gowin/tangnano20k.cst
add_file gowin/tangnano20k.sdc
run all
