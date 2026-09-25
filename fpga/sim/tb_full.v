// Full receive chain, RF to pixels: synthetic FM I/Q (model/iqsynth.py, SMPTE 75 % bars for
// NTSC / EBU 75 % bars for PAL) -> fm_frontend -> video_timing -> chroma_dec -> fb_format ->
// async FIFO -> fb_ctrl + SDRAM model -> out_path (bob, 4:3). Dumps the video_timing stream
// (for model/chain_ref.py) and the first output frame that shows field MIN_FIELD or later.
`timescale 1ns/1ps
module tb_full;
    parameter N = 3600000;
    parameter PAL = 0;
    parameter MIN_FIELD = 3;
    parameter HEX = "data/full_ntsc.hex";
    parameter CV_OUT = "data/full_ntsc_cv.txt";
    parameter OUT = "data/full_ntsc_rgb.txt";
    parameter GAP = 1;                  // 1: the receive chain runs on the pixel clock (74.25 MHz)
                                        //    with one sample per 74.25/40 clocks, as in top.v (default)

    reg lclk = 0, pclk = 0;
    always #(GAP ? 6.734 : 12.5) lclk = ~lclk;
    always #6.734 pclk = ~pclk;
    reg lrst = 1, prst = 1;

    // ---------------- link domain ----------------
    reg [7:0] mem [0:N-1];
    initial $readmemh(HEX, mem);
    reg [7:0] iq = 0; integer ii = 0, acc = 0; reg iq_valid = 0;
    always @(posedge lclk) if (!lrst) begin
        acc = acc + 40000;
        if (!GAP || acc >= 74250) begin
            if (GAP) acc = acc - 74250;
            iq <= (ii < N) ? mem[ii] : 8'h00; ii <= ii + 1; iq_valid <= 1'b1;
        end else iq_valid <= 1'b0;
    end
    wire signed [17:0] f20; wire f20_valid, click;
    fm_frontend #(.LUT_FILE("../rtl/dsp/phase_lut.hex")) u_fm (.clk(lclk), .rst(lrst), .iq(iq), .iq_valid(iq_valid),
        .f20(f20), .f20_valid(f20_valid), .click(click));
    wire signed [11:0] cv; wire cv_valid, line_start, field_odd, field_start, is_pal, vlocked;
    wire [10:0] cv_x; wire [9:0] line_no; wire signed [17:0] tip, blank;
    video_timing u_vt (.clk(lclk), .rst(lrst), .f(f20), .f_valid(f20_valid), .cv(cv), .cv_valid(cv_valid), .cv_x(cv_x),
        .line_start(line_start), .line_no(line_no), .field_odd(field_odd), .field_start(field_start),
        .is_pal(is_pal), .locked(vlocked), .meas_tip(tip), .meas_blank(blank));
    wire signed [11:0] y_c; wire signed [15:0] u_c, v_c; wire [10:0] x_c; wire c_valid, killed, sw;
    chroma_dec #(.SIN_FILE("../rtl/dsp/sin_lut.hex"), .COS_FILE("../rtl/dsp/cos_lut.hex")) u_chroma (
        .clk(lclk), .rst(lrst), .cv(cv), .cv_valid(cv_valid), .cv_x(cv_x), .is_pal(is_pal), .comb(1'b1),
        .hue(16'd0), .sat(8'd146), .y_out(y_c), .u_out(u_c), .v_out(v_c), .x_out(x_c), .out_valid(c_valid),
        .killed(killed), .pal_sw_neg(sw));
    wire [35:0] ff_wdata; wire ff_wr;
    fb_format u_fmt (.clk(lclk), .rst(lrst), .y_in(y_c), .u_in(u_c), .v_in(v_c), .x_in(x_c), .in_valid(c_valid),
        .tag_strobe(cv_valid && cv_x == 11'd0), .line_no(line_no), .field_odd(field_odd), .is_pal(is_pal), .locked(vlocked),
        .brightness(8'sd0), .contrast(8'd128), .fifo_data(ff_wdata), .fifo_wr(ff_wr));

    // ---------------- pixel domain ----------------
    wire [35:0] ff_rdata; wire ff_empty, ff_full, ff_pop; wire [9:0] ff_rlevel, ff_wlevel;
    async_fifo #(.WIDTH(36), .AW(9)) u_fifo (
        .wclk(lclk), .wrst(lrst), .wr_en(ff_wr), .wr_data(ff_wdata), .full(ff_full), .wr_level(ff_wlevel),
        .rclk(pclk), .rrst(prst), .rd_en(ff_pop), .rd_data(ff_rdata), .empty(ff_empty), .rd_level(ff_rlevel));
    wire sd_req, sd_we, sd_ack, sd_wd_pop, sd_rd_valid, sd_ready;
    wire [20:0] sd_addr; wire [31:0] sd_rdata;
    wire frame_evt, req, req_prev, done, busy; wire [8:0] req_line; wire [2:0] req_slot;
    wire cur_odd, cur_pal, cur_valid, prev_valid; wire [7:0] field_count;
    wire lc_we; wire [2:0] lc_slot; wire [8:0] lc_word; wire [31:0] lc_wdata;
    fb_ctrl u_fb (.clk(pclk), .rst(prst),
        .fifo_data(ff_rdata), .fifo_empty(ff_empty), .fifo_level(ff_rlevel), .fifo_pop(ff_pop),
        .sd_req(sd_req), .sd_we(sd_we), .sd_addr(sd_addr), .sd_ack(sd_ack), .sd_wd_pop(sd_wd_pop),
        .sd_rdata(sd_rdata), .sd_rd_valid(sd_rd_valid), .sd_ready(sd_ready),
        .frame_evt(frame_evt), .req(req), .req_line(req_line), .req_prev(req_prev), .req_slot(req_slot),
        .done(done), .busy(busy), .cur_odd(cur_odd), .cur_pal(cur_pal), .cur_valid(cur_valid),
        .prev_valid(prev_valid), .field_count(field_count),
        .lc_we(lc_we), .lc_slot(lc_slot), .lc_word(lc_word), .lc_wdata(lc_wdata));
    wire sdc, cke, cs_n, ras_n, cas_n, we_n; wire [10:0] a; wire [1:0] ba; wire [3:0] dqm; wire [31:0] dq;
    sdram_ctrl #(.INIT_CYCLES(100), .CL(2), .REFRESH_CYCLES(579)) u_sd (
        .clk(pclk), .rst(prst), .rd_lat(3'd3), .rd_neg(1'b0),
        .req(sd_req), .req_we(sd_we), .req_addr(sd_addr), .req_ack(sd_ack),
        .wdata(ff_rdata[31:0]), .wd_pop(sd_wd_pop), .rdata(sd_rdata), .rd_valid(sd_rd_valid), .ready(sd_ready),
        .sdram_clk(sdc), .sdram_cke(cke), .sdram_cs_n(cs_n), .sdram_ras_n(ras_n), .sdram_cas_n(cas_n),
        .sdram_we_n(we_n), .sdram_addr(a), .sdram_ba(ba), .sdram_dqm(dqm), .sdram_dq(dq));
    sdram_model #(.CL(2)) mdl (.clk(sdc), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
        .addr(a), .ba(ba), .dqm(dqm), .dq(dq));
    reg [10:0] hc = 0; reg [9:0] vc = 0;
    always @(posedge pclk) if (!prst) begin
        if (hc == 11'd1649) begin hc <= 0; vc <= (vc == 10'd749) ? 10'd0 : vc + 10'd1; end
        else hc <= hc + 11'd1;
    end
    wire [23:0] rgb; wire [15:0] late;
    out_path u_out (.clk(pclk), .rst(prst), .hc(hc), .vc(vc), .aspect_169(1'b0), .weave_req(1'b0),
        .dim(1'b0), .nosig_screen(1'b0),
        .frame_evt(frame_evt), .req(req), .req_line(req_line), .req_prev(req_prev), .req_slot(req_slot),
        .done(done), .busy(busy), .cur_odd(cur_odd), .cur_pal(cur_pal), .cur_valid(cur_valid),
        .prev_valid(prev_valid), .lc_we(lc_we), .lc_slot(lc_slot), .lc_word(lc_word), .lc_wdata(lc_wdata),
        .rgb(rgb), .late_count(late));

    // ---------------- which field is in which buffer ----------------
    integer seq = 0, bf [0:4], k, n_ffw = 0, n_desc = 0;
    integer n_x0 = 0, n_x0act = 0, shown = 0;
    always @(posedge lclk) if (c_valid && x_c == 0) begin
        n_x0 = n_x0 + 1;
        if (vlocked && line_no >= (PAL ? 22 : 17) && line_no < (PAL ? 310 : 257)) n_x0act = n_x0act + 1;
        if (shown < 6 && n_x0 > 400) begin shown = shown + 1; $display("x0: line_no %0d odd %0d locked %0d", line_no, field_odd, vlocked); end
    end
    always @(posedge lclk) if (ff_wr) begin n_ffw = n_ffw + 1; if (ff_wdata[35]) n_desc = n_desc + 1; end
    reg     mark = 0;
    initial for (k = 0; k < 5; k = k + 1) bf[k] = 0;
    always @(posedge pclk) begin
        mark <= 1'b0;
        if (!u_fb.w_line && u_fb.head_desc && ff_rdata[34] && u_fb.sd_ready) begin seq = seq + 1; mark <= 1'b1; end
        if (mark) bf[u_fb.wbuf] = seq;             // wbuf after the publish holds field `seq`
    end

    // ---------------- dumps ----------------
    integer fcv, fo, npix = 0, cap = 0, cap_field = 0, cap_prev = 0, cap_odd = 0;
    initial begin fcv = $fopen(CV_OUT, "w"); fo = $fopen(OUT, "w"); end
    always @(posedge lclk) if (cv_valid && fcv != 0) $fwrite(fcv, "%0d %0d %0d %0d\n", cv_x, cv, line_no, field_odd);
    reg [10:0] hcd [0:5]; reg [9:0] vcd [0:5];
    always @(posedge pclk) begin
        hcd[0] <= hc; vcd[0] <= vc;
        for (k = 1; k < 6; k = k + 1) begin hcd[k] <= hcd[k-1]; vcd[k] <= vcd[k-1]; end
        if (vc == 10'd741 && hc == 11'd10 && cap == 0 && cur_valid && bf[u_fb.rb0] >= MIN_FIELD) begin
            cap = 1; cap_field = bf[u_fb.rb0]; cap_prev = bf[u_fb.rb1]; cap_odd = cur_odd;
        end
        if (cap == 1 && vcd[5] < 10'd720 && hcd[5] < 11'd1280 && npix < 1280 * 720) begin
            $fwrite(fo, "%06x\n", rgb); npix = npix + 1;
        end
    end
    initial begin
        #200 lrst = 0; prst = 0;
        wait (npix == 1280 * 720 || ii >= N);
        $fclose(fo); $fclose(fcv); fcv = 0;
        $display("tb_full: pixels %0d, video locked %0d pal %0d killed %0d, clicks?, late %0d, SDRAM errors %0d",
                 npix, vlocked, is_pal, killed, late, mdl.errors);
        $display("tb_full: chroma line starts %0d (active %0d), fifo writes %0d (desc %0d), SDRAM writes %0d reads %0d, fields published %0d, buffers %0d %0d %0d %0d %0d, rb0 %0d",
                 n_x0, n_x0act, n_ffw, n_desc, mdl.writes, mdl.reads, seq, bf[0], bf[1], bf[2], bf[3], bf[4], u_fb.rb0);
        $display("META pal=%0d weave=0 aspect=0 field=%0d prev=%0d odd=%0d", PAL, cap_field, cap_prev, cap_odd);
        $finish;
    end
endmodule
