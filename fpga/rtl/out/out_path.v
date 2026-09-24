// Output path (pixel clock): stored fields -> deinterlace -> 4-tap polyphase scaler -> RGB.
//
// Geometry: 4:3 -> 960x720 at x = 160..1119 (160 px pillarbox bars), 16:9 stretch -> 1280x720.
//
// Vertical (per output line y, Q16 source position, 32 phases):
//   bob  : field line   v = ((2y + 1) L - 360 - 720 p) / 1440   (p = 0 odd/top field, 1 even)
//   weave: frame line   v = ((2y + 1) L - 360) / 720, frame line q from field q & 1 (0 = top)
//   L = 240 (NTSC) / 288 (PAL). Taps are source lines floor(v) - 1 .. + 2, clamped.
// Horizontal: u = (x + 0.5) 720 / W - 0.5 luma samples; chroma (co-sited, 360 per line) at u / 2.
// Filter: Catmull-Rom 4-tap, Q7 (rtl/out/cr_coef.vh from model/scaler_coef.py); the host
// model model/scaler_ref.py is bit-exact with this file.
//
// Data flow:
//   line cache: 5 slots x 360 words, slot = key mod 5, key = field line (bob) or frame line
//     (weave); it always holds the 5 consecutive keys around the next output line, fetched
//     from fb_ctrl one line at a time (the window moves by <= 1 key per output line).
//   vertical pass: during output line vc, the 4 taps of line vc + 1 are filtered, one pixel
//     per clock, into 4-way interleaved line banks (pixel p in bank (p + 4) & 3, with 2 pixels
//     of edge padding each side), double-buffered by line parity.
//   horizontal pass: one output pixel per clock reads 4 adjacent samples from the 4 banks.
// Latency: rgb is valid 7 clocks after (hc, vc) (hdmi_tx PIX_LATENCY = 7, including the OSD
// stage outside this module: `rgb` here is valid 6 clocks after).
`default_nettype none
module out_path (
    input  wire        clk,
    input  wire        rst,
    input  wire [10:0] hc,
    input  wire [9:0]  vc,
    // settings (quasi-static)
    input  wire        aspect_169,     // 1 = stretch to 1280
    input  wire        weave_req,      // 1 = weave when two matching fields exist
    input  wire        dim,            // show video at half brightness (signal lost)
    input  wire        nosig_screen,   // replace video by the no-signal background
    // fb_ctrl
    output wire        frame_evt,
    output reg         req,
    output reg  [8:0]  req_line,
    output reg         req_prev,
    output reg  [2:0]  req_slot,
    input  wire        done,
    input  wire        busy,
    input  wire        cur_odd,
    input  wire        cur_pal,
    input  wire        cur_valid,
    input  wire        prev_valid,
    input  wire        lc_we,
    input  wire [2:0]  lc_slot,
    input  wire [8:0]  lc_word,
    input  wire [31:0] lc_wdata,
    output reg  [23:0] rgb,            // 6 clocks after (hc, vc)
    output reg  [15:0] late_count      // vertical passes that found a tap line not yet fetched
);
`include "cr_coef.vh"

    // ------------------------------------------------------------------ frame state
    assign frame_evt = (vc == 10'd740) && (hc == 11'd0);
    reg weave;                          // latched after fb_ctrl has latched its field pair
    always @(posedge clk)
        if (rst) weave <= 1'b0;
        else if (vc == 10'd740 && hc == 11'd4) weave <= weave_req && prev_valid;

    wire [9:0]  L    = cur_pal ? 10'd288 : 10'd240;
    wire [9:0]  kmax = weave ? {L[8:0], 1'b0} - 10'd1 : L - 10'd1;
    wire signed [27:0] S_v = weave ? (cur_pal ? 28'sd52429 : 28'sd43691) : (cur_pal ? 28'sd26214 : 28'sd21845);
    wire signed [27:0] P0  = weave ? (cur_pal ? -28'sd6554 : -28'sd10923)
                                   : (cur_pal ? (cur_odd ? -28'sd3277 : -28'sd36045)
                                              : (cur_odd ? -28'sd5461 : -28'sd38229));

    // position of the target line t(vc) = vc + 1 (vc <= 718) or 0 (vc >= 719)
    reg signed [27:0] posA;
    always @(posedge clk)
        if (hc == 11'd0) posA <= (vc >= 10'd719) ? P0 : posA + S_v;
    wire signed [11:0] kf = posA[27:16];          // floor(v), >= -1

    function [9:0] clampk(input signed [11:0] k, input [9:0] km);
        clampk = (k < 0) ? 10'd0 : (k > $signed({2'b0, km})) ? km : k[9:0];
    endfunction
    function [2:0] mod5(input [9:0] k);           // 16 = 1 (mod 5): sum the hex digits
        reg [5:0] s;
        begin
            s = {2'b0, k[3:0]} + {2'b0, k[7:4]} + {4'b0, k[9:8]};
            mod5 = (s >= 30) ? s - 30 : (s >= 25) ? s - 25 : (s >= 20) ? s - 20 :
                   (s >= 15) ? s - 15 : (s >= 10) ? s - 10 : (s >= 5) ? s - 5 : s;
        end
    endfunction

    // ------------------------------------------------------------------ line cache + fetch
    // Pipelined (posA only changes at hc == 0): A = needed keys and slots, B = hit/miss per key,
    // then the request. A 4-clock cool-down after each request/completion lets A/B catch up.
    reg [9:0] tag [0:4];
    reg [4:0] tvalid;
    reg       fgen, pend_gen, fetching;
    reg [2:0] pend_slot;
    reg [2:0] cool;
    reg [9:0] nk [0:4];
    reg [2:0] ns [0:4];
    reg [4:0] miss_r;
    reg [9:0] mk_r;
    reg [2:0] ms_r;
    integer j;
    always @(posedge clk) begin
        for (j = 0; j < 5; j = j + 1) begin                            // stage A
            nk[j] <= clampk(kf + j - 1, kmax);
            ns[j] <= mod5(clampk(kf + j - 1, kmax));
        end
        for (j = 0; j < 5; j = j + 1)                                  // stage B
            miss_r[j] <= !tvalid[ns[j]] || tag[ns[j]] != nk[j];
        mk_r <= nk[0]; ms_r <= ns[0];
        for (j = 4; j >= 0; j = j - 1)
            if (!tvalid[ns[j]] || tag[ns[j]] != nk[j]) begin mk_r <= nk[j]; ms_r <= ns[j]; end
    end
    always @(posedge clk) begin
        req <= 1'b0;
        if (cool != 0) cool <= cool - 3'd1;
        if (rst) begin
            tvalid <= 5'd0; fetching <= 1'b0; fgen <= 1'b0; cool <= 3'd0;
        end else begin
            if (frame_evt) begin tvalid <= 5'd0; fgen <= ~fgen; cool <= 3'd4; end
            if (done && fetching) begin
                fetching <= 1'b0; cool <= 3'd4;
                if (pend_gen == fgen && !frame_evt) tvalid[pend_slot] <= 1'b1;
            end
            // new requests from line 741 on (after the frame event has settled)
            if (!fetching && cool == 0 && !busy && !req && (|miss_r) && cur_valid && !frame_evt &&
                !(vc >= 10'd720 && vc <= 10'd740)) begin
                req <= 1'b1; req_slot <= ms_r; req_line <= weave ? mk_r[9:1] : mk_r[8:0];
                req_prev <= weave ? (mk_r[0] ^ ~cur_odd) : 1'b0;
                tag[ms_r] <= mk_r; tvalid[ms_r] <= 1'b0;
                fetching <= 1'b1; pend_slot <= ms_r; pend_gen <= fgen;
            end
        end
    end

    // 5 x (512 x 32) cache slots; every slot is read at the same word address
    reg  [8:0]  lc_raddr;
    wire [31:0] lc_q [0:4];
    genvar g;
    generate for (g = 0; g < 5; g = g + 1) begin : slot
        (* ram_style = "block" *) reg [31:0] mem [0:511];
        reg [31:0] q;
        always @(posedge clk) begin
            if (lc_we && lc_slot == g) mem[lc_word] <= lc_wdata;
            q <= mem[lc_raddr];
        end
        assign lc_q[g] = q;
    end endgenerate

    // ------------------------------------------------------------------ vertical pass
    // pixel i = hc - 16 (0..719); stage v1 = cache data, v2 = products, v3 = sums, v4 = write
    reg  [2:0]  ts0, ts1, ts2, ts3;               // slots of taps 0..3
    reg  [4:0]  vph;
    reg         vrun0, vrun1, vrun2, vrun3;
    reg  [9:0]  vi0, vi1, vi2, vi3;
    wire [9:0]  hrel = hc[9:0] - 10'd16;
    always @(posedge clk) begin
        if (hc == 11'd6) begin                    // stage A/B settled 3 clocks after posA
            ts0 <= ns[0]; ts1 <= ns[1]; ts2 <= ns[2]; ts3 <= ns[3];
            vph <= posA[15:11];
            if ((vc < 10'd719 || vc == 10'd749) && (|miss_r[3:0]) && cur_valid && !rst)
                late_count <= late_count + 16'd1;
        end
        if (rst) late_count <= 16'd0;
        vrun0 <= (hc >= 11'd16) && (hc < 11'd736);
        vi0 <= hrel;
        lc_raddr <= hrel[9:1];
        vrun1 <= vrun0; vi1 <= vi0;
        vrun2 <= vrun1; vi2 <= vi1;
        vrun3 <= vrun2; vi3 <= vi2;
    end
    // v1: select the component and multiply (Y and the co-sited chroma component)
    wire [35:0] vc4 = cr_coef(vph);
    wire signed [8:0] vcf0 = vc4[8:0], vcf1 = vc4[17:9], vcf2 = vc4[26:18], vcf3 = vc4[35:27];
    wire [31:0] d0 = lc_q[ts0], d1 = lc_q[ts1], d2 = lc_q[ts2], d3 = lc_q[ts3];
    function [7:0] ycomp(input [31:0] d, input odd); ycomp = odd ? d[23:16] : d[7:0]; endfunction
    function [7:0] ccomp(input [31:0] d, input odd); ccomp = odd ? d[31:24] : d[15:8]; endfunction
    reg signed [17:0] vpy0, vpy1, vpy2, vpy3, vpc0, vpc1, vpc2, vpc3;
    reg signed [19:0] vsy, vsc;
    always @(posedge clk) begin
        vpy0 <= $signed({1'b0, ycomp(d0, vi1[0])}) * vcf0; vpc0 <= $signed({1'b0, ccomp(d0, vi1[0])}) * vcf0;
        vpy1 <= $signed({1'b0, ycomp(d1, vi1[0])}) * vcf1; vpc1 <= $signed({1'b0, ccomp(d1, vi1[0])}) * vcf1;
        vpy2 <= $signed({1'b0, ycomp(d2, vi1[0])}) * vcf2; vpc2 <= $signed({1'b0, ccomp(d2, vi1[0])}) * vcf2;
        vpy3 <= $signed({1'b0, ycomp(d3, vi1[0])}) * vcf3; vpc3 <= $signed({1'b0, ccomp(d3, vi1[0])}) * vcf3;
        vsy <= vpy0 + vpy1 + vpy2 + vpy3;
        vsc <= vpc0 + vpc1 + vpc2 + vpc3;
    end
    function [7:0] clip7(input signed [19:0] s);      // round Q7, clip to 0..255
        reg signed [19:0] r;
        begin r = (s + 20'sd64) >>> 7; clip7 = (r < 0) ? 8'd0 : (r > 255) ? 8'd255 : r[7:0]; end
    endfunction
    wire [7:0] vy = clip7(vsy), vcv = clip7(vsc);

    // line banks: Y 4 x (512 x 8), C 4 x (512 x 16) = {Cb, Cr}; address {parity, index >> 2}
    wire       wpp = ~vc[0];                 // parity of the target line t(vc)
    wire [9:0] yp  = vi3 + 10'd4;            // luma position + 4
    wire [8:0] cm  = vi3[9:1] + 9'd4;        // chroma position + 4 (at odd pixels)
    reg  [7:0] cb_hold;
    always @(posedge clk) if (vrun3 && !vi3[0]) cb_hold <= vcv;
    // bank write enables/addresses incl. edge padding (-2, -1 at the start; +1, +2 at the end)
    wire yfirst = vrun3 && vi3 == 10'd0, ylast = vrun3 && vi3 == 10'd719;
    wire cfirst = vrun3 && vi3 == 10'd1, clast = vrun3 && vi3 == 10'd719;
    reg  [7:0]  ybk_d [0:3];
    reg  [15:0] cbk_d [0:3];
    reg  [7:0]  ybk_a [0:3], cbk_a [0:3];
    reg  [3:0]  ybk_we, cbk_we;
    integer b;
    always @(*) begin
        for (b = 0; b < 4; b = b + 1) begin
            ybk_we[b] = 1'b0; ybk_a[b] = yp[9:2]; ybk_d[b] = vy;
            cbk_we[b] = 1'b0; cbk_a[b] = cm[8:2]; cbk_d[b] = {cb_hold, vcv};
        end
        if (vrun3) ybk_we[yp[1:0]] = 1'b1;
        if (yfirst) begin ybk_we[2] = 1'b1; ybk_a[2] = 8'd0; ybk_we[3] = 1'b1; ybk_a[3] = 8'd0; end   // p = -2, -1
        if (ylast)  begin ybk_we[0] = 1'b1; ybk_a[0] = 8'd181; ybk_we[1] = 1'b1; ybk_a[1] = 8'd181; end // p = 720, 721
        if (vrun3 && vi3[0]) cbk_we[cm[1:0]] = 1'b1;
        if (cfirst) begin cbk_we[2] = 1'b1; cbk_a[2] = 8'd0; cbk_we[3] = 1'b1; cbk_a[3] = 8'd0; end   // m = -2, -1
        if (clast)  begin cbk_we[0] = 1'b1; cbk_a[0] = 8'd91; cbk_we[1] = 1'b1; cbk_a[1] = 8'd91; end   // m = 360, 361
    end

    // ------------------------------------------------------------------ horizontal pass
    wire [10:0] xs  = aspect_169 ? 11'd0 : 11'd160;
    wire [10:0] xw  = aspect_169 ? 11'd1280 : 11'd960;
    wire signed [27:0] S_h = aspect_169 ? 28'sd36864 : 28'sd49152;
    wire signed [27:0] U0  = aspect_169 ? -28'sd14336 : -28'sd8192;
    reg  signed [27:0] hacc;
    wire signed [27:0] hcur = (hc == xs) ? U0 : hacc + S_h;
    always @(posedge clk) hacc <= hcur;
    wire signed [27:0] ccur = hcur >>> 1;
    wire [9:0] s4  = hcur[25:16] + 10'd3;     // (n - 1) + 4, n = floor(u) >= -1
    wire [8:0] sc4 = ccur[24:16] + 9'd3;      // (m - 1) + 4
    wire       rpp = vc[0];
    reg  [7:0]  yq [0:3];
    reg  [15:0] cq [0:3];
    reg  [1:0]  r_s, r_sc;
    reg  [4:0]  r_ph, r_phc;
    reg  [6:0]  act;                          // active-video flag pipeline
    wire act0 = (vc < 10'd720) && (hc >= xs) && (hc < xs + xw);
    genvar gb;
    generate for (gb = 0; gb < 4; gb = gb + 1) begin : bank
        localparam [1:0] BK = gb;
        (* ram_style = "block" *) reg [7:0]  ym [0:511];
        (* ram_style = "block" *) reg [15:0] cmm [0:511];
        wire [1:0] yo = BK - s4[1:0], co = BK - sc4[1:0];
        wire [9:0] yi = s4 + {8'd0, yo};
        wire [8:0] ci = sc4 + {7'd0, co};
        always @(posedge clk) begin
            if (ybk_we[gb]) ym[{wpp, ybk_a[gb]}] <= ybk_d[gb];
            if (cbk_we[gb]) cmm[{wpp, cbk_a[gb]}] <= cbk_d[gb];
            yq[gb] <= ym[{rpp, yi[9:2]}];
            cq[gb] <= cmm[{rpp, 1'b0, ci[8:2]}];
        end
    end endgenerate
    always @(posedge clk) begin
        r_s <= s4[1:0]; r_sc <= sc4[1:0]; r_ph <= hcur[15:11]; r_phc <= ccur[15:11];
        act <= {act[5:0], act0};
    end
    // h1: taps in order (tap j = bank (s4 + j) & 3), products
    wire [35:0] hy4 = cr_coef(r_ph), hc4 = cr_coef(r_phc);
    wire signed [8:0] hyc0 = hy4[8:0], hyc1 = hy4[17:9], hyc2 = hy4[26:18], hyc3 = hy4[35:27];
    wire signed [8:0] hcc0 = hc4[8:0], hcc1 = hc4[17:9], hcc2 = hc4[26:18], hcc3 = hc4[35:27];
    wire [7:0]  ty0 = yq[r_s], ty1 = yq[r_s + 2'd1], ty2 = yq[r_s + 2'd2], ty3 = yq[r_s + 2'd3];
    wire [15:0] tc0 = cq[r_sc], tc1 = cq[r_sc + 2'd1], tc2 = cq[r_sc + 2'd2], tc3 = cq[r_sc + 2'd3];
    reg signed [17:0] hpy0, hpy1, hpy2, hpy3, hpb0, hpb1, hpb2, hpb3, hpr0, hpr1, hpr2, hpr3;
    reg signed [19:0] hsy, hsb, hsr;
    reg [7:0] Y, Cb, Cr;
    always @(posedge clk) begin
        hpy0 <= $signed({1'b0, ty0}) * hyc0; hpy1 <= $signed({1'b0, ty1}) * hyc1;
        hpy2 <= $signed({1'b0, ty2}) * hyc2; hpy3 <= $signed({1'b0, ty3}) * hyc3;
        hpb0 <= $signed({1'b0, tc0[15:8]}) * hcc0; hpb1 <= $signed({1'b0, tc1[15:8]}) * hcc1;
        hpb2 <= $signed({1'b0, tc2[15:8]}) * hcc2; hpb3 <= $signed({1'b0, tc3[15:8]}) * hcc3;
        hpr0 <= $signed({1'b0, tc0[7:0]}) * hcc0;  hpr1 <= $signed({1'b0, tc1[7:0]}) * hcc1;
        hpr2 <= $signed({1'b0, tc2[7:0]}) * hcc2;  hpr3 <= $signed({1'b0, tc3[7:0]}) * hcc3;
        hsy <= hpy0 + hpy1 + hpy2 + hpy3;
        hsb <= hpb0 + hpb1 + hpb2 + hpb3;
        hsr <= hpr0 + hpr1 + hpr2 + hpr3;
        Y <= clip7(hsy); Cb <= clip7(hsb); Cr <= clip7(hsr);
    end

    // ------------------------------------------------------------------ YCbCr (BT.601 limited) -> RGB
    reg signed [21:0] yy, rv, gu, gv, bu;
    always @(posedge clk) begin
        yy <= ($signed({1'b0, Y}) - 22'sd16) * 22'sd1192;
        rv <= ($signed({1'b0, Cr}) - 22'sd128) * 22'sd1634;
        gu <= ($signed({1'b0, Cb}) - 22'sd128) * 22'sd401;
        gv <= ($signed({1'b0, Cr}) - 22'sd128) * 22'sd833;
        bu <= ($signed({1'b0, Cb}) - 22'sd128) * 22'sd2065;
    end
    function [7:0] clip10(input signed [21:0] v);
        reg signed [21:0] r;
        begin r = v >>> 10; clip10 = (r < 0) ? 8'd0 : (r > 255) ? 8'd255 : r[7:0]; end
    endfunction
    wire [7:0] r8 = clip10(yy + rv), g8 = clip10(yy - gu - gv), b8 = clip10(yy + bu);
    localparam [23:0] NOSIG_BG = 24'h101840;          // dark blue
    always @(posedge clk) begin
        if (nosig_screen) rgb <= (vc < 10'd720) ? NOSIG_BG : 24'h000000;
        else if (!act[4] || !cur_valid) rgb <= 24'h000000;
        else if (dim) rgb <= {1'b0, r8[7:1], 1'b0, g8[7:1], 1'b0, b8[7:1]};
        else rgb <= {r8, g8, b8};
    end
endmodule
`default_nettype wire
