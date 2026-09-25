// 720p HDMI transmitter core: CEA-861 timing, video preamble/guard bands and a
// once-per-frame AVI InfoFrame data island (HDMI 1.4 §5.2, CEA-861-F §6.4).
//
// Timing (CEA-861, 74.25 MHz, positive syncs):
//   fmt50=0: VIC 4  1280x720p60  (also 59.94 with a 74.176 MHz clock)  H 1280+110+40+220 = 1650
//   fmt50=1: VIC 19 1280x720p50                                       H 1280+440+40+220 = 1980
//   V (both): 720 + 5 + 5 + 20 = 750
//
// The pixel source sees (hc, vc) and must return rgb PIX_LATENCY clocks later.
`default_nettype none
module hdmi_tx #(
    parameter integer PIX_LATENCY = 2
) (
    input  wire        clk,        // pixel clock
    input  wire        rst,
    input  wire        fmt50,      // 1 = 720p50 (VIC 19), 0 = 720p60/59.94 (VIC 4)
    input  wire        dvi_only,   // 1 = no data islands / guard bands (DVI fallback)
    output reg  [10:0] hc = 0,     // pixel position being requested now
    output wire [10:0] hc_next,    // hc of the next clock (lets consumers register hc comparisons)
    output reg  [9:0]  vc = 0,
    output wire        req_de,     // (hc, vc) inside the 1280x720 active area
    output reg         frame_start,// one clock at hc=0, vc=0
    input  wire [23:0] rgb,        // {r, g, b}, PIX_LATENCY clocks after (hc, vc)
    output wire [9:0]  tmds0,
    output wire [9:0]  tmds1,
    output wire [9:0]  tmds2
);
    localparam H_ACTIVE = 1280, V_ACTIVE = 720, V_TOTAL = 750;
    localparam V_SYNC_START = 725, V_SYNC_END = 730;
    wire [10:0] h_total = fmt50 ? 11'd1980 : 11'd1650;
    wire [10:0] h_sync_start = fmt50 ? 11'd1720 : 11'd1390;   // 1280 + FP
    wire [10:0] h_sync_end   = fmt50 ? 11'd1760 : 11'd1430;   // + 40

    // Data island position: line 721 (vertical blanking), starting right after active.
    localparam ISL_LINE = 10'd721;
    localparam ISL_PRE  = 11'd1284;           // 8-clock preamble 1284..1291
    localparam ISL_GB0  = ISL_PRE + 11'd8;    // leading guard band 1292..1293
    localparam ISL_PKT  = ISL_GB0 + 11'd2;    // 32-clock packet 1294..1325
    localparam ISL_GB1  = ISL_PKT + 11'd32;   // trailing guard band 1326..1327

    assign hc_next = rst ? 11'd0 : (hc == h_total - 1) ? 11'd0 : hc + 11'd1;
    always @(posedge clk) begin
        if (rst) begin
            hc <= 0; vc <= 0;
        end else if (hc == h_total - 1) begin
            hc <= 0;
            vc <= (vc == V_TOTAL - 1) ? 10'd0 : vc + 10'd1;
        end else begin
            hc <= hc + 11'd1;
        end
        frame_start <= (hc == 0 && vc == 0);
    end
    assign req_de = (hc < H_ACTIVE) && (vc < V_ACTIVE);

    // ---- per-clock period classification ----
    localparam P_CTRL = 3'd0, P_VIDEO = 3'd1, P_VPRE = 3'd2, P_VGB = 3'd3,
               P_IPRE = 3'd4, P_IGB = 3'd5, P_IPKT = 3'd6;
    wire next_line_active = (vc == V_TOTAL - 1) || (vc < V_ACTIVE - 1);
    wire hs = (hc >= h_sync_start) && (hc < h_sync_end);
    wire vs = (vc >= V_SYNC_START) && (vc < V_SYNC_END);
    reg [2:0] period;
    reg [4:0] pkt_idx;
    always @(*) begin
        period = P_CTRL;
        pkt_idx = 5'd0;
        if (req_de) period = P_VIDEO;
        else if (!dvi_only && next_line_active && hc >= h_total - 11'd10 && hc < h_total - 11'd2) period = P_VPRE;
        else if (!dvi_only && next_line_active && hc >= h_total - 11'd2) period = P_VGB;
        else if (!dvi_only && vc == ISL_LINE) begin
            if (hc >= ISL_PRE && hc < ISL_GB0) period = P_IPRE;
            else if ((hc >= ISL_GB0 && hc < ISL_PKT) || (hc >= ISL_GB1 && hc < ISL_GB1 + 11'd2)) period = P_IGB;
            else if (hc >= ISL_PKT && hc < ISL_GB1) begin period = P_IPKT; pkt_idx = hc - ISL_PKT; end
        end
    end

    // ---- AVI InfoFrame (CEA-861-F Table 8/10), rebuilt from inputs ----
    // HB0 0x82 type, HB1 0x02 version, HB2 0x0D length.
    // PB1: Y=00 RGB, A0=1 active-format present   -> 0x10
    // PB2: C=10 BT.709, M=10 16:9, R=1000 (active format = same as picture) -> 0xA8.
    //      Always R=1000, also for the 4:3 pillarbox (out_path draws the bars into the frame).
    //      R=1001 (4:3 centred, 0xA9) made the user's monitor lose and regain the picture every
    //      few seconds at 720p50 (steady at 720p60); 0xA8 is steady at both (MEASUREMENTS M70).
    // PB3: Q=10 full-range RGB                      -> 0x08
    // PB4: VIC 4 / 19
    wire [7:0] pb1 = 8'h10;
    wire [7:0] pb2 = 8'hA8;
    wire [7:0] pb3 = 8'h08;
    wire [7:0] pb4 = fmt50 ? 8'd19 : 8'd4;
    wire [7:0] pb0 = 8'd0 - (8'h82 + 8'h02 + 8'h0D + pb1 + pb2 + pb3 + pb4);  // checksum
    wire [23:0] header = {8'h0D, 8'h02, 8'h82};                             // HB2 HB1 HB0 (LSB first)
    // subpacket 0 = PB0..PB6 (LSB = PB0), subpacket 1 = PB7..PB13 (all zero here)
    wire [55:0] sp0 = {8'd0 /*PB6*/, 8'd0 /*PB5*/, pb4, pb3, pb2, pb1, pb0};

    // BCH ECC (HDMI 1.4 §5.2.3.4): g(x) = x^8 + x^7 + x^6 + 1, LSB first.
    function [7:0] bch_ecc;
        input [63:0] bits;
        input integer n;
        integer k;
        reg [7:0] e;
        begin
            e = 8'd0;
            for (k = 0; k < 56; k = k + 1)
                if (k < n) e = (e >> 1) ^ ((e[0] ^ bits[k]) ? 8'b10000011 : 8'd0);
            bch_ecc = e;
        end
    endfunction

    wire [31:0] hdr_full = {bch_ecc({40'd0, header}, 24), header};
    wire [63:0] sp0_full = {bch_ecc({8'd0, sp0}, 56), sp0};
    wire [63:0] sp1_full = 64'd0;   // zero payload -> zero ECC
    wire [63:0] sp2_full = 64'd0;
    wire [63:0] sp3_full = 64'd0;

    wire [3:0] isl_ch0 = {pkt_idx != 5'd0, hdr_full[pkt_idx], vs, hs};
    wire [3:0] isl_ch1 = {sp3_full[{pkt_idx, 1'b0}], sp2_full[{pkt_idx, 1'b0}],
                          sp1_full[{pkt_idx, 1'b0}], sp0_full[{pkt_idx, 1'b0}]};
    wire [3:0] isl_ch2 = {sp3_full[{pkt_idx, 1'b1}], sp2_full[{pkt_idx, 1'b1}],
                          sp1_full[{pkt_idx, 1'b1}], sp0_full[{pkt_idx, 1'b1}]};

    // ---- delay control to meet the pixel source latency ----
    reg [2:0] period_d [0:PIX_LATENCY-1];
    reg       hs_d [0:PIX_LATENCY-1], vs_d [0:PIX_LATENCY-1];
    reg [3:0] i0_d [0:PIX_LATENCY-1], i1_d [0:PIX_LATENCY-1], i2_d [0:PIX_LATENCY-1];
    integer s;
    always @(posedge clk) begin
        period_d[0] <= period; hs_d[0] <= hs; vs_d[0] <= vs;
        i0_d[0] <= isl_ch0; i1_d[0] <= isl_ch1; i2_d[0] <= isl_ch2;
        for (s = 1; s < PIX_LATENCY; s = s + 1) begin
            period_d[s] <= period_d[s-1]; hs_d[s] <= hs_d[s-1]; vs_d[s] <= vs_d[s-1];
            i0_d[s] <= i0_d[s-1]; i1_d[s] <= i1_d[s-1]; i2_d[s] <= i2_d[s-1];
        end
    end
    wire [2:0] p = period_d[PIX_LATENCY-1];
    wire hsy = hs_d[PIX_LATENCY-1], vsy = vs_d[PIX_LATENCY-1];

    reg [2:0] m0, m1, m2;
    reg [1:0] c0, c1, c2;
    reg [3:0] t0, t1, t2;
    always @(*) begin
        c0 = {vsy, hsy}; c1 = 2'b00; c2 = 2'b00;
        t0 = i0_d[PIX_LATENCY-1]; t1 = i1_d[PIX_LATENCY-1]; t2 = i2_d[PIX_LATENCY-1];
        m0 = 3'd0; m1 = 3'd0; m2 = 3'd0;
        case (p)
            P_VIDEO: begin m0 = 3'd1; m1 = 3'd1; m2 = 3'd1; end
            P_VPRE:  begin c1 = 2'b01; c2 = 2'b00; end              // CTL0..3 = 1,0,0,0
            P_VGB:   begin m0 = 3'd3; m1 = 3'd3; m2 = 3'd3; end
            P_IPRE:  begin c1 = 2'b01; c2 = 2'b01; end              // CTL0..3 = 1,0,1,0
            P_IGB:   begin m0 = 3'd4; m1 = 3'd4; m2 = 3'd4; t0 = {2'b11, vsy, hsy}; end
            P_IPKT:  begin m0 = 3'd2; m1 = 3'd2; m2 = 3'd2; end
            default: ;
        endcase
    end

    // Channel 0 = blue, 1 = green, 2 = red (DVI 1.0 §3.2.2)
    tmds_encoder #(.CHANNEL(0)) enc0 (.clk(clk), .mode(m0), .data(rgb[7:0]),   .ctrl(c0), .terc4(t0), .q(tmds0));
    tmds_encoder #(.CHANNEL(1)) enc1 (.clk(clk), .mode(m1), .data(rgb[15:8]),  .ctrl(c1), .terc4(t1), .q(tmds1));
    tmds_encoder #(.CHANNEL(2)) enc2 (.clk(clk), .mode(m2), .data(rgb[23:16]), .ctrl(c2), .terc4(t2), .q(tmds2));
endmodule
`default_nettype wire
