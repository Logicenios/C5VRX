// On-screen display v2 (pixel clock), composited after scaling (menu redesign; model/osd2_ref.py
// is the bit-exact reference, sim/tb_osd2.v).
//
// Layers, back to front: video -> panel -> bar -> stripe (three rounded rectangles) -> text.
//   Rounded rectangle: pixel (dx, dy) inside the w x h box; in a corner square of side r the
//   distance d^2 = cx^2 + cy^2 (cx, cy from the corner's inner edge) gives alpha a for
//   d^2 < r^2, a >> 1 for r^2 <= d^2 < (r+1)^2 (one anti-aliased pixel), else 0.
//   Text: 40 x 16 cells of 8 x 16 glyphs doubled to 16 x 32 with Scale2x (EPX); neighbours
//   outside the glyph count as 0. Cell {attr, char}: attr[3:0] palette index, attr[4] dim.
//   Blend per channel: out = v + (((c - v) * a) >>> 4), a = 0..16 (16 = opaque).
// Registers (CPU, crystal clock) are written to a shadow set; a write to register 31 requests a
// commit, which is applied in one clock at the start of vertical blanking (vc = 720, hc = 0) and
// acknowledged by toggling `commit_ack` (so animation steps are frame-synchronous and tear-free;
// the CPU writes the next set only after the acknowledge). A global fade is the CPU writing
// scaled alphas.
//   0..15  palette[i] = RGB888
//   16 + 3k: {y[25:16], x[10:0]}, 17 + 3k: {h[25:16], w[10:0]},
//   18 + 3k: {alpha[20:16], colour index[11:8], radius[4:0]}      k = 0 panel, 1 bar, 2 stripe
//   27 + k : {(r + 1)^2 [26:16], r^2 [10:0]} (computed by the CPU: the commit is a plain copy)
//   25     text window {y0[25:16], x0[10:0]}
//   26     text alphas {dim alpha[12:8], alpha[4:0]}
//   31     commit
// Latency: rgb_in is valid 6 clocks after (hc, vc), rgb_out 18 clocks after (hdmi_tx
// PIX_LATENCY = 18).
`default_nettype none
module osd2 #(
    parameter FONT_FILE = "rtl/osd/font.hex",
    parameter V_TOTAL = 750                  // lines per frame (720p50 and 720p60 alike)
) (
    input  wire        clk,
    input  wire [10:0] hc_nx,                // hdmi_tx hc / vc of the next clock: the OSD keeps its own
    input  wire [9:0]  vc_nx,                // copy so its per-pixel logic does not load hdmi_tx's counters (M81)
    // CPU side (crystal clock)
    input  wire        wclk,
    input  wire        we,                   // text RAM write
    input  wire [9:0]  waddr,                // {row[3:0], col[5:0]}
    input  wire [15:0] wdata,
    input  wire        rwe,                  // register write
    input  wire [4:0]  raddr,
    input  wire [31:0] rdata,
    output reg         commit_req = 1'b0,    // wclk domain: toggles on a commit request
    output reg         commit_ack = 1'b0,    // clk domain: toggles when a commit was applied
    input  wire [23:0] rgb_in,
    output reg  [23:0] rgb_out
) /* synthesis syn_dspstyle = "logic" */;   // small multipliers in logic: the DSP blocks are full
    reg [10:0] hc = 0; reg [9:0] vc = 0;
    always @(posedge clk) begin hc <= hc_nx; vc <= vc_nx; end      // == hdmi_tx hc, vc

    // ---------------- CPU side: text RAM, shadow registers ----------------
    reg [15:0] text [0:1023] /* synthesis syn_ramstyle = "block_ram" */;
    always @(posedge wclk) if (we) text[waddr] <= wdata;
    reg [31:0] sh [0:29] /* synthesis syn_ramstyle = "registers" */;
    always @(posedge wclk) if (rwe) begin
        if (raddr == 5'd31) commit_req <= ~commit_req;
        else if (raddr <= 5'd29) sh[raddr] <= rdata;
    end

    // ---------------- commit: copy the shadow set during vertical blanking ----------------
    reg [2:0] cs = 0;
    always @(posedge clk) cs <= {cs[1:0], commit_req};
    wire pending = cs[2] ^ commit_ack;
    reg [23:0] pal [0:15] /* synthesis syn_ramstyle = "registers" */;
    reg [10:0] lx [0:2] /* synthesis syn_ramstyle = "registers" */, lw [0:2] /* synthesis syn_ramstyle = "registers" */; reg [9:0] ly [0:2] /* synthesis syn_ramstyle = "registers" */, lh [0:2] /* synthesis syn_ramstyle = "registers" */;
    reg [4:0]  lr [0:2] /* synthesis syn_ramstyle = "registers" */, la [0:2] /* synthesis syn_ramstyle = "registers" */;
    reg [3:0]  lci [0:2] /* synthesis syn_ramstyle = "registers" */; reg [23:0] lc [0:2] /* synthesis syn_ramstyle = "registers" */;
    reg [10:0] lr2 [0:2] /* synthesis syn_ramstyle = "registers" */, lr12 [0:2] /* synthesis syn_ramstyle = "registers" */;          // r^2, (r + 1)^2 (1024 at r = 31)
    reg [10:0] tx0 = 0; reg [9:0] ty0 = 0; reg [4:0] ta = 0, tda = 0;
    integer i, k;
    initial for (k = 0; k < 3; k = k + 1) begin la[k] = 0; lx[k] = 0; ly[k] = 0; lw[k] = 0; lh[k] = 0; lr[k] = 0; end
    always @(posedge clk) begin
        // pure register copies (no logic on the paths from the CPU clock domain); the layer colours
        // are looked up in the copied palette one clock later
        if (pending && vc == 10'd720 && hc == 11'd0) begin
            for (i = 0; i < 16; i = i + 1) pal[i] <= sh[i][23:0];
            for (k = 0; k < 3; k = k + 1) begin
                lx[k] <= sh[16 + 3 * k][10:0]; ly[k] <= sh[16 + 3 * k][25:16];
                lw[k] <= sh[17 + 3 * k][10:0]; lh[k] <= sh[17 + 3 * k][25:16];
                lr[k] <= sh[18 + 3 * k][4:0];  la[k] <= sh[18 + 3 * k][20:16];
                lci[k] <= sh[18 + 3 * k][11:8];
                lr2[k] <= sh[27 + k][10:0]; lr12[k] <= sh[27 + k][26:16];
            end
            tx0 <= sh[25][10:0]; ty0 <= sh[25][25:16];
            ta <= sh[26][4:0]; tda <= sh[26][12:8];
            commit_ack <= ~commit_ack;
        end
        for (k = 0; k < 3; k = k + 1) lc[k] <= pal[lci[k]];
    end

    // x^2 for x = 0..31 as an explicit table (no multiplier inference on the corner path)
    function [9:0] sq5(input [4:0] v);
        case (v)
            5'd0: sq5 = 10'd0;
            5'd1: sq5 = 10'd1;
            5'd2: sq5 = 10'd4;
            5'd3: sq5 = 10'd9;
            5'd4: sq5 = 10'd16;
            5'd5: sq5 = 10'd25;
            5'd6: sq5 = 10'd36;
            5'd7: sq5 = 10'd49;
            5'd8: sq5 = 10'd64;
            5'd9: sq5 = 10'd81;
            5'd10: sq5 = 10'd100;
            5'd11: sq5 = 10'd121;
            5'd12: sq5 = 10'd144;
            5'd13: sq5 = 10'd169;
            5'd14: sq5 = 10'd196;
            5'd15: sq5 = 10'd225;
            5'd16: sq5 = 10'd256;
            5'd17: sq5 = 10'd289;
            5'd18: sq5 = 10'd324;
            5'd19: sq5 = 10'd361;
            5'd20: sq5 = 10'd400;
            5'd21: sq5 = 10'd441;
            5'd22: sq5 = 10'd484;
            5'd23: sq5 = 10'd529;
            5'd24: sq5 = 10'd576;
            5'd25: sq5 = 10'd625;
            5'd26: sq5 = 10'd676;
            5'd27: sq5 = 10'd729;
            5'd28: sq5 = 10'd784;
            5'd29: sq5 = 10'd841;
            5'd30: sq5 = 10'd900;
            5'd31: sq5 = 10'd961;
        endcase
    endfunction

    // ---------------- geometry: three rounded rectangles ----------------
    // The vertical terms are constant along a line: they are worked out for the next line during
    // the current one (vn, a few register stages with a whole line to settle) and taken at the
    // line change, so the pixel pipeline only reads registers. (Computed per pixel, rows whose
    // vertical corner distance was >= 16 drew full width in hardware although simulation and
    // model were right: the top rows of every panel with a radius over 16.)
    reg [9:0] vn = 0;                          // the next line
    reg signed [11:0] ngy [0:2] /* synthesis syn_ramstyle = "registers" */;
    reg [2:0] niny = 0, iny = 0;               // the line crosses the rectangle
    reg [5:0] ncy [0:2] /* synthesis syn_ramstyle = "registers" */, cyl [0:2] /* synthesis syn_ramstyle = "registers" */;   // [5] = not a corner row
    reg [9:0] nsqy [0:2] /* synthesis syn_ramstyle = "registers" */, sqyl [0:2] /* synthesis syn_ramstyle = "registers" */;
    always @(posedge clk) begin
        vn <= (vc == V_TOTAL - 1) ? 10'd0 : vc + 10'd1;
        for (k = 0; k < 3; k = k + 1) begin
            ngy[k] <= $signed({2'b0, vn}) - $signed({2'b0, ly[k]});
            niny[k] <= ngy[k] >= 0 && ngy[k] < $signed({2'b0, lh[k]});
            ncy[k] <= (ngy[k] < $signed({7'd0, lr[k]})) ? {1'b0, lr[k] - 5'd1 - ngy[k][4:0]}
                    : (ngy[k] >= $signed({2'b0, lh[k]}) - $signed({7'd0, lr[k]})) ? {1'b0, ngy[k][4:0] - (lh[k][4:0] - lr[k])}
                    : 6'h20;
            nsqy[k] <= sq5(ncy[k][4:0]);
        end
        // taken while hc = 0 of the new line is in s0; s1 reads them one clock later
        if (hc == 11'd0) begin
            iny <= niny;
            for (k = 0; k < 3; k = k + 1) begin cyl[k] <= ncy[k]; sqyl[k] <= nsqy[k]; end
        end
    end

    // pixels: s0 offset; s1 inside / corner distance; s2 square; s3 sum; s4 alpha
    reg signed [11:0] gdx [0:2] /* synthesis syn_ramstyle = "registers" */;
    reg [2:0]  in1, in2, in2b;
    reg [5:0]  cx [0:2] /* synthesis syn_ramstyle = "registers" */;             // cx[5] = 1: not in a corner column
    reg [10:0] d2 [0:2] /* synthesis syn_ramstyle = "registers" */; reg [2:0] crn2, crn3;
    reg [9:0]  sqx [0:2] /* synthesis syn_ramstyle = "registers" */, sqy [0:2] /* synthesis syn_ramstyle = "registers" */;
    reg [4:0]  al [0:6][0:2] /* synthesis syn_ramstyle = "registers" */;   // alpha per layer, carried to the blend stages
    always @(posedge clk) begin
        for (k = 0; k < 3; k = k + 1) begin
            gdx[k] <= $signed({1'b0, hc}) - $signed({1'b0, lx[k]});
            // s1
            in1[k] <= iny[k] && gdx[k] >= 0 && gdx[k] < $signed({1'b0, lw[k]});
            cx[k] <= (gdx[k] < $signed({7'd0, lr[k]})) ? {1'b0, lr[k] - 5'd1 - gdx[k][4:0]}
                   : (gdx[k] >= $signed({1'b0, lw[k]}) - $signed({7'd0, lr[k]})) ? {1'b0, gdx[k][4:0] - (lw[k][4:0] - lr[k])}
                   : 6'h20;
            // s2: squares; s3: sum (one multiply-add per clock missed 74.25 MHz in a full chip)
            in2[k] <= in1[k];
            crn2[k] <= !cx[k][5] && !cyl[k][5];
            if (in1[k] && !cx[k][5] && !cyl[k][5]) begin sqx[k] <= sq5(cx[k][4:0]); sqy[k] <= sqyl[k]; end
            in2b[k] <= in2[k]; crn3[k] <= crn2[k];
            if (in2[k] && crn2[k]) d2[k] <= {1'b0, sqx[k]} + {1'b0, sqy[k]};   // used only then
            // s4
            al[0][k] <= !in2b[k] ? 5'd0 : !crn3[k] ? la[k] : (d2[k] < lr2[k]) ? la[k]
                      : (d2[k] < lr12[k]) ? {1'b0, la[k][4:1]} : 5'd0;
        end
    end

    // ---------------- text: prefetch the next cell, Scale2x ----------------
    reg signed [11:0] tdx; reg signed [10:0] tdy;
    wire tvy = tdy >= 0 && tdy < 11'sd512;
    // s0: text position
    always @(posedge clk) begin
        tdx <= $signed({1'b0, hc}) - $signed({1'b0, tx0});
        tdy <= $signed({1'b0, vc}) - $signed({1'b0, ty0});
    end
    reg [7:0] font [0:2047];
    initial $readmemh(FONT_FILE, font);
    // fetch sequence for cell (tdx >> 4) + 1, started when tdx[3:0] == 0 (tdx = -16 .. 623). One
    // font read port (one block RAM), data two clocks after the address register is written:
    //   f0 text RAM -> tq; f1..f3 font rows gy-1, gy, gy+1; f3..f5 take them
    wire [5:0]  fcol = tdx[9:4] + 6'd1;
    wire        fgo  = tvy && tdx[3:0] == 4'd0 && tdx >= -12'sd16 && tdx < 12'sd624;
    reg  [5:0]  fseq = 0; reg [5:0] fcol_r; reg [15:0] tq; reg [3:0] gy;
    reg  [10:0] fa; reg [7:0] fq; reg frd_m, frd_p;
    reg  [7:0]  n_up, n_mid, n_dn; reg [4:0] n_attr;
    always @(posedge clk) begin
        fseq <= {fseq[4:0], fgo};
        if (fgo) fcol_r <= fcol;
        gy <= tdy[4:1];
        if (fseq[0]) tq <= text[{tdy[8:5], fcol_r}];
        if (fseq[1]) begin fa <= {tq[6:0], gy - 4'd1}; frd_m <= gy != 4'd0; end
        if (fseq[2]) fa <= {tq[6:0], gy};
        if (fseq[3]) begin fa <= {tq[6:0], gy + 4'd1}; frd_p <= gy != 4'd15; n_up <= frd_m ? fq : 8'd0; end
        if (fseq[4]) begin n_mid <= fq; n_attr <= tq[12:8]; end
        if (fseq[5]) n_dn <= frd_p ? fq : 8'd0;
        fq <= font[fa];
    end
    // current cell: swapped in when the pixel pipeline enters it
    reg [7:0] c_up, c_mid, c_dn; reg [4:0] c_attr; reg c_on;
    reg signed [11:0] tdx1; reg sy1, tin1;
    always @(posedge clk) begin
        if (tdx[3:0] == 4'd0) begin
            c_up <= n_up; c_mid <= n_mid; c_dn <= n_dn; c_attr <= n_attr;
            c_on <= tvy && tdx >= 0 && tdx < 12'sd640;
        end
        tdx1 <= tdx; sy1 <= tdy[0]; tin1 <= tvy && tdx >= 0 && tdx < 12'sd640;
    end
    // s2: Scale2x for the sub-pixel (sx, sy) of glyph pixel gx
    wire [2:0] gx = tdx1[3:1];
    wire sx = tdx1[0];
    wire E = c_mid[3'd7 - gx], B = c_up[3'd7 - gx], Hh = c_dn[3'd7 - gx];
    wire D = (gx == 3'd0) ? 1'b0 : c_mid[3'd7 - gx + 3'd1];
    wire F = (gx == 3'd7) ? 1'b0 : c_mid[3'd7 - gx - 3'd1];
    wire epx = (B != Hh) && (D != F);
    wire px = !epx ? E : (!sy1 && !sx) ? ((D == B) ? D : E) : (!sy1 && sx) ? ((B == F) ? F : E)
            : (sy1 && !sx) ? ((D == Hh) ? D : E) : ((Hh == F) ? F : E);
    reg [4:0] tal2; reg [23:0] tcol2; wire [4:0] tal5; wire [23:0] tcol5;
    pipe_dly #(.W(29), .N(3)) u_tdly (.clk(clk), .d({tal2, tcol2}), .q({tal5, tcol5}));   // s3 .. s5
    always @(posedge clk) begin
        tal2 <= (tin1 && c_on && px) ? (c_attr[4] ? tda : ta) : 5'd0;
        tcol2 <= pal[c_attr[3:0]];
        // s3 .. s5: carry text to the blend stage (s6)
        for (k = 0; k < 3; k = k + 1) begin
            al[1][k] <= al[0][k];
        end
    end
    // layer alphas: al[0] is s4 (s0 gdx, s1 cx, s2 d2, s3 -> al[0] at s4); al[2] at s6

    // ---------------- blend: three clocks per layer, rgb_out 18 after (hc, vc) ----------------
    // S: d = c - v; M: p = d * a; A: v + (p >>> 4) (per channel). Layers: panel (edges 7-9), bar
    // (10-12), stripe (13-15), text (16-18). A subtract and a logic multiplier in one clock missed
    // 74.25 MHz by ~0.9 ns. The later layers' alphas / colours ride along (q_*).
    function [29:0] sub3(input [23:0] c, input [23:0] v);
        sub3 = {$signed({2'b0, c[23:16]}) - $signed({2'b0, v[23:16]}),
                $signed({2'b0, c[15:8]}) - $signed({2'b0, v[15:8]}),
                $signed({2'b0, c[7:0]}) - $signed({2'b0, v[7:0]})};
    endfunction
    function [14:0] mul1(input [9:0] d, input [4:0] a); mul1 = $signed(d) * $signed({1'b0, a}); endfunction
    function [44:0] mul3(input [29:0] d, input [4:0] a);
        mul3 = {mul1(d[29:20], a), mul1(d[19:10], a), mul1(d[9:0], a)};
    endfunction
    function [7:0] add1(input [7:0] v, input [8:0] p); add1 = v + p[7:0]; endfunction   // mod 256
    // (each sum sized to 8 bits: in a concatenation an unsized 8 + 9 bit sum would be 9 bits wide)
    function [23:0] add3(input [23:0] v, input [44:0] p);
        add3 = {add1(v[23:16], p[42:34]), add1(v[15:8], p[27:19]), add1(v[7:0], p[12:4])};
    endfunction
    // per-layer pipeline registers: stage S (d, v, a), M (p, v, a), A (w). Where a layer's alpha
    // is 0 (almost the whole screen when the menu is closed) its subtract and multiply registers
    // keep their values and the video passes through: the same output with far less switching,
    // which disturbed the HDMI link (MEASUREMENTS M81).
    reg [29:0] bd0, bd1, bd2, bd3; reg [44:0] p0, p1, p2, p3;
    reg [23:0] vs0, vm0, vs1, vm1, vs2, vm2, vs3, vm3, w0, w1, w2;
    reg [4:0]  as0, as1, as2, as3; reg z0m, z1m, z2m, z3m;
    // carried parameters, delayed to their layer's subtract stage (edges 10, 13, 16)
    wire [4:0] q_a1_9, q_a2_12, q_at_15; wire [23:0] q_ct_15;
    pipe_dly #(.W(5), .N(3)) u_qa1 (.clk(clk), .d(al[1][1]), .q(q_a1_9));
    pipe_dly #(.W(5), .N(6)) u_qa2 (.clk(clk), .d(al[1][2]), .q(q_a2_12));
    pipe_dly #(.W(29), .N(9)) u_qt (.clk(clk), .d({tal5, tcol5}), .q({q_at_15, q_ct_15}));
    always @(posedge clk) begin
        // panel
        if (al[1][0] != 0) bd0 <= sub3(lc[0], rgb_in);
        vs0 <= rgb_in; as0 <= al[1][0];
        if (as0 != 0) p0 <= mul3(bd0, as0);
        vm0 <= vs0; z0m <= as0 == 0;
        w0 <= z0m ? vm0 : add3(vm0, p0);
        // bar (w0 valid after edge 9)
        if (q_a1_9 != 0) bd1 <= sub3(lc[1], w0);
        vs1 <= w0; as1 <= q_a1_9;
        if (as1 != 0) p1 <= mul3(bd1, as1);
        vm1 <= vs1; z1m <= as1 == 0;
        w1 <= z1m ? vm1 : add3(vm1, p1);
        // stripe (w1 after edge 12)
        if (q_a2_12 != 0) bd2 <= sub3(lc[2], w1);
        vs2 <= w1; as2 <= q_a2_12;
        if (as2 != 0) p2 <= mul3(bd2, as2);
        vm2 <= vs2; z2m <= as2 == 0;
        w2 <= z2m ? vm2 : add3(vm2, p2);
        // text (w2 after edge 15)
        if (q_at_15 != 0) bd3 <= sub3(q_ct_15, w2);
        vs3 <= w2; as3 <= q_at_15;
        if (as3 != 0) p3 <= mul3(bd3, as3);
        vm3 <= vs3; z3m <= as3 == 0;
        rgb_out <= z3m ? vm3 : add3(vm3, p3);
    end
endmodule
`default_nettype wire
