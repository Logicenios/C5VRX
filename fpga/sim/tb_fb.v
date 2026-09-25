// Frame buffer + line cache: async_fifo -> fb_ctrl -> sdram_ctrl/sdram_model -> out_path.
//
// A generator in the link clock domain writes fields of tagged words
// {field id[7:0], line[8:0], word index[8:0], field id[5:0]} at real line/field rates; the
// output side runs real 720p50 or 720p60 raster counters. Checks:
//   1. every word written to the line cache belongs to the requested line and word index;
//   2. no tearing: within one output frame all lines from rb0 come from one field and (weave)
//      all lines from rb1 from the field before it;
//   3. the field being written is never read, and the shown field id never goes backwards;
//   4. the 4 vertical taps of every output line hold the expected source lines (bob: field
//      lines floor(v)-1..+2; weave: frame lines from the right field), fetched in time
//      (out_path late_count stays 0).
// Runs: NTSC 59.94 -> 720p50 (drops) and PAL 50 -> 720p60 (repeats), bob and weave.
`timescale 1ns/1ps
module tb_fb;
    parameter IN_PAL = 0;
    parameter OUT50 = 1;
    parameter WEAVE = 0;
    parameter FRAMES = 7;
    parameter SHORT = 0;                  // > 0: every 37th active line carries only SHORT of its
                                          //    360 pixel words (a real line cut short); checks that
                                          //    fb_ctrl keeps publishing fields instead of wedging.
                                          //    A multiple of 8 (e.g. 296) puts the next descriptor
                                          //    at the FIFO head on a burst boundary.

    reg lclk = 0, pclk = 0;
    always #12.5 lclk = ~lclk;            // 40 MHz
    always #6.734 pclk = ~pclk;           // 74.25 MHz
    reg lrst = 1, prst = 1;

    // ---------------- generator (link domain) ----------------
    localparam integer LP  = IN_PAL ? 2560 : 2542;
    localparam integer NACT = IN_PAL ? 288 : 240;
    reg [35:0] wdata; reg wr = 0;
    reg [7:0] fid = 0;
    reg       odd = 1;
    integer   gl = 0, gc = 0, nlines = 263;
    reg [8:0] widx;
    always @(posedge lclk) begin
        wr <= 1'b0;
        if (!lrst) begin
            if (gl < NACT) begin
                if (gc == 0) begin
                    wdata <= {1'b1, (gl == 0), odd, IN_PAL[0], 23'd0, gl[8:0]}; wr <= 1'b1;
                end else if (gc >= 200 && gc < 200 + 6 * ((SHORT != 0 && gl % 37 == 5) ? SHORT : 360) &&
                             (gc - 200) % 6 == 0) begin
                    widx = (gc - 200) / 6; wdata <= {4'd0, fid, gl[8:0], widx, fid[5:0]}; wr <= 1'b1;
                end
            end
            if (gc == LP - 1) begin
                gc <= 0;
                if (gl == nlines - 1) begin
                    gl <= 0; fid <= fid + 8'd1; odd <= ~odd;
                    nlines <= IN_PAL ? (odd ? 312 : 313) : (odd ? 263 : 262);
                end else gl <= gl + 1;
            end else gc <= gc + 1;
        end
    end

    // ---------------- DUT ----------------
    wire [35:0] ff_rdata; wire ff_empty, ff_full, ff_pop; wire [9:0] ff_rlevel, ff_wlevel;
    async_fifo #(.WIDTH(36), .AW(9)) u_fifo (
        .wclk(lclk), .wrst(lrst), .wr_en(wr), .wr_data(wdata), .full(ff_full), .wr_level(ff_wlevel),
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
    wire sdc, cke, cs_n, ras_n, cas_n, we_n; wire [10:0] a; wire [1:0] ba; wire [3:0] dqm; wire [31:0] dq;
    sdram_ctrl #(.INIT_CYCLES(100), .CL(2), .REFRESH_CYCLES(579)) u_sd (
        .clk(pclk), .rst(prst), .rd_lat(3'd3), .rd_neg(1'b0),
        .req(sd_req), .req_we(sd_we), .req_addr(sd_addr), .req_ack(sd_ack),
        .wdata(ff_rdata[31:0]), .wd_pop(sd_wd_pop), .rdata(sd_rdata), .rd_valid(sd_rd_valid), .ready(sd_ready),
        .sdram_clk(sdc), .sdram_cke(cke), .sdram_cs_n(cs_n), .sdram_ras_n(ras_n), .sdram_cas_n(cas_n),
        .sdram_we_n(we_n), .sdram_addr(a), .sdram_ba(ba), .sdram_dqm(dqm), .sdram_dq(dq));
    sdram_model #(.CL(2)) mdl (.clk(sdc), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
        .addr(a), .ba(ba), .dqm(dqm), .dq(dq));

    localparam integer HT = OUT50 ? 1980 : 1650;
    reg [10:0] hc = 0; reg [9:0] vc = 0;
    always @(posedge pclk) if (!prst) begin
        if (hc == HT - 1) begin hc <= 0; vc <= (vc == 10'd749) ? 10'd0 : vc + 10'd1; end
        else hc <= hc + 11'd1;
    end
    wire [23:0] rgb; wire [15:0] late;
    wire [10:0] hc_next = (hc == HT - 1) ? 11'd0 : hc + 11'd1;
    out_path u_out (
        .clk(pclk), .rst(prst), .hc(hc), .hc_next(hc_next), .vc(vc), .aspect_169(1'b0), .weave_req(WEAVE[0]),
        .dim(1'b0), .nosig_screen(1'b0),
        .frame_evt(frame_evt), .req(req), .req_line(req_line), .req_prev(req_prev), .req_slot(req_slot),
        .done(done), .busy(busy), .cur_odd(cur_odd), .cur_pal(cur_pal), .cur_valid(cur_valid),
        .prev_valid(prev_valid), .lc_we(lc_we), .lc_slot(lc_slot), .lc_word(lc_word), .lc_wdata(lc_wdata),
        .rgb(rgb), .late_count(late));

    // ---------------- checks ----------------
    integer ovf = 0;
    integer errs = 0, fetch_words = 0, checked_lines = 0, frames = 0, repeats = 0, drops = 0;
    integer f0 = -1, f1 = -1, prev_f0 = -1, weave_frames = 0, late0 = 0;
    reg r_prev_q;
    always @(posedge pclk) if (req) r_prev_q <= req_prev;
    always @(posedge lclk) if (wr && ff_full) ovf = ovf + 1;
    // 1-3: line-cache writes
    always @(posedge pclk) if (lc_we) begin
        fetch_words = fetch_words + 1;
        if (lc_wdata[23:15] != u_fb.r_line || lc_wdata[14:6] != lc_word || lc_wdata[5:0] != lc_wdata[29:24]) begin
            errs = errs + 1;
            if (errs < 10) $display("ERR cache word %h at word %0d: want line %0d", lc_wdata, lc_word, u_fb.r_line);
        end
        if (!u_fb.r_prev) begin
            if (f0 < 0) f0 = lc_wdata[31:24];
            else if (lc_wdata[31:24] != f0[7:0]) begin
                errs = errs + 1;
                if (errs < 10) $display("ERR tearing: field %0d in an output frame showing field %0d", lc_wdata[31:24], f0);
            end
        end else begin
            if (f1 < 0) f1 = lc_wdata[31:24];
            else if (lc_wdata[31:24] != f1[7:0]) begin
                errs = errs + 1;
                if (errs < 10) $display("ERR tearing (prev field): %0d vs %0d", lc_wdata[31:24], f1);
            end
        end
        if (lc_wdata[31:24] == fid) begin
            errs = errs + 1;
            if (errs < 10) $display("ERR reading field %0d while it is being written", fid);
        end
    end
    always @(posedge pclk) if (frame_evt && !prst) begin
        if (f0 >= 0) begin
            frames = frames + 1;
            if (frames == 1) late0 = late;          // start-up frame may miss lines
            if (f1 >= 0) begin
                weave_frames = weave_frames + 1;
                if (f1 != ((f0 + 255) % 256)) begin errs = errs + 1; $display("ERR weave pair %0d/%0d", f0, f1); end
            end
            if (prev_f0 >= 0) begin
                if (f0 < prev_f0) begin errs = errs + 1; $display("ERR field went backwards %0d -> %0d", prev_f0, f0); end
                else if (f0 == prev_f0) repeats = repeats + 1;
                else if (f0 > prev_f0 + 1) drops = drops + f0 - prev_f0 - 1;
            end
            $display("frame %0d: field %0d%s writer at field %0d", frames, f0, (f1 >= 0) ? " + previous" : "", fid);
            prev_f0 = f0;
        end
        f0 = -1; f1 = -1;
    end
    // 4: the four tap slots of the vertical pass hold the right lines
    function [31:0] slot_word0(input [2:0] s);
        case (s)
            3'd0: slot_word0 = u_out.slot[0].mem[0]; 3'd1: slot_word0 = u_out.slot[1].mem[0];
            3'd2: slot_word0 = u_out.slot[2].mem[0]; 3'd3: slot_word0 = u_out.slot[3].mem[0];
            default: slot_word0 = u_out.slot[4].mem[0];
        endcase
    endfunction
    integer t, pos, S, P0, k, kmax, j, key, L;
    reg [31:0] w; reg [2:0] ts [0:3];
    always @(posedge pclk) if (hc == 11'd20 && (vc < 10'd719 || vc == 10'd749) && cur_valid && !prst && prev_f0 >= 0) begin
        t = (vc == 10'd749) ? 0 : vc + 1;
        L = cur_pal ? 288 : 240;
        if (u_out.weave) begin S = cur_pal ? 52429 : 43691; P0 = cur_pal ? -6554 : -10923; kmax = 2 * L - 1; end
        else begin
            S = cur_pal ? 26214 : 21845; kmax = L - 1;
            P0 = cur_pal ? (cur_odd ? -3277 : -36045) : (cur_odd ? -5461 : -38229);
        end
        pos = P0 + t * S;
        k = pos >>> 16;
        ts[0] = u_out.ts0; ts[1] = u_out.ts1; ts[2] = u_out.ts2; ts[3] = u_out.ts3;
        for (j = 0; j < 4; j = j + 1) begin
            key = k - 1 + j; if (key < 0) key = 0; if (key > kmax) key = kmax;
            w = slot_word0(ts[j]);
            if (u_out.weave ? (w[23:15] != (key >> 1)) : (w[23:15] != key)) begin
                errs = errs + 1;
                if (errs < 10) $display("ERR y=%0d tap %0d: slot %0d holds line %0d, want key %0d", t, j, ts[j], w[23:15], key);
            end
        end
        checked_lines = checked_lines + 1;
    end

    initial begin
        #200 lrst = 0; prst = 0;
        wait (frames == FRAMES);
        $display("IN %s -> OUT %s %s: frames %0d (%0d with a field pair), repeats %0d, drops %0d, cache words %0d, lines checked %0d, late %0d, SDRAM errors %0d, fifo overflow %0d, errors %0d",
                 IN_PAL ? "PAL 50" : "NTSC 59.94", OUT50 ? "720p50" : "720p60", WEAVE ? "weave" : "bob",
                 frames, weave_frames, repeats, drops, fetch_words, checked_lines, late - late0, mdl.errors, ovf, errs);
        if (SHORT != 0) begin
            // short lines leave stale words in the SDRAM (content errors are expected there);
            // what must hold is that every input field is still published
            $display("SHORT lines: generator fields %0d, fb_ctrl fields published %0d, fifo overflow %0d", fid, u_fb.field_count, ovf);
            $display("%s", (((fid - u_fb.field_count) & 8'hFF) <= 8'd2 && fid > 4 && ovf == 0) ? "PASS" : "FAIL");
        end else
        $display("%s", (errs == 0 && mdl.errors == 0 && ovf == 0 && late == late0 && checked_lines > 0) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
