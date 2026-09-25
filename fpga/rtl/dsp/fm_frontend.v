// FM front end, one I/Q byte per clock (link strobe, 40 MS/s).
//   phase LUT -> adjacent discriminator (k = 1, +-20 MHz, THEORY §5.1/§5.2)
//   -> click repair (THEORY §10) -> halfband 2:1 -> de-emphasis (THEORY §6.3)
// Bit-exact with fpga/model/ref.py fm_frontend(). Frequency word: 1 LSB = 610.35 Hz.
`default_nettype none
module fm_frontend #(
    parameter LUT_FILE = "phase_lut.hex",
    parameter signed [16:0] CLICK_ABS  = 17'sd22937,  // 14 MHz
    parameter        [8:0]  CLICK_R2_LOW = 9'd10,
    parameter signed [17:0] CLICK_JUMP = 18'sd8192    // 5 MHz
) (
    input  wire               clk,
    input  wire               rst,
    input  wire [1:0]         deemph,      // de-emphasis roof: 0 13.4 dB (NTSC), 1 8 dB, 2 4 dB, 3 off
    input  wire [7:0]         iq,          // {I[3:0], Q[3:0]}
    input  wire               iq_valid,
    output reg signed [17:0]  f20,         // de-emphasised frequency, 20 MS/s
    output reg                f20_valid,
    output reg                click        // a click was repaired (for statistics)
);
    // ---- stage 0: LUT (synchronous ROM) ----
    reg [24:0] lut [0:255];
    initial $readmemh(LUT_FILE, lut);
    reg [24:0] lut_q, lut_r;
    reg        vq, v0;
    always @(posedge clk) begin
        lut_q <= lut[iq];
        vq <= iq_valid & ~rst;
        // extra register after the block RAM: its clock-to-output fed the discriminator / click
        // logic directly (0.5 ns slack at 74.25 MHz; MEASUREMENTS M75)
        lut_r <= lut_q; v0 <= vq & ~rst;
    end
    wire [15:0] ph = lut_r[15:0];
    wire [8:0]  r2 = lut_r[24:16];

    // ---- stage 1: discriminator + click repair (one-sample look-ahead) ----
    reg [15:0] ph_prev;
    reg [8:0]  r2_prev;
    reg        have_prev;
    reg signed [15:0] d_p, y_pp;
    reg        click_p;
    wire signed [15:0] d_s = have_prev ? $signed(ph - ph_prev) : 16'sd0;
    wire signed [16:0] ysum = $signed(y_pp) + $signed(d_s);
    wire signed [15:0] y_sm1 = click_p ? ysum[16:1] : d_p;          // y[s-1]
    wire [8:0] r2min = (r2 < r2_prev) ? r2 : r2_prev;
    wire signed [16:0] d_abs = d_s[15] ? -$signed({d_s[15], d_s}) : $signed({d_s[15], d_s});
    wire signed [17:0] jump = $signed(d_s) - $signed(y_sm1);
    wire signed [17:0] jump_abs = jump[17] ? -jump : jump;
    wire click_s = have_prev && ((d_abs > CLICK_ABS) || ((r2min < CLICK_R2_LOW) && (jump_abs > CLICK_JUMP)));

    reg signed [15:0] y_out;
    reg        y_valid;
    reg [1:0]  y_count;        // saturating: y index >= 1 means a real y exists
    always @(posedge clk) begin
        y_valid <= 1'b0;
        if (rst) begin
            have_prev <= 1'b0; d_p <= 0; y_pp <= 0; click_p <= 1'b0; ph_prev <= 0; r2_prev <= 0;
        end else if (v0) begin
            ph_prev <= ph; r2_prev <= r2; have_prev <= 1'b1;
            d_p <= d_s; y_pp <= y_sm1; click_p <= click_s;
            click <= click_p;
            if (have_prev) begin y_out <= y_sm1; y_valid <= 1'b1; end   // emits y[s-1], s>=1
        end
    end

    // ---- stage 2: halfband 2:1 on y (index j = s-1), output at even j >= 6 ----
    reg signed [15:0] yr [0:6];
    reg [31:0] yidx;
    reg signed [16:0] z;
    reg        z_valid;
    reg        y_valid_d;
    always @(posedge clk) y_valid_d <= y_valid & ~rst;
    integer k;
    // the 5-term sum in two clocks: partial sums registered from yr at the evaluation clock (yr
    // may shift again on the next clock), added the clock after
    wire signed [21:0] hb_a = 22'sd16 * $signed(yr[3]) - $signed(yr[0]) - $signed(yr[6]);
    wire signed [21:0] hb_b = 22'sd9 * ($signed(yr[2]) + $signed(yr[4]));
    reg  signed [21:0] hb_ra, hb_rb;
    reg        hb_v;
    wire signed [21:0] hb_acc = hb_ra + hb_rb;
    always @(posedge clk) begin
        z_valid <= 1'b0;
        if (rst) begin
            yidx <= 0;
            for (k = 0; k < 7; k = k + 1) yr[k] <= 16'sd0;
        end else if (y_valid) begin
            yr[0] <= y_out;
            for (k = 1; k < 7; k = k + 1) yr[k] <= yr[k-1];
            yidx <= yidx + 1;
        end
        // yr now holds y[j..j-6] for j = yidx-1; evaluate one clock after the shift
        hb_v <= !rst && y_valid_d && yidx >= 7 && yidx[0] == 1'b1;
        hb_ra <= hb_a; hb_rb <= hb_b;
        if (hb_v && !rst) begin
            z <= hb_acc >>> 5;
            z_valid <= 1'b1;
        end
    end

    // ---- stage 3: de-emphasis, y = (B0 x + B1 x1) * 16 + A1N y1 >> 14 (y with 4 frac bits) ----
    // Q14 coefficients per mode (ref.DEEMPH_ROOF / ref.deemph_coeffs; same pole, tau_p = 0.8162 us).
    // The Tank II has little or no pre-emphasis (MEASUREMENTS M76), so the NTSC roof over-filters.
    // Runtime coefficients need real multipliers: products on the z_valid clock, the sum and the
    // state update on the next (z_valid is >= 2 clocks apart), so the output stream is unchanged.
    reg signed [15:0] c_b0, c_b1, c_a1;
    always @(posedge clk)
        case (deemph)
            2'd0: begin c_b0 <= 16'sd3886;  c_b1 <= -16'sd2912; c_a1 <= 16'sd15410; end
            2'd1: begin c_b0 <= 16'sd6816;  c_b1 <= -16'sd5842; c_a1 <= 16'sd15410; end
            2'd2: begin c_b0 <= 16'sd10517; c_b1 <= -16'sd9543; c_a1 <= 16'sd15410; end
            default: begin c_b0 <= 16'sd16384; c_b1 <= 16'sd0; c_a1 <= 16'sd0; end
        endcase
    reg signed [16:0] x1;
    reg signed [23:0] yf1;
    reg signed [33:0] pa;                  // B0 x + B1 x1   (|.| < 2^31)
    reg signed [39:0] pb;                  // A1N y1         (|.| < 2^38)
    reg               d_v;
    wire signed [39:0] yf_w = ($signed(pa) * 40'sd16 + pb) >>> 14;
    always @(posedge clk) begin
        f20_valid <= 1'b0; d_v <= 1'b0;
        if (rst) begin
            x1 <= 0; yf1 <= 0;
        end else begin
            if (z_valid) begin
                pa <= c_b0 * z + c_b1 * x1;
                pb <= c_a1 * yf1;
                x1 <= z;
                d_v <= 1'b1;
            end
            if (d_v) begin
                yf1 <= yf_w[23:0];
                f20 <= yf_w[21:4];
                f20_valid <= 1'b1;
            end
        end
    end
endmodule
`default_nettype wire
