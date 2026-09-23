// C5VRX FPGA top (Sipeed Tang Nano 20K): C5 sample link -> FM demod -> sync/levels ->
// colour decode -> SDRAM triple-buffered fields -> free-running 720p HDMI.
//
// PRE-SCALER / PRE-OSD build for the Phase 4 resource and timing gate (fpga/README.md):
// nearest-neighbour scaling, fixed picture settings, no UART control link yet.
//
// Clock domains
//   lclk  link STROBE, 40 MHz from the C5 (PARLIO RX clock out, docs/FPGA_LINK.md §2)
//   sclk  54 MHz from pll_sys (SDRAM controller + fb_ctrl)
//   pclk  74.25 MHz = fclk / 5; fclk 371.25 MHz from pll_tmds_60 (TMDS serialiser)
// Crossings: async_fifo (lclk -> sclk), toggle handshakes and a dual-clock line cache
// (sclk <-> pclk), 2-FF synchronisers for quasi-static status bits.
`default_nettype none
module top (
    input  wire       clk27,
    input  wire       btn_s1,
    input  wire       btn_s2,
    output wire [5:0] led,            // active low
    // C5 sample link: link_d[k] = PARLIO RX data bit k = C5 GPIO BOARD_IQ_PINS[k]
    // (byte = {I[3:0], Q[3:0]}), sampled on the rising STROBE edge like the C5 itself
    input  wire       link_strobe,
    input  wire [7:0] link_d,
    input  wire       link_rx,        // C5 UART1 TX (GPIO11)
    output wire       link_tx,        // C5 UART1 RX (GPIO12), idle high
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
    assign link_tx = 1'b1;           // control link: post-gate

    // ------------------------------------------------------------------ clocks
    wire fclk, plock, pclk, sclk, slock;
    pll_tmds_60 u_pll_tmds (.clock_in(clk27), .clock_out(fclk), .locked(plock));
    CLKDIV #(.DIV_MODE("5")) u_div (.CLKOUT(pclk), .HCLKIN(fclk), .RESETN(plock), .CALIB(1'b0));
    pll_sys u_pll_sys (.clock_in(clk27), .clock_out(sclk), .locked(slock));
    wire lclk = link_strobe;

    reg [3:0] prst_cnt = 4'hF, srst_cnt = 4'hF, lrst_cnt = 4'hF;
    always @(posedge pclk or negedge plock)
        if (!plock) prst_cnt <= 4'hF; else if (prst_cnt != 0) prst_cnt <= prst_cnt - 4'd1;
    always @(posedge sclk or negedge slock)
        if (!slock) srst_cnt <= 4'hF; else if (srst_cnt != 0) srst_cnt <= srst_cnt - 4'd1;
    always @(posedge lclk) if (lrst_cnt != 0) lrst_cnt <= lrst_cnt - 4'd1;
    wire prst = prst_cnt != 0, srst = srst_cnt != 0, lrst = lrst_cnt != 0;

    // ------------------------------------------------------------------ link domain
    // capture register in the input pads (nextpnr --vopt ireg_in_iob); STROBE is the
    // source-synchronous clock, so no synchroniser is needed
    reg [7:0] iq;
    always @(posedge lclk) iq <= link_d;

    wire signed [17:0] f20; wire f20_valid, click;
    fm_frontend #(.LUT_FILE("rtl/dsp/phase_lut.hex")) u_fm (
        .clk(lclk), .rst(lrst), .iq(iq), .iq_valid(1'b1),
        .f20(f20), .f20_valid(f20_valid), .click(click));

    wire signed [11:0] cv; wire cv_valid; wire [10:0] cv_x;
    wire line_start, field_odd, field_start, is_pal, vlocked;
    wire [9:0] line_no; wire signed [17:0] meas_tip, meas_blank;
    video_timing u_vt (
        .clk(lclk), .rst(lrst), .f(f20), .f_valid(f20_valid),
        .cv(cv), .cv_valid(cv_valid), .cv_x(cv_x), .line_start(line_start), .line_no(line_no),
        .field_odd(field_odd), .field_start(field_start), .is_pal(is_pal), .locked(vlocked),
        .meas_tip(meas_tip), .meas_blank(meas_blank));

    wire signed [11:0] y_c; wire signed [15:0] u_c, v_c; wire [10:0] x_c;
    wire c_valid, killed, pal_sw_neg;
    chroma_dec #(.SIN_FILE("rtl/dsp/sin_lut.hex"), .COS_FILE("rtl/dsp/cos_lut.hex")) u_chroma (
        .clk(lclk), .rst(lrst), .cv(cv), .cv_valid(cv_valid), .cv_x(cv_x), .is_pal(is_pal),
        .comb(1'b1), .hue(16'd0), .sat(8'd146),
        .y_out(y_c), .u_out(u_c), .v_out(v_c), .x_out(x_c), .out_valid(c_valid),
        .killed(killed), .pal_sw_neg(pal_sw_neg));

    // line tags travel with the samples: delay-free here because chroma_dec's latency is
    // far shorter than one line and fb_format latches them at x == 0
    wire [35:0] ff_wdata; wire ff_wr;
    fb_format u_fmt (
        .clk(lclk), .rst(lrst), .y_in(y_c), .u_in(u_c), .v_in(v_c), .x_in(x_c), .in_valid(c_valid),
        .line_no(line_no), .field_odd(field_odd), .is_pal(is_pal), .locked(vlocked),
        .brightness(8'sd0), .contrast(8'd128),
        .fifo_data(ff_wdata), .fifo_wr(ff_wr));

    wire [35:0] ff_rdata; wire ff_empty, ff_full, ff_pop; wire [9:0] ff_rlevel, ff_wlevel;
    async_fifo #(.WIDTH(36), .AW(9)) u_fifo (
        .wclk(lclk), .wrst(lrst), .wr_en(ff_wr), .wr_data(ff_wdata), .full(ff_full), .wr_level(ff_wlevel),
        .rclk(sclk), .rrst(srst), .rd_en(ff_pop), .rd_data(ff_rdata), .empty(ff_empty), .rd_level(ff_rlevel));

    // ------------------------------------------------------------------ SDRAM domain
    wire sd_req, sd_we, sd_ack, sd_wd_pop, sd_rd_valid, sd_ready;
    wire [20:0] sd_addr; wire [31:0] sd_rdata;
    wire frame_tog, req_tog, done_tog; wire [8:0] req_line; wire [1:0] req_slot;
    wire s_cur_odd, s_cur_pal, s_cur_valid; wire [7:0] field_count;
    wire lc_we; wire [10:0] lc_waddr; wire [31:0] lc_wdata;
    fb_ctrl u_fb (
        .clk(sclk), .rst(srst),
        .fifo_data(ff_rdata), .fifo_empty(ff_empty), .fifo_level(ff_rlevel), .fifo_pop(ff_pop),
        .sd_req(sd_req), .sd_we(sd_we), .sd_addr(sd_addr), .sd_ack(sd_ack), .sd_wd_pop(sd_wd_pop),
        .sd_rdata(sd_rdata), .sd_rd_valid(sd_rd_valid), .sd_ready(sd_ready),
        .frame_tog(frame_tog), .req_tog(req_tog), .req_line(req_line), .req_slot(req_slot),
        .done_tog(done_tog), .cur_odd(s_cur_odd), .cur_pal(s_cur_pal), .cur_valid(s_cur_valid),
        .field_count(field_count), .lc_we(lc_we), .lc_waddr(lc_waddr), .lc_wdata(lc_wdata));

    sdram_ctrl u_sdram (
        .clk(sclk), .rst(srst), .req(sd_req), .req_we(sd_we), .req_addr(sd_addr), .req_ack(sd_ack),
        .wdata(ff_rdata[31:0]), .wd_pop(sd_wd_pop), .rdata(sd_rdata), .rd_valid(sd_rd_valid),
        .ready(sd_ready),
        .sdram_clk(O_sdram_clk), .sdram_cke(O_sdram_cke), .sdram_cs_n(O_sdram_cs_n),
        .sdram_ras_n(O_sdram_ras_n), .sdram_cas_n(O_sdram_cas_n), .sdram_we_n(O_sdram_wen_n),
        .sdram_addr(O_sdram_addr), .sdram_ba(O_sdram_ba), .sdram_dqm(O_sdram_dqm), .sdram_dq(IO_sdram_dq));

    // ------------------------------------------------------------------ pixel domain
    reg [1:0] cur_odd_s, cur_pal_s, cur_valid_s, vlocked_s, pal_in_s;
    reg [7:0] fc_s1, fc_s2;
    always @(posedge pclk) begin
        cur_odd_s <= {cur_odd_s[0], s_cur_odd};
        cur_pal_s <= {cur_pal_s[0], s_cur_pal};
        cur_valid_s <= {cur_valid_s[0], s_cur_valid};
        vlocked_s <= {vlocked_s[0], vlocked};
        pal_in_s <= {pal_in_s[0], is_pal};
        fc_s1 <= field_count; fc_s2 <= fc_s1;   // compared for change only; a torn sample just counts as a change
    end

    wire [10:0] hc; wire [9:0] vc; wire de, fs;
    // Signal loss: no new field for 8 output frames -> show the last frame dimmed.
    reg [7:0] fc_last; reg [3:0] stale; reg dim;
    // Output rate follows the stored standard (PAL -> 720p50, else 720p60) after 16
    // consecutive frames agree; the 59.94 Hz clock is a gate item (fpga/README.md).
    reg fmt50; reg [4:0] fmt_hyst;
    always @(posedge pclk) begin
        if (prst) begin
            fc_last <= 0; stale <= 4'd15; dim <= 1'b0; fmt50 <= 1'b0; fmt_hyst <= 0;
        end else if (fs) begin
            if (fc_s2 != fc_last) begin fc_last <= fc_s2; stale <= 0; end
            else if (stale != 4'd15) stale <= stale + 4'd1;
            dim <= (stale >= 4'd8);
            if (cur_valid_s[1] && cur_pal_s[1] != fmt50) begin
                fmt_hyst <= fmt_hyst + 5'd1;
                if (fmt_hyst == 5'd15) begin fmt50 <= cur_pal_s[1]; fmt_hyst <= 0; end
            end else fmt_hyst <= 0;
        end
    end

    wire [23:0] rgb;
    out_path u_out (
        .clk(pclk), .rst(prst), .hc(hc), .vc(vc), .aspect_169(1'b0),
        .cur_odd(cur_odd_s[1]), .cur_pal(cur_pal_s[1]), .cur_valid(cur_valid_s[1]), .dim(dim),
        .frame_tog(frame_tog), .req_tog(req_tog), .req_line(req_line), .req_slot(req_slot),
        .lc_wclk(sclk), .lc_we(lc_we), .lc_waddr(lc_waddr), .lc_wdata(lc_wdata), .rgb(rgb));

    wire [9:0] t0, t1, t2;
    hdmi_tx #(.PIX_LATENCY(2)) u_tx (
        .clk(pclk), .rst(prst), .fmt50(fmt50), .dvi_only(1'b0), .afd_4x3(1'b1),
        .hc(hc), .vc(vc), .req_de(de), .frame_start(fs), .rgb(rgb),
        .tmds0(t0), .tmds1(t1), .tmds2(t2));
    hdmi_phy u_phy (.pclk(pclk), .fclk(fclk), .rst(prst), .d0(t0), .d1(t1), .d2(t2),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n), .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n));

    // ------------------------------------------------------------------ LEDs
    reg [23:0] lbeat;
    always @(posedge lclk) lbeat <= lbeat + 24'd1;
    reg [1:0] lbeat_s;
    always @(posedge pclk) lbeat_s <= {lbeat_s[0], lbeat[23]};
    assign led = ~{lbeat_s[1], cur_valid_s[1], pal_in_s[1], vlocked_s[1], sd_ready, plock & slock};

    // unused
    wire _unused = &{1'b0, btn_s1, btn_s2, link_rx, click, line_start, field_start, meas_tip,
                     meas_blank, killed, pal_sw_neg, ff_full, ff_wlevel, done_tog, de};
endmodule
`default_nettype wire
