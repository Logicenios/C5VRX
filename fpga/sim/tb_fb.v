// Frame-buffer path: async_fifo -> fb_ctrl -> sdram_ctrl/sdram_model -> out_path line cache.
//
// A generator in the link clock domain writes fields of tagged words
// {field id, line, word index, field id[5:0]} at real line/field rates; the output side
// runs real 720p50 or 720p60 raster counters. Checks:
//   1. every word written to the line cache belongs to the requested line and word index;
//   2. no tearing: every cache line fetched during one output frame comes from the same field;
//   3. the field shown is complete (its id is older than the field being written) and
//      field ids never go backwards (frame repeat/drop only);
//   4. bob mapping: in each active output line the word at the displayed slot is source line
//      k(y) = floor(((2y + 1) L + 360 - 720 p) / 1440) clamped to 0..L-1 of the shown field.
// Run both rate-mismatch directions: IN_PAL=0 OUT50=1 (59.94 -> 50, drops) and
// IN_PAL=1 OUT50=0 (50 -> 60, repeats).
`timescale 1ns/1ps
module tb_fb;
    parameter IN_PAL = 0;
    parameter OUT50 = 1;
    parameter FRAMES = 7;

    reg lclk = 0, sclk = 0, pclk = 0;
    always #12.5 lclk = ~lclk;            // 40 MHz
    always #9.259 sclk = ~sclk;           // 54 MHz
    always #6.734 pclk = ~pclk;           // 74.25 MHz
    reg lrst = 1, srst = 1, prst = 1;

    // ---------------- generator (link domain) ----------------
    localparam integer LP  = IN_PAL ? 2560 : 2542;            // line period, lclk cycles (64 / 63.556 us)
    localparam integer NACT = IN_PAL ? 288 : 240;
    reg [35:0] wdata; reg wr = 0;
    reg [7:0] fid = 0;
    reg       odd = 1;
    integer   gl = 0, gc = 0, nlines = 263;
    reg [8:0] widx;
    always @(posedge lclk) begin
        wr <= 1'b0;
        if (!lrst) begin
            // line gl of the field, cycle gc of the line
            if (gl < NACT) begin
                if (gc == 0) begin
                    wdata <= {1'b1, (gl == 0), odd, IN_PAL[0], 23'd0, gl[8:0]}; wr <= 1'b1;
                end else if (gc >= 200 && gc < 200 + 6 * 360 && (gc - 200) % 6 == 0) begin
                    widx = (gc - 200) / 6; wdata <= {4'd0, fid, gl[8:0], widx, fid[5:0]}; wr <= 1'b1;
                end
            end
            if (gc == LP - 1) begin
                gc <= 0;
                if (gl == nlines - 1) begin
                    gl <= 0; fid <= fid + 8'd1; odd <= ~odd;
                    nlines <= IN_PAL ? (odd ? 313 : 312) : (odd ? 262 : 263);
                end else gl <= gl + 1;
            end else gc <= gc + 1;
        end
    end

    // ---------------- DUT ----------------
    wire [35:0] ff_rdata; wire ff_empty, ff_full, ff_pop; wire [9:0] ff_rlevel, ff_wlevel;
    async_fifo #(.WIDTH(36), .AW(9)) u_fifo (
        .wclk(lclk), .wrst(lrst), .wr_en(wr), .wr_data(wdata), .full(ff_full), .wr_level(ff_wlevel),
        .rclk(sclk), .rrst(srst), .rd_en(ff_pop), .rd_data(ff_rdata), .empty(ff_empty), .rd_level(ff_rlevel));

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

    wire sdc, cke, cs_n, ras_n, cas_n, we_n; wire [10:0] a; wire [1:0] ba; wire [3:0] dqm; wire [31:0] dq;
    sdram_ctrl #(.INIT_CYCLES(100)) u_sd (
        .clk(sclk), .rst(srst), .req(sd_req), .req_we(sd_we), .req_addr(sd_addr), .req_ack(sd_ack),
        .wdata(ff_rdata[31:0]), .wd_pop(sd_wd_pop), .rdata(sd_rdata), .rd_valid(sd_rd_valid), .ready(sd_ready),
        .sdram_clk(sdc), .sdram_cke(cke), .sdram_cs_n(cs_n), .sdram_ras_n(ras_n), .sdram_cas_n(cas_n),
        .sdram_we_n(we_n), .sdram_addr(a), .sdram_ba(ba), .sdram_dqm(dqm), .sdram_dq(dq));
    sdram_model mdl (.clk(sdc), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
        .addr(a), .ba(ba), .dqm(dqm), .dq(dq));

    // output raster (hdmi_tx totals: 1650 x 750 at 60 Hz, 1980 x 750 at 50 Hz)
    localparam integer HT = OUT50 ? 1980 : 1650;
    reg [10:0] hc = 0; reg [9:0] vc = 0;
    always @(posedge pclk) if (!prst) begin
        if (hc == HT - 1) begin hc <= 0; vc <= (vc == 10'd749) ? 10'd0 : vc + 10'd1; end
        else hc <= hc + 11'd1;
    end
    reg [1:0] co_s, cp_s, cv_s;
    always @(posedge pclk) begin co_s <= {co_s[0], s_cur_odd}; cp_s <= {cp_s[0], s_cur_pal}; cv_s <= {cv_s[0], s_cur_valid}; end
    wire [23:0] rgb;
    out_path u_out (
        .clk(pclk), .rst(prst), .hc(hc), .vc(vc), .aspect_169(1'b0),
        .cur_odd(co_s[1]), .cur_pal(cp_s[1]), .cur_valid(cv_s[1]), .dim(1'b0),
        .frame_tog(frame_tog), .req_tog(req_tog), .req_line(req_line), .req_slot(req_slot),
        .lc_wclk(sclk), .lc_we(lc_we), .lc_waddr(lc_waddr), .lc_wdata(lc_wdata), .rgb(rgb));

    // ---------------- checks ----------------
    integer ovf = 0;
    integer errs = 0, fetch_words = 0, checked_lines = 0, frames = 0, repeats = 0, drops = 0;
    integer frame_fid = -1, prev_fid = -1;
    // 1-3: line-cache writes (SDRAM domain)
    always @(posedge sclk) if (lc_we) begin
        fetch_words = fetch_words + 1;
        if (lc_wdata[23:15] != u_fb.r_line || lc_wdata[14:6] != lc_waddr[8:0] ||
            lc_wdata[5:0] != lc_wdata[29:24] || lc_waddr[10:9] != u_fb.r_slot) begin
            errs = errs + 1;
            if (errs < 10) $display("ERR cache word %h at %h: want line %0d slot %0d", lc_wdata, lc_waddr, u_fb.r_line, u_fb.r_slot);
        end
        if (frame_fid < 0) frame_fid = lc_wdata[31:24];
        else if (lc_wdata[31:24] != frame_fid[7:0]) begin
            errs = errs + 1;
            if (errs < 10) $display("ERR tearing: field %0d in output frame showing field %0d", lc_wdata[31:24], frame_fid);
        end
        if (lc_wdata[31:24] == fid) begin
            errs = errs + 1;
            if (errs < 10) $display("ERR reading field %0d while it is being written", fid);
        end
    end
    // new output frame (out_path's frame event at line 740): account the previous one
    always @(posedge pclk) if (vc == 10'd740 && hc == 11'd0 && !prst) begin
        if (frame_fid >= 0) begin
            frames = frames + 1;
            if (prev_fid >= 0) begin
                if (frame_fid < prev_fid) begin errs = errs + 1; $display("ERR field went backwards %0d -> %0d", prev_fid, frame_fid); end
                else if (frame_fid == prev_fid) repeats = repeats + 1;
                else if (frame_fid > prev_fid + 1) drops = drops + frame_fid - prev_fid - 1;
            end
            $display("frame %0d: field %0d (%s) writer at field %0d", frames, frame_fid, co_s[1] ? "odd" : "even", fid);
            prev_fid = frame_fid;
        end
        frame_fid = -1;
    end
    // 4: vertical mapping, checked mid-line on the displayed slot
    integer y, L, p, k;
    reg [31:0] w;
    always @(posedge pclk) if (hc == 11'd600 && vc < 10'd720 && cv_s[1] && !prst && prev_fid >= 0) begin
        y = vc; L = cp_s[1] ? 288 : 240; p = co_s[1] ? 0 : 1;
        k = ((2 * y + 1) * L + 360 - 720 * p); k = (k < 0) ? 0 : k / 1440; if (k > L - 1) k = L - 1;
        w = u_out.lc[{u_out.cur_slot, 9'd0}];
        checked_lines = checked_lines + 1;
        if (w[23:15] != k || u_out.src_line != k) begin
            errs = errs + 1;
            if (errs < 10) $display("ERR y=%0d: slot %0d holds line %0d, src_line %0d, want %0d", y, u_out.cur_slot, w[23:15], u_out.src_line, k);
        end
    end

    initial begin
        #200 lrst = 0; srst = 0; prst = 0;
        wait (frames == FRAMES);
        $display("IN %s -> OUT %s: frames %0d, repeats %0d, drops %0d, cache words %0d, lines checked %0d, SDRAM errors %0d, fifo overflow %0d, errors %0d",
                 IN_PAL ? "PAL 50" : "NTSC 59.94", OUT50 ? "720p50" : "720p60", frames, repeats, drops,
                 fetch_words, checked_lines, mdl.errors, ovf, errs);
        $display("%s", (errs == 0 && mdl.errors == 0 && ovf == 0) ? "PASS" : "FAIL");
        $finish;
    end
    always @(posedge lclk) if (wr && ff_full) ovf = ovf + 1;
endmodule
