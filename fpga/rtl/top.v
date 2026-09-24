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
    wire        osd_we; wire [9:0] osd_waddr; wire [15:0] osd_wdata;
    reg  [3:0]  cpu_rst_cnt = 4'hF;
    always @(posedge clk27) if (cpu_rst_cnt != 0) cpu_rst_cnt <= cpu_rst_cnt - 4'd1;
    soc u_soc (
        .clk(clk27), .resetn(cpu_rst_cnt == 0), .uart_tx(link_tx), .uart_rx(link_rx),
        .osd_we(osd_we), .osd_waddr(osd_waddr), .osd_wdata(osd_wdata),
        .status(status), .meas_tip(tip32), .meas_blank(blank32), .counters(counters), .debug(debug),
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
    clk_gen u_clk (.clk27(clk27), .mode(mode_req), .fclk(fclk), .pclk(pclk), .locked(plocked), .mode_cur(mode_cur),
                   .restarts(clk_restarts), .last_cause(clk_cause));
    // debug word: {mode changes requested[7:0], restarts[7:0], cause, mode_want, mode_req, 8'd0, ...}
    reg [7:0] mode_changes = 0;
    reg [1:0] mode_req_d = 0;
    always @(posedge clk27) begin
        mode_req_d <= mode_req;
        if (mode_req_d != mode_req && mode_changes != 8'hFF) mode_changes <= mode_changes + 8'd1;
    end
    assign debug = {mode_changes, clk_restarts, 2'd0, clk_cause, mode_want, mode_req, 8'd0};

    // ================================================================== lclk: receive chain
    wire lclk = link_strobe;
    reg [3:0] lrst_cnt = 4'hF;
    always @(posedge lclk) if (lrst_cnt != 0) lrst_cnt <= lrst_cnt - 4'd1;
    wire lrst = lrst_cnt != 0;

    // settings into the link domain
    wire [1:0]  std_l; wire notch_l; wire [15:0] hue_l; wire [7:0] sat_l, bri_l, con_l;
    cdc_bus #(.W(43)) u_set_l (.clk(lclk), .d({set0[1:0], set0[6], set1[23:0], set2[15:0]}),
                               .q({std_l, notch_l, sat_l, hue_l, con_l, bri_l}));

    // capture in fabric flip-flops. The pad input register (nextpnr --vopt ireg_in_iob) reads a
    // constant 0 with this toolchain (docs/MEASUREMENTS.md M61), so it is not used. STROBE is the
    // source-synchronous clock, so no synchroniser is needed. A LUT1 buffer per bit adds delay
    // before the phase-LUT BSRAM address pins, which otherwise miss hold by ~0.12 ns.
    reg [7:0] iq_cap, iq_r;
    always @(posedge lclk) begin iq_cap <= link_d; iq_r <= iq_cap; end
    wire [7:0] iq;
    genvar gi;
    generate for (gi = 0; gi < 8; gi = gi + 1) begin : iq_dly
        (* keep *) LUT1 #(.INIT(2'b10)) u_buf (.F(iq[gi]), .I0(iq_r[gi]));
    end endgenerate

    wire signed [17:0] f20; wire f20_valid, click;
    fm_frontend #(.LUT_FILE("rtl/dsp/phase_lut.hex")) u_fm (
        .clk(lclk), .rst(lrst), .iq(iq), .iq_valid(1'b1),
        .f20(f20), .f20_valid(f20_valid), .click(click));

    wire signed [11:0] cv; wire cv_valid; wire [10:0] cv_x;
    wire line_start, field_odd, field_start, pal_det, vlocked;
    wire [9:0] line_no; wire signed [17:0] meas_tip, meas_blank;
    video_timing u_vt (
        .clk(lclk), .rst(lrst), .f(f20), .f_valid(f20_valid),
        .cv(cv), .cv_valid(cv_valid), .cv_x(cv_x), .line_start(line_start), .line_no(line_no),
        .field_odd(field_odd), .field_start(field_start), .is_pal(pal_det), .locked(vlocked),
        .meas_tip(meas_tip), .meas_blank(meas_blank));
    // menu override of the standard (Auto uses the detected line period)
    wire is_pal = (std_l == 2'd1) ? 1'b0 : (std_l == 2'd2) ? 1'b1 : pal_det;

    wire signed [11:0] y_c; wire signed [15:0] u_c, v_c; wire [10:0] x_c;
    wire c_valid, killed, pal_sw_neg;
    chroma_dec #(.SIN_FILE("rtl/dsp/sin_lut.hex"), .COS_FILE("rtl/dsp/cos_lut.hex")) u_chroma (
        .clk(lclk), .rst(lrst), .cv(cv), .cv_valid(cv_valid), .cv_x(cv_x), .is_pal(is_pal),
        .comb(~notch_l), .hue(hue_l), .sat(sat_l),
        .y_out(y_c), .u_out(u_c), .v_out(v_c), .x_out(x_c), .out_valid(c_valid),
        .killed(killed), .pal_sw_neg(pal_sw_neg));

    wire [35:0] ff_wdata; wire ff_wr;
    fb_format u_fmt (
        .clk(lclk), .rst(lrst), .y_in(y_c), .u_in(u_c), .v_in(v_c), .x_in(x_c), .in_valid(c_valid),
        .tag_strobe(cv_valid && cv_x == 11'd0), .line_no(line_no), .field_odd(field_odd), .is_pal(is_pal), .locked(vlocked),
        .brightness(bri_l), .contrast(con_l),
        .fifo_data(ff_wdata), .fifo_wr(ff_wr));

    reg [15:0] click_cnt = 0;
    always @(posedge lclk) if (click) click_cnt <= click_cnt + 16'd1;
    reg [23:0] lbeat = 0;
    always @(posedge lclk) lbeat <= lbeat + 24'd1;

    // ================================================================== pclk: frame buffer and output
    reg [3:0] prst_cnt = 4'hF;
    always @(posedge pclk or negedge plocked)
        if (!plocked) prst_cnt <= 4'hF; else if (prst_cnt != 0) prst_cnt <= prst_cnt - 4'd1;
    wire prst = prst_cnt != 0;

    wire [35:0] ff_rdata; wire ff_empty, ff_full, ff_pop; wire [9:0] ff_rlevel, ff_wlevel;
    async_fifo #(.WIDTH(36), .AW(9)) u_fifo (
        .wclk(lclk), .wrst(lrst), .wr_en(ff_wr), .wr_data(ff_wdata), .full(ff_full), .wr_level(ff_wlevel),
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
        .lc_we(lc_we), .lc_slot(lc_slot), .lc_word(lc_word), .lc_wdata(lc_wdata));

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

    wire [10:0] hc; wire [9:0] vc; wire de, fs;
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
        .clk(pclk), .rst(prst), .hc(hc), .vc(vc), .aspect_169(aspect_p), .weave_req(weave_p),
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
        .clk(pclk), .rst(prst), .fmt50(mode_p == 2'd2), .dvi_only(1'b0), .afd_4x3(!aspect_p),
        .hc(hc), .vc(vc), .req_de(de), .frame_start(fs), .rgb(rgb),
        .tmds0(t0), .tmds1(t1), .tmds2(t2));
    hdmi_phy u_phy (.pclk(pclk), .fclk(fclk), .rst(prst), .d0(t0), .d1(t1), .d2(t2),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n), .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n));

    // ================================================================== status back to clk27
    wire [3:0] st_l;                          // {killed, pal_det, vlocked, lbeat}
    cdc_bus #(.W(4)) u_st_l (.clk(clk27), .d({killed, pal_det, vlocked, lbeat[15]}), .q(st_l));
    assign vlocked_k = st_l[1];
    assign pal_det_k = st_l[2];
    wire [3:0] st_p;                          // {lost, sd_ready, cur_valid, -}
    cdc_bus #(.W(4)) u_st_p (.clk(clk27), .d({lost, sd_ready, cur_valid, 1'b0}), .q(st_p));
    cdc_bus #(.W(36)) u_meas (.clk(clk27), .d({meas_tip, meas_blank}), .q({tip32[17:0], blank32[17:0]}));
    assign tip32[31:18] = {14{tip32[17]}};
    assign blank32[31:18] = {14{blank32[17]}};
    wire [7:0] fc_k; wire [15:0] late_k, click_k;
    cdc_bus #(.W(24)) u_cnt_p (.clk(clk27), .d({late_count, field_count}), .q({late_k, fc_k}));
    cdc_bus #(.W(16)) u_cnt_l (.clk(clk27), .d(click_cnt), .q(click_k));
    assign counters = {click_k[7:0], late_k, fc_k};

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
