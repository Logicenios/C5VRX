// Output path end to end: fields from model/scaler_ref.py test_fields() -> FIFO -> fb_ctrl ->
// SDRAM model -> out_path (deinterlace + 4-tap scaler + RGB). One output frame is dumped
// (rgb hex per pixel, 1280 x 720) and compared with the host model bit-exact.
`timescale 1ns/1ps
module tb_scaler;
    parameter PAL = 1;
    parameter WEAVE = 0;
    parameter ASPECT = 0;
    parameter CAPTURE = 4;                 // output frame to dump
    parameter IMG = "data/scaler_fields.hex";
    parameter OUT = "data/scaler_rtl.txt";

    reg lclk = 0, pclk = 0;
    always #12.5 lclk = ~lclk;             // 40 MHz
    always #6.734 pclk = ~pclk;            // 74.25 MHz
    reg lrst = 1, prst = 1;

    // ---------------- field generator (link domain) ----------------
    reg [31:0] img [0:2*288*360-1];
    initial $readmemh(IMG, img);
    localparam integer LP   = PAL ? 2560 : 2542;
    localparam integer NACT = PAL ? 288 : 240;
    reg [35:0] wdata; reg wr = 0;
    reg        odd = 1;                    // odd field = top field (frame lines 0, 2, ...)
    integer    gl = 0, gc = 0, nlines = 313, widx;
    always @(posedge lclk) begin
        wr <= 1'b0;
        if (!lrst) begin
            if (gl < NACT) begin
                if (gc == 0) begin
                    wdata <= {1'b1, (gl == 0), odd, PAL[0], 23'd0, gl[8:0]}; wr <= 1'b1;
                end else if (gc >= 200 && gc < 200 + 6 * 360 && (gc - 200) % 6 == 0) begin
                    widx = (gc - 200) / 6;
                    wdata <= {4'd0, img[(odd ? 0 : 288 * 360) + gl * 360 + widx]}; wr <= 1'b1;
                end
            end
            if (gc == LP - 1) begin
                gc <= 0;
                if (gl == nlines - 1) begin
                    gl <= 0; odd <= ~odd;
                    nlines <= PAL ? (odd ? 312 : 313) : (odd ? 263 : 262);
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
    // zero-delay model: CL 2 -> rd_lat 3 (hardware needs 4 at 74.25 MHz, MEASUREMENTS M60)
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
    out_path u_out (
        .clk(pclk), .rst(prst), .hc(hc), .vc(vc), .aspect_169(ASPECT[0]), .weave_req(WEAVE[0]),
        .dim(1'b0), .nosig_screen(1'b0),
        .frame_evt(frame_evt), .req(req), .req_line(req_line), .req_prev(req_prev), .req_slot(req_slot),
        .done(done), .busy(busy), .cur_odd(cur_odd), .cur_pal(cur_pal), .cur_valid(cur_valid),
        .prev_valid(prev_valid), .lc_we(lc_we), .lc_slot(lc_slot), .lc_word(lc_word), .lc_wdata(lc_wdata),
        .rgb(rgb), .late_count(late));

    // ---------------- capture ----------------
    reg [10:0] hcd [0:5]; reg [9:0] vcd [0:5];
    integer k, frames = 0, fo, npix = 0, cap_odd = -1, cap_weave = -1, late0 = 0;
    always @(posedge pclk) begin
        hcd[0] <= hc; vcd[0] <= vc;
        for (k = 1; k < 6; k = k + 1) begin hcd[k] <= hcd[k-1]; vcd[k] <= vcd[k-1]; end
        if (frame_evt) frames = frames + 1;
        if (frames == CAPTURE && hc == 11'd10 && vc == 10'd741) begin
            cap_odd = cur_odd; cap_weave = u_out.weave; late0 = late;
        end
        // rgb now belongs to (hcd[5], vcd[5]) (6-clock latency)
        if (frames == CAPTURE && vcd[5] < 10'd720 && hcd[5] < 11'd1280) begin
            if (npix < 1280 * 720) begin $fwrite(fo, "%06x\n", rgb); npix = npix + 1; end
        end
    end
    initial begin
        fo = $fopen(OUT, "w");
        #200 lrst = 0; prst = 0;
        wait (npix == 1280 * 720);
        $fclose(fo);
        $display("tb_scaler PAL=%0d WEAVE=%0d ASPECT=%0d: newest_odd=%0d weave=%0d late=%0d SDRAM errors %0d",
                 PAL, WEAVE, ASPECT, cap_odd, cap_weave, late - late0, mdl.errors);
        $display("META %0d %0d %0d %0d", PAL, cap_weave, ASPECT, cap_odd);
        $finish;
    end
endmodule
