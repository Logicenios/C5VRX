// FM front end, one I/Q byte per clock (link strobe, 40 MS/s).
//   phase LUT -> adjacent discriminator (k = 1, +-20 MHz, THEORY §5.1/§5.2)
//   -> click repair (THEORY §10) -> halfband 2:1 -> de-emphasis (THEORY §6.3)
// Bit-exact with fpga/model/ref.py fm_frontend(). Frequency word: 1 LSB = 610.35 Hz.
`default_nettype none
module fm_frontend #(
    parameter LUT_FILE = "phase_lut.hex",
    parameter signed [16:0] CLICK_ABS  = 17'sd22937,  // 14 MHz
    parameter        [8:0]  CLICK_R2_LOW = 9'd10,
    parameter signed [17:0] CLICK_JUMP = 18'sd8192,   // 5 MHz
    parameter signed [15:0] B0  = 16'sd3886,          // de-emphasis Q14 (ref.deemph_coeffs)
    parameter signed [15:0] B1  = -16'sd2912,
    parameter signed [15:0] A1N = 16'sd15410
) (
    input  wire               clk,
    input  wire               rst,
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
    reg signed [16:0] x1;
    reg signed [23:0] yf1;
    wire signed [39:0] acc = ($signed(B0) * $signed(z) + $signed(B1) * $signed(x1)) * 16
                             + $signed(A1N) * $signed(yf1);
    wire signed [39:0] yf_w = acc >>> 14;
    always @(posedge clk) begin
        f20_valid <= 1'b0;
        if (rst) begin
            x1 <= 0; yf1 <= 0;
        end else if (z_valid) begin
            x1 <= z;
            yf1 <= yf_w[23:0];
            f20 <= yf_w[21:4];
            f20_valid <= 1'b1;
        end
    end
endmodule
`default_nettype wire
