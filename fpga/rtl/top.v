// C5VRX FPGA top (Sipeed Tang Nano 20K): C5 sample link -> FM demod -> sync/levels ->
// colour decode -> SDRAM field store -> deinterlace + 4-tap scaler -> OSD -> 720p HDMI.
//
// Clock domains
//   clk27  crystal: control CPU (menu, C5 UART link), output-rate selection, clk_gen control.
//          Never reset by a rate change, so the menu state survives it.
//   lclk   link STROBE, 40 MHz from the C5 (PARLIO RX clock out, docs/FPGA_LINK.md §2):
//          capture, FM demod, sync/levels, chroma, fb_format.
//   pclk   74.25 / 74.176 MHz (clk_gen: cascaded, run-time retuned rPLLs, MEASUREMENTS M58/M59):
//          SDRAM (CL 2, read latency 4: M60), fb_ctrl, out_path, OSD, HDMI; fclk = 5 x pclk.
// Crossings: async_fifo (lclk -> pclk), cdc_bus for settings/status, dual-clock OSD text RAM.
`default_nettype none
module top (
    input  wire       clk27,
    input  wire       btn_s1,         // high when pressed
    input  wire       btn_s2,
    output wire [5:0] led,            // active low
    // C5 sample link: link_d[k] = PARLIO RX data bit k = C5 GPIO BOARD_IQ_PINS[k]
    // (byte = {I[3:0], Q[3:0]}), sampled on the rising STROBE edge like the C5 itself
    input  wire       link_strobe,
    input  wire [7:0] link_d,
    input  wire       link_rx,        // C5 UART1 TX (GPIO11)
    output wire       link_tx,        // C5 UART1 RX (GPIO12), idle high
    output wire       dbg_tx,         // copy of link_tx on the BL616 USB-UART (host /dev/ttyUSB1, 1 Mbaud)
    // HDMI
    output wire       tmds_clk_p, tmds_clk_n,
    output wire [2:0] tmds_d_p, tmds_d_n,
    // embedded SDRAM
    output wire        O_sdram_clk,
    output wire        O_sdram_cke,
    output wire        O_sdram_cs_n,
    output wire        O_sdram_cas_n,
    output wire        O_sdram_ras_n,
    output wire        O_sdram_wen_n,
    output wire [3:0]  O_sdram_dqm,
    output wire [10:0] O_sdram_addr,
    output wire [1:0]  O_sdram_ba,
    inout  wire [31:0] IO_sdram_dq
);
    // ================================================================== clk27: control
    wire [31:0] set0, set1, set2, osd_ctrl, status, counters;
    wire [31:0] tip32, blank32, debug;
    wire [7:0]  drops_a, drops_b, ovf_k, fbd_k, fb_dbg;   // diagnostics register 0x3000_0048
    wire [31:0] link_raw, link_freq, link_errp, link_errn, link_bits;
    wire        cap_req, cap_done_l; wire [10:0] cap_addr; wire [15:0] cap_data;
    reg  [1:0]  cap_done_s = 0;
    always @(posedge clk27) cap_done_s <= {cap_done_s[0], cap_done_l};
    wire        cap_done_k = cap_done_s[1];
    wire        clog_req, clog_done_l; wire [8:0] clog_addr; wire [31:0] clog_data;   // colour-lock recorder
    reg  [1:0]  clog_done_s = 0;
    always @(posedge clk27) clog_done_s <= {clog_done_s[0], clog_done_l};
    wire        osd_we; wire [9:0] osd_waddr; wire [15:0] osd_wdata;
    reg  [3:0]  cpu_rst_cnt = 4'hF;
    always @(posedge clk27) if (cpu_rst_cnt != 0) cpu_rst_cnt <= cpu_rst_cnt - 4'd1;
    soc u_soc (
        .clk(clk27), .resetn(cpu_rst_cnt == 0), .uart_tx(link_tx), .uart_rx(link_rx),
        .osd_we(osd_we), .osd_waddr(osd_waddr), .osd_wdata(osd_wdata),
        .status(status), .meas_tip(tip32), .meas_blank(blank32), .counters(counters), .debug(debug),
        .link_raw(link_raw), .link_freq(link_freq), .link_errp(link_errp), .link_errn(link_errn), .link_bits(link_bits),
        .cap_req(cap_req), .cap_done(cap_done_k), .cap_addr(cap_addr), .cap_data(cap_data),
        .clog_req(clog_req), .clog_done(clog_done_s[1]), .clog_addr(clog_addr), .clog_data(clog_data),
        .vt_dbg({8'd0, vt_dbg_k}), .vt_pulses({br_k, hs_k}), .diag({drops_a, drops_b, ovf_k, fbd_k}),
        .settings0(set0), .settings1(set1), .settings2(set2), .osd_ctrl(osd_ctrl));

    // output-rate selection: Force 60, or follow the (effective) standard once it has been
    // stable for 0.5 s while video_timing is locked (plan Phase 4: only switch on a real change);
    // a standard forced in the menu applies without lock
    wire [1:0] std_mode = set0[1:0];
    wire       force60  = set0[2];
    wire       vlocked_k, pal_det_k;
    wire [1:0] mode_cur;
    reg  [1:0] mode_req = 2'd0;
    reg  [23:0] hyst = 0;
    wire pal_eff_k = (std_mode == 2'd1) ? 1'b0 : (std_mode == 2'd2) ? 1'b1 : pal_det_k;
    wire [1:0] mode_want = force60 ? 2'd0 : (pal_eff_k ? 2'd2 : 2'd1);
    always @(posedge clk27) begin
        if (force60) begin mode_req <= 2'd0; hyst <= 0; end
        else if ((vlocked_k || std_mode != 2'd0) && mode_want != mode_req) begin
            if (hyst == 24'd13_500_000) begin mode_req <= mode_want; hyst <= 0; end
            else hyst <= hyst + 24'd1;
        end else hyst <= 0;
    end

    wire fclk, pclk, plocked;
    wire [7:0] clk_restarts; wire [1:0] clk_cause;
`ifdef SINGLE_PLL
    // EXPERIMENT (make SINGLE_PLL=1): pixel clock from one rPLL fed by the crystal pin, as in the
    // colour-bar bitstream (27 x 55/4 = 371.25 MHz, 74.25 MHz pixel clock). 60 and 50 Hz only
    // (both use 74.25 MHz); 59.94 needs the cascade and is output with 60 Hz timing here.
    wire sp_lock;
    pll_tmds_60 u_pll1 (.clock_in(clk27), .clock_out(fclk), .locked(sp_lock));
    CLKDIV #(.DIV_MODE("5")) u_div1 (.CLKOUT(pclk), .HCLKIN(fclk), .RESETN(sp_lock), .CALIB(1'b0));
    reg [1:0] sp_ls = 0;
    always @(posedge clk27) sp_ls <= {sp_ls[0], sp_lock};
    assign plocked = sp_ls[1];
    assign mode_cur = (mode_req == 2'd1) ? 2'd0 : mode_req;
    assign clk_restarts = 8'd0; assign clk_cause = 2'd0; assign drops_a = 8'd0; assign drops_b = {7'd0, ~sp_ls[1]};
`else
    clk_gen u_clk (.clk27(clk27), .mode(mode_req), .fclk(fclk), .pclk(pclk), .locked(plocked), .mode_cur(mode_cur),
                   .restarts(clk_restarts), .last_cause(clk_cause), .drops_a(drops_a), .drops_b(drops_b));
`endif
    // debug word: {mode changes requested[7:0], restarts[7:0], cause, mode_want, mode_req, 8'd0, ...}
    reg [7:0] mode_changes = 0;
    reg [1:0] mode_req_d = 0;
    always @(posedge clk27) begin
        mode_req_d <= mode_req;
        if (mode_req_d != mode_req && mode_changes != 8'hFF) mode_changes <= mode_changes + 8'd1;
    end
    assign debug = {mode_changes, clk_restarts, 2'd0, clk_cause, mode_want, mode_req, 8'd0};

    // ================================================================== lclk: link capture only
    // Only the capture runs on the STROBE clock. Logic clocked by the asynchronous STROBE disturbed
    // the HDMI output (the capture card lost lock: 4 copies of fm_frontend on STROBE broke the
    // colour-bar bitstream, the same 4 copies on pclk did not; MEASUREMENTS M74). So each sample
    // crosses into the pixel-clock domain through a 16-entry FIFO right after capture, and the
    // receive chain runs on pclk (74.25 / 74.176 MHz) with a sample-valid enable (~54 % duty).
    // The chain is clock-rate independent: sim/tb_full GAP=1 gives a bit-identical frame.
    wire lclk = link_strobe;
    reg [24:0] win_cnt = 0; reg win_tog = 0;           // 1 s windows from the crystal
    always @(posedge clk27) if (win_cnt == 25'd26_999_999) begin win_cnt <= 0; win_tog <= ~win_tog; end
                            else win_cnt <= win_cnt + 25'd1;
    reg [3:0] lrst_cnt = 4'hF;
    always @(posedge lclk) if (lrst_cnt != 0) lrst_cnt <= lrst_cnt - 4'd1;
    wire lrst = lrst_cnt != 0;

    reg [3:0] prst_cnt = 4'hF;
    always @(posedge pclk or negedge plocked)
        if (!plocked) prst_cnt <= 4'hF; else if (prst_cnt != 0) prst_cnt <= prst_cnt - 4'd1;
    wire prst = prst_cnt != 0;

    // settings into the receive (pixel-clock) domain
    wire [1:0]  std_l, deemph_l; wire oldlock_l, lpf_l, notch_l, test_l, idle_l, fmonly_l; wire [15:0] hue_l; wire [7:0] sat_l, bri_l, con_l;
    cdc_bus #(.W(50)) u_set_l (.clk(pclk), .d({set0[13], set0[12], set0[11:10], set0[9], set0[8], set0[7], set0[1:0], set0[6], set1[23:0], set2[15:0]}),
                               .q({oldlock_l, lpf_l, deemph_l, fmonly_l, idle_l, test_l, std_l, notch_l, sat_l, hue_l, con_l, bri_l}));
    // menu "Decoder" (diagnostics): Idle holds the receive DSP chain (fm_frontend, video_timing,
    // chroma_dec) in reset; FM only keeps fm_frontend running and holds the rest. Used to find
    // which block's activity disturbs the HDMI output (MEASUREMENTS M73).
    wire drst = prst | idle_l;               // fm_frontend
    wire vrst = prst | idle_l | fmonly_l;    // video_timing, chroma_dec

    // capture in fabric flip-flops. The pad input register (nextpnr --vopt ireg_in_iob) reads a
    // constant 0 with this toolchain (docs/MEASUREMENTS.md M61), so it is not used. STROBE is the
    // source-synchronous clock, so no synchroniser is needed.
    reg [7:0] iq_cap;
    always @(posedge lclk) iq_cap <= link_d;
    // STROBE -> pclk: pclk (74 MHz) reads faster than STROBE writes (40 MHz), so the FIFO stays
    // near empty; while pclk is held in reset (PLL restart) it fills and further writes are dropped
    wire lf_empty; wire [7:0] lf_data;
    async_fifo #(.WIDTH(8), .AW(4)) u_lfifo (
        .wclk(lclk), .wrst(lrst), .wr_en(1'b1), .wr_data(iq_cap), .full(), .wr_level(),
        .rclk(pclk), .rrst(prst), .rd_en(!lf_empty), .rd_data(lf_data), .empty(lf_empty), .rd_level());
    // one sample per pop; a LUT1 buffer per bit adds delay before the phase-LUT BSRAM address
    // pins, which otherwise miss hold by ~0.12 ns
    reg [7:0] iq_r; reg iq_v = 1'b0;
    always @(posedge pclk) begin iq_r <= lf_data; iq_v <= !lf_empty && !prst; end
    wire [7:0] iq;
    genvar gi;
    generate for (gi = 0; gi < 8; gi = gi + 1) begin : iq_dly
        (* keep *) LUT1 #(.INIT(2'b10)) u_buf (.F(iq[gi]), .I0(iq_r[gi]));
    end endgenerate

    wire signed [17:0] f20; wire f20_valid, click;
    fm_frontend #(.LUT_FILE("rtl/dsp/phase_lut.hex")) u_fm (
        .clk(pclk), .rst(drst), .deemph(deemph_l), .lpf(lpf_l), .iq(iq), .iq_valid(iq_v),
        .f20(f20), .f20_valid(f20_valid), .click(click));

    wire signed [11:0] cv; wire cv_valid; wire [10:0] cv_x;
    wire line_start, field_odd, field_start, pal_det, vlocked;
    wire [9:0] line_no; wire signed [17:0] meas_tip, meas_blank;
    wire signed [15:0] cv_ffp, cv_ffn;       // colour feed-forward (MEASUREMENTS M79)
    video_timing u_vt (
        .clk(pclk), .rst(vrst), .f(f20), .f_valid(f20_valid),
        .cv(cv), .cv_valid(cv_valid), .cv_x(cv_x), .line_start(line_start), .line_no(line_no),
        .field_odd(field_odd), .field_start(field_start), .is_pal(pal_det), .locked(vlocked),
        .meas_tip(meas_tip), .meas_blank(meas_blank), .dbg(vt_dbg), .hsync_pulse(vt_hs), .broad_pulse(vt_broad), .perr_q4(perr_q4),
        .cv_ff_pal(cv_ffp), .cv_ff_ntsc(cv_ffn));
    wire [23:0] vt_dbg; wire vt_hs, vt_broad;
    // per-second H sync / broad pulse counts (same 1 s windows as the link monitor)
    reg [2:0] vw = 0; reg [15:0] hs_c = 0, br_c = 0, hs_n = 0, br_n = 0;
    always @(posedge pclk) begin
        vw <= {vw[1:0], win_tog};
        if (vw[2] ^ vw[1]) begin hs_n <= hs_c; br_n <= br_c; hs_c <= 0; br_c <= 0; end
        else begin
            if (vt_hs && hs_c != 16'hFFFF) hs_c <= hs_c + 16'd1;
            if (vt_broad && br_c != 16'hFFFF) br_c <= br_c + 16'd1;
        end
    end
    // menu override of the standard (Auto uses the detected line period)
    wire is_pal = (std_l == 2'd1) ? 1'b0 : (std_l == 2'd2) ? 1'b1 : pal_det;

    wire signed [11:0] y_c; wire signed [15:0] u_c, v_c; wire [10:0] x_c;
    wire c_valid, killed, pal_sw_neg;
    wire clog_we; wire [15:0] clog_bu, clog_bv, clog_corr; wire [2:0] clog_fl; wire signed [11:0] perr_q4;
    chroma_dec #(.SIN_FILE("rtl/dsp/sin_lut.hex"), .COS_FILE("rtl/dsp/cos_lut.hex")) u_chroma (
        .clk(pclk), .rst(vrst), .cv(cv), .cv_valid(cv_valid), .cv_x(cv_x), .cv_ff_pal(cv_ffp), .cv_ff_ntsc(cv_ffn), .is_pal(is_pal),
        .comb(~notch_l), .hue(hue_l), .sat(sat_l), .lock_legacy(oldlock_l),
        .y_out(y_c), .u_out(u_c), .v_out(v_c), .x_out(x_c), .out_valid(c_valid),
        .killed(killed), .pal_sw_neg(pal_sw_neg),
        .log_we(clog_we), .log_bu(clog_bu), .log_bv(clog_bv), .log_corr(clog_corr), .log_fl(clog_fl));

    // colour-lock recorder (MEASUREMENTS M79): 256 lines of the burst loop, read by the CPU
    chroma_log u_clog (.clk(pclk), .rec_we(clog_we), .bu(clog_bu), .bv(clog_bv), .corr(clog_corr), .perr(perr_q4),
        .fl(clog_fl), .field_start(field_start), .req_tog(clog_req), .done_tog(clog_done_l),
        .rclk(clk27), .raddr(clog_addr), .rdata(clog_data));

    // menu "Test pattern": the internal PAL colour bars replace the decoder at fb_format's input
    // (the whole frame-buffer / SDRAM / scaler / HDMI path runs as with real video)
    wire signed [11:0] ts_y; wire signed [15:0] ts_u, ts_v; wire [10:0] ts_x; wire [9:0] ts_line;
    wire ts_valid, ts_odd;
    // 40 MS/s sample tick from the pixel clock (the test pattern needs no C5)
    reg [16:0] ts_acc = 0; reg ts_en = 1'b0;
    always @(posedge pclk) begin
        ts_en <= (ts_acc + 17'd40000 >= 17'd74250);
        ts_acc <= (ts_acc + 17'd40000 >= 17'd74250) ? ts_acc + 17'd40000 - 17'd74250 : ts_acc + 17'd40000;
    end
    test_src u_tsrc (.clk(pclk), .rst(prst | ~test_l), .en(ts_en), .y(ts_y), .u(ts_u), .v(ts_v), .x(ts_x),
                     .valid(ts_valid), .line(ts_line), .odd(ts_odd));

    wire [35:0] ff_wdata; wire ff_wr;
    fb_format u_fmt (
        .clk(pclk), .rst(prst),
        .y_in(test_l ? ts_y : y_c), .u_in(test_l ? ts_u : u_c), .v_in(test_l ? ts_v : v_c),
        .x_in(test_l ? ts_x : x_c), .in_valid(test_l ? ts_valid : c_valid),
        .tag_strobe(test_l ? (ts_valid && ts_x == 11'd0) : (cv_valid && cv_x == 11'd0)),
        .line_no(test_l ? ts_line : line_no), .field_odd(test_l ? ts_odd : field_odd),
        .is_pal(test_l | is_pal), .locked(test_l | vlocked),
        .brightness(bri_l), .contrast(con_l),
        .fifo_data(ff_wdata), .fifo_wr(ff_wr));

    // link monitor (docs/FPGA_LINK.md §2.3, §2.5): strobe frequency, bit activity, edge placement
    wire [25:0] lm_samples, lm_errp, lm_errn; wire [7:0] lm_seen0, lm_seen1, lm_edges;
    link_mon u_lmon (.lclk(lclk), .link_d(link_d), .dp_in(iq_cap), .win_tog(win_tog),
                     .samples(lm_samples), .err_p(lm_errp), .err_n(lm_errn),
                     .seen0(lm_seen0), .seen1(lm_seen1), .edges(lm_edges), .dn_out(lm_dn));
    wire [7:0] lm_dn;
    // raw capture for bring-up: {falling, rising} bytes of 2048 consecutive STROBE cycles
    link_cap u_lcap (.lclk(lclk), .dp(iq_cap), .dn(lm_dn), .req_tog(cap_req), .done_tog(cap_done_l),
                     .rclk(clk27), .raddr(cap_addr), .rdata(cap_data));

    reg [15:0] click_cnt = 0;
    always @(posedge pclk) if (click) click_cnt <= click_cnt + 16'd1;
    reg [23:0] lbeat = 0;
    always @(posedge lclk) lbeat <= lbeat + 24'd1;

    // ================================================================== pclk: frame buffer and output
    wire [35:0] ff_rdata; wire ff_empty, ff_full, ff_pop; wire [9:0] ff_rlevel, ff_wlevel;
    async_fifo #(.WIDTH(36), .AW(9)) u_fifo (
        .wclk(pclk), .wrst(prst), .wr_en(ff_wr), .wr_data(ff_wdata), .full(ff_full), .wr_level(ff_wlevel),
        .rclk(pclk), .rrst(prst), .rd_en(ff_pop), .rd_data(ff_rdata), .empty(ff_empty), .rd_level(ff_rlevel));

    wire sd_req, sd_we, sd_ack, sd_wd_pop, sd_rd_valid, sd_ready;
    wire [20:0] sd_addr; wire [31:0] sd_rdata;
    wire frame_evt, req, req_prev, done, busy; wire [8:0] req_line; wire [2:0] req_slot;
    wire cur_odd, cur_pal, cur_valid, prev_valid; wire [7:0] field_count;
    wire lc_we; wire [2:0] lc_slot; wire [8:0] lc_word; wire [31:0] lc_wdata;
    fb_ctrl u_fb (
        .clk(pclk), .rst(prst),
        .fifo_data(ff_rdata), .fifo_empty(ff_empty), .fifo_level(ff_rlevel), .fifo_pop(ff_pop),
        .sd_req(sd_req), .sd_we(sd_we), .sd_addr(sd_addr), .sd_ack(sd_ack), .sd_wd_pop(sd_wd_pop),
        .sd_rdata(sd_rdata), .sd_rd_valid(sd_rd_valid), .sd_ready(sd_ready),
        .frame_evt(frame_evt), .req(req), .req_line(req_line), .req_prev(req_prev), .req_slot(req_slot),
        .done(done), .busy(busy), .cur_odd(cur_odd), .cur_pal(cur_pal), .cur_valid(cur_valid),
        .prev_valid(prev_valid), .field_count(field_count),
        .lc_we(lc_we), .lc_slot(lc_slot), .lc_word(lc_word), .lc_wdata(lc_wdata), .dbg(fb_dbg));

    // diagnostics: fb_ctrl state snapshot and FIFO overflows (writes dropped while full)
    reg  [7:0] ff_ovf = 0;
    always @(posedge pclk) if (prst) ff_ovf <= 0; else if (ff_wr && ff_full && ff_ovf != 8'hFF) ff_ovf <= ff_ovf + 8'd1;
    cdc_bus #(.W(8)) u_ovf_k (.clk(clk27), .d(ff_ovf), .q(ovf_k));
    cdc_bus #(.W(8)) u_fbd_k (.clk(clk27), .d(fb_dbg), .q(fbd_k));

    sdram_ctrl #(.REFRESH_CYCLES(579), .INIT_CYCLES(14850), .CL(2)) u_sdram (
        .clk(pclk), .rst(prst), .rd_lat(3'd4), .rd_neg(1'b0),
        .req(sd_req), .req_we(sd_we), .req_addr(sd_addr), .req_ack(sd_ack),
        .wdata(ff_rdata[31:0]), .wd_pop(sd_wd_pop), .rdata(sd_rdata), .rd_valid(sd_rd_valid),
        .ready(sd_ready),
        .sdram_clk(O_sdram_clk), .sdram_cke(O_sdram_cke), .sdram_cs_n(O_sdram_cs_n),
        .sdram_ras_n(O_sdram_ras_n), .sdram_cas_n(O_sdram_cas_n), .sdram_we_n(O_sdram_wen_n),
        .sdram_addr(O_sdram_addr), .sdram_ba(O_sdram_ba), .sdram_dqm(O_sdram_dqm), .sdram_dq(IO_sdram_dq));

    // settings into the pixel domain
    wire aspect_p, weave_p, nosig_p, osd_en_p; wire [10:0] osd_x0; wire [9:0] osd_y0;
    cdc_bus #(.W(25)) u_set_p (.clk(pclk), .d({set0[3], set0[4], set0[5], osd_ctrl[31], osd_ctrl[25:16], osd_ctrl[10:0]}),
                               .q({aspect_p, weave_p, nosig_p, osd_en_p, osd_y0, osd_x0}));
    wire [1:0] mode_p;
    cdc_bus #(.W(2)) u_mode_p (.clk(pclk), .d(mode_cur), .q(mode_p));

    wire [10:0] hc, hc_next; wire [9:0] vc; wire de, fs;
    // signal loss: no new field for 8 output frames
    reg [7:0] fc_last; reg [3:0] stale; reg lost;
    always @(posedge pclk) begin
        if (prst) begin fc_last <= 0; stale <= 4'd15; lost <= 1'b1; end
        else if (fs) begin
            if (field_count != fc_last) begin fc_last <= field_count; stale <= 0; end
            else if (stale != 4'd15) stale <= stale + 4'd1;
            lost <= (stale >= 4'd8);
        end
    end

    wire [23:0] rgb_v, rgb;
    wire [15:0] late_count;
    out_path u_out (
        .clk(pclk), .rst(prst), .hc(hc), .hc_next(hc_next), .vc(vc), .aspect_169(aspect_p), .weave_req(weave_p),
        .dim(lost && !nosig_p), .nosig_screen((lost || !cur_valid) && nosig_p),
        .frame_evt(frame_evt), .req(req), .req_line(req_line), .req_prev(req_prev), .req_slot(req_slot),
        .done(done), .busy(busy), .cur_odd(cur_odd), .cur_pal(cur_pal), .cur_valid(cur_valid),
        .prev_valid(prev_valid), .lc_we(lc_we), .lc_slot(lc_slot), .lc_word(lc_word), .lc_wdata(lc_wdata),
        .rgb(rgb_v), .late_count(late_count));

    osd u_osd (
        .clk(pclk), .hc(hc), .vc(vc), .enable(osd_en_p), .x0(osd_x0), .y0(osd_y0),
        .wclk(clk27), .we(osd_we), .waddr(osd_waddr), .wdata(osd_wdata),
        .rgb_in(rgb_v), .rgb_out(rgb));

    wire [9:0] t0, t1, t2;
    hdmi_tx #(.PIX_LATENCY(7)) u_tx (
        .clk(pclk), .rst(prst), .fmt50(mode_p == 2'd2), .dvi_only(1'b0),
        .hc(hc), .hc_next(hc_next), .vc(vc), .req_de(de), .frame_start(fs), .rgb(rgb),
        .tmds0(t0), .tmds1(t1), .tmds2(t2));
    hdmi_phy u_phy (.pclk(pclk), .fclk(fclk), .rst(prst), .d0(t0), .d1(t1), .d2(t2),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n), .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n));

    // ================================================================== status back to clk27
    wire [3:0] st_l;                          // {killed, pal_det, vlocked, lbeat}
    cdc_bus #(.W(4)) u_st_l (.clk(clk27), .d({killed, pal_det | test_l, vlocked | test_l, lbeat[15]}), .q(st_l));
    assign vlocked_k = st_l[1];
    assign pal_det_k = st_l[2];
    wire [3:0] st_p;                          // {lost, sd_ready, cur_valid, -}
    cdc_bus #(.W(4)) u_st_p (.clk(clk27), .d({lost, sd_ready, cur_valid, 1'b0}), .q(st_p));
    wire [23:0] vt_dbg_k; wire [15:0] hs_k, br_k;
    cdc_bus #(.W(24)) u_vtd (.clk(clk27), .d(vt_dbg), .q(vt_dbg_k));
    cdc_bus #(.W(32)) u_vtp (.clk(clk27), .d({br_n, hs_n}), .q({br_k, hs_k}));
    cdc_bus #(.W(36)) u_meas (.clk(clk27), .d({meas_tip, meas_blank}), .q({tip32[17:0], blank32[17:0]}));
    assign tip32[31:18] = {14{tip32[17]}};
    assign blank32[31:18] = {14{blank32[17]}};
    wire [7:0] fc_k; wire [15:0] late_k, click_k;
    cdc_bus #(.W(24)) u_cnt_p (.clk(clk27), .d({late_count, field_count}), .q({late_k, fc_k}));
    cdc_bus #(.W(16)) u_cnt_l (.clk(clk27), .d(click_cnt), .q(click_k));
    assign counters = {click_k[7:0], late_k, fc_k};

    // link monitor into the CPU domain. Window results are held for 1 s; the raw pins are
    // sampled directly (the wiring test holds each pattern for >= 10 ms); the edge counter
    // changes once per slow test edge.
    reg [7:0] raw_s1 = 0, raw_s2 = 0;
    always @(posedge clk27) begin raw_s1 <= link_d; raw_s2 <= raw_s1; end
    wire [7:0] edges_k; wire [25:0] freq_k, errp_k, errn_k; wire [15:0] bits_k;
    cdc_bus #(.W(8))  u_lm_e (.clk(clk27), .d(lm_edges), .q(edges_k));
    cdc_bus #(.W(94)) u_lm_w (.clk(clk27), .d({lm_samples, lm_errp, lm_errn, lm_seen0, lm_seen1}),
                              .q({freq_k, errp_k, errn_k, bits_k}));
    assign link_raw  = {16'd0, edges_k, raw_s2};
    assign link_freq = {6'd0, freq_k};
    assign link_errp = {6'd0, errp_k};
    assign link_errn = {6'd0, errn_k};
    assign link_bits = {16'd0, bits_k};

    // strobe presence: the lclk heartbeat bit toggles every 1.6 ms at 40 MHz
    reg st_hb_d = 0; reg [17:0] hb_age = 0; reg strobe_ok = 0;
    always @(posedge clk27) begin
        st_hb_d <= st_l[0];
        if (st_hb_d != st_l[0]) begin hb_age <= 0; strobe_ok <= 1'b1; end
        else if (hb_age == 18'd135000) strobe_ok <= 1'b0;       // 5 ms without a toggle
        else hb_age <= hb_age + 18'd1;
    end
    reg [1:0] b1s = 0, b2s = 0;
    always @(posedge clk27) begin b1s <= {b1s[0], btn_s1}; b2s <= {b2s[0], btn_s2}; end
    assign status = {20'd0, st_p[3], strobe_ok, mode_cur, st_p[2], plocked, st_p[1], st_l[3],
                     st_l[2], st_l[1], b2s[1], b1s[1]};

    // ================================================================== LEDs (active low)
    assign led = ~{strobe_ok, st_p[1], st_l[2], st_l[1], st_p[2], plocked};

    assign dbg_tx = link_tx;

    wire _unused = &{1'b0, line_start, field_start, pal_sw_neg, ff_full, ff_wlevel, de, click_k[15:8]};
endmodule
`default_nettype wire
