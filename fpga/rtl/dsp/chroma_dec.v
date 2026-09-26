// Y/C separation and colour demodulation on the 1280-point line-locked grid (THEORY §11).
// Bit-exact with fpga/model/chroma_ref.py chroma_decode().
//
//  * NCO: 16-bit phase, NTSC 11648 (91/512 turn), PAL 14528 (227/1024 turn) per sample.
//  * Burst: products over x in [112,144); decision (PAL V-switch, colour killer) at x = 150;
//    NCO phase correction applied at the end of the line.
//  * Y/C: comb (NTSC 1H, PAL 2H) or notch (2x - x[-2] - x[+2]) / 4.
//  * Demod: U = LPF(C sin), V = LPF(C cos), two boxcars (8, 6), x sat >> 20, PAL-D average.
// Output lags the input by 2 samples (continuous across lines).
// Pipelined for the 74.25 MHz receive clock (MEASUREMENTS M75): the burst products, the mixer
// and the saturation each take several clocks (with valid and x carried along), so the output
// sample stream is unchanged; only its latency in clocks grows. is_pal and the NCO increment
// are registered (quasi-static).
`default_nettype none
module chroma_dec #(
    parameter SIN_FILE = "sin_lut.hex",
    parameter COS_FILE = "cos_lut.hex"
) (
    input  wire               clk,
    input  wire               rst,
    input  wire signed [11:0] cv,
    input  wire               cv_valid,
    input  wire [10:0]        cv_x,
    input  wire signed [15:0] cv_ff_pal,    // video_timing feed-forward, with cv_x = 1279 (NCO units)
    input  wire signed [15:0] cv_ff_ntsc,
    input  wire               is_pal,
    input  wire               comb,         // 1 = comb, 0 = notch
    input  wire [15:0]        hue,          // NTSC hue offset (1/65536 turn)
    input  wire [7:0]         sat,          // 146 = nominal
    input  wire               lock_legacy,  // 1: old burst lock (flip on one line's bu > 0, no gate)
    output reg  signed [11:0] y_out,
    output reg  signed [15:0] u_out,
    output reg  signed [15:0] v_out,
    output reg  [10:0]        x_out,
    output reg                out_valid,
    output reg                killed,
    output reg                pal_sw_neg,
    // colour-lock recorder (top.v chroma_log): one record per line at the line end, when the NCO
    // correction is applied. Observation only; nothing here feeds back into the decoder.
    output reg                log_we = 1'b0,
    output reg  [15:0]        log_bu,        // burst U sum >>> 8, saturated
    output reg  [15:0]        log_bv,        // burst V sum >>> 8, saturated
    output reg  [15:0]        log_corr,      // NCO phase correction added at this line end
    output reg  [2:0]         log_fl         // {180-degree flip (bu > 0), V switch, killed}
);
    localparam integer LS = 1280;
    localparam [10:0] BX0 = 11'd112, BX1 = 11'd144, BDEC = 11'd150, XACT0 = 11'd160;
    localparam signed [31:0] KILL_BU = 32'sd60000;
    localparam [32:0]        LOCK_GATE = 33'd150000;   // |bu| + |bv| below: no burst, hold the loop
    // ACC (model/chroma_ref.py): burst magnitude max + 3/8 min of |bu|, |bv|, filtered 1/64 per line
    // on lines with a burst and no colour killer; next line's saturation = sat * g >> 8,
    // g = REF * 256 / filtered (serial divider), clamped to 128 .. 1023 (0.5 .. 4)
    localparam [25:0]        ACC_REF_PAL = 26'd1003168, ACC_REF_NTSC = 26'd1125856;

    reg signed [9:0] sin_rom [0:255];
    reg signed [9:0] cos_rom [0:255];

    reg        pal;                                   // registered is_pal (quasi-static)
    reg [15:0] inc;
    always @(posedge clk) begin pal <= is_pal; inc <= is_pal ? 16'd14528 : 16'd11648; end

    // ---------------- NCO ----------------
    reg [15:0] phi_line, phi_run;
    wire [15:0] phi_in = (cv_x == 0) ? phi_line : phi_run + inc;

    // ---------------- line buffers: 1H and 2H composite delay ----------------
    reg signed [11:0] lb1 [0:LS-1];
    reg signed [11:0] lb2 [0:LS-1];
    reg signed [11:0] d1_q, d2_q;

    // ---------------- burst ----------------
    reg signed [31:0] bu, bv, bv_prev;
    reg [3:0]  kill_cnt;
    // burst products: phase -> ROM -> product -> accumulate, one stage per clock. The window
    // ends at x = 143 and the decision is at x = 150, >= 14 clocks later, so the sums are complete.
    // Samples arrive >= 2 clocks apart, so sin and cos share one multiplier (DSP blocks are the
    // scarce resource): sin product on the sample's clock, cos on the next.
    reg        k1_v, k2_v, k3_v, kp_b, kp_c; reg [10:0] k1_x, k2_x, kh_x, k3_x;
    reg [7:0]  k1_kb; reg signed [11:0] k1_cv, k2_cv, kh_cv;
    reg signed [9:0] k2_s, k2_c, kh_c;
    reg signed [21:0] kp /* synthesis syn_dspstyle = "dsp" */;
    reg signed [21:0] k3_s, k3_c;
    wire signed [11:0] kma = k2_v ? k2_cv : kh_cv;
    wire signed [9:0]  kmb = k2_v ? k2_s : kh_c;
    always @(posedge clk) begin
        k1_v <= cv_valid && !rst && cv_x >= BX0 && cv_x < BX1;
        k1_x <= cv_x; k1_kb <= phi_in[15:8]; k1_cv <= cv;
        k2_v <= k1_v; k2_x <= k1_x; k2_cv <= k1_cv; k2_s <= sin_rom[k1_kb]; k2_c <= cos_rom[k1_kb];
        kp <= kma * kmb;
        kp_b <= k2_v; kp_c <= kp_b; k3_v <= kp_c;
        if (k2_v) begin kh_cv <= k2_cv; kh_c <= k2_c; kh_x <= k2_x; end
        if (kp_b) k3_s <= kp;                  // sin product (made on the sample's clock)
        if (kp_c) begin k3_c <= kp; k3_x <= kh_x; end
    end

    // Burst lock (chroma_ref.chroma_decode, MEASUREMENTS M79). The 180-degree flip is decided on
    // the two-line sum of burst U (the PAL +-45 degree swing cancels in it); after a flip the
    // previous line's values are carried into the new frame (negated). Lines without a burst hold
    // the loop, and the first line with one only primes the sums. The old rule (flip whenever this
    // line's bu > 0) can settle into a flip-every-line false lock: 180 degrees per line plus the PAL
    // swing looks like a burst at 0 +- 45 degrees, i.e. bands of hue-inverted lines.
    // Everything is decided at x = BDEC (the sums are final) and applied at the line end.
    reg  signed [31:0] bu_prev;
    reg         have_prev;
    // two steps (one sample each) so no clock chains the sums, the comparisons and the correction:
    // x = BDEC: error sum, |bu| and |bv|, two-line U sum; x = BDEC + 1: burst present;
    // x = BDEC + 2: flip and correction
    wire signed [32:0] err = pal ? (bv + bv_prev) : {bv[31], bv};
    wire [31:0] abu = bu[31] ? -bu : bu, abv = bv[31] ? -bv : bv;
    wire signed [32:0] usum = {bu[31], bu} + {bu_prev[31], bu_prev};
    reg  signed [32:0] err_r;
    reg         present_r, usum_pos, bu_pos, have_r;
    reg  [31:0] abu_r, abv_r;
    wire        hold = !present_r || !have_r;
    wire        flip = lock_legacy ? bu_pos : (!hold && (pal ? usum_pos : bu_pos));
    wire signed [32:0] err_sh = err_r >>> 9;
    wire [15:0] corr16 = (!lock_legacy && hold) ? 16'd0 : (-err_sh[15:0]) + (flip ? 16'd32768 : 16'd0);
    reg  [15:0] corr_r; reg flip_r;

    function [15:0] sat16(input signed [31:0] v);
        reg signed [31:0] s;
        begin s = v >>> 8; sat16 = (s > 32767) ? 16'h7FFF : (s < -32768) ? 16'h8000 : s[15:0]; end
    endfunction

    // ---------------- ACC state ----------------
    reg  [25:0] acc_mf;                    // filtered burst magnitude
    reg  [26:0] acc_mag; reg acc_upd, acc_go;
    reg  [9:0]  sat_eff, sat_nxt;          // saturation in use / for the next line (from the ACC)
    wire [31:0] acc_mx = (abu_r > abv_r) ? abu_r : abv_r, acc_mn = (abu_r > abv_r) ? abv_r : abu_r;
    wire signed [27:0] acc_dif = $signed({1'b0, acc_mag}) - $signed({2'b0, acc_mf});

    // ---------------- stage A register (input sample) ----------------
    reg signed [11:0] a_cv;
    reg [15:0] a_phi;
    reg [10:0] a_x;
    reg        a_v;
    always @(posedge clk) begin
        a_v <= 1'b0; log_we <= 1'b0;
        if (rst) begin
            phi_line <= 0; phi_run <= 0; bv_prev <= 0; bu_prev <= 0; have_prev <= 1'b0; kill_cnt <= 0;
            corr_r <= 0; flip_r <= 1'b0; present_r <= 1'b0; have_r <= 1'b0; err_r <= 0; usum_pos <= 1'b0; bu_pos <= 1'b0;
            killed <= 1'b0; pal_sw_neg <= 1'b0;
            acc_mf <= pal ? ACC_REF_PAL : ACC_REF_NTSC; acc_upd <= 1'b0; acc_go <= 1'b0;
        end else if (cv_valid) begin
            acc_go <= 1'b0;
            phi_run <= phi_in;
            a_cv <= cv; a_phi <= phi_in; a_x <= cv_x; a_v <= 1'b1;
            d1_q <= lb1[cv_x]; d2_q <= lb2[cv_x];
            lb1[cv_x] <= cv;
            lb2[cv_x] <= lb1[cv_x];
            if (cv_x == BDEC) begin
                pal_sw_neg <= pal && (bv < 0);
                err_r <= err; abu_r <= abu; abv_r <= abv;
                usum_pos <= usum > 0; bu_pos <= bu > 0; have_r <= have_prev;
            end
            if (cv_x == BDEC + 11'd1) begin
                present_r <= ({1'b0, abu_r} + {1'b0, abv_r}) >= LOCK_GATE;
                // colour killer from the registered |bu| (samples before XACT0 are blanked anyway)
                if (abu_r < KILL_BU) begin
                    kill_cnt <= (kill_cnt == 4'd8) ? 4'd8 : kill_cnt + 4'd1;
                    killed <= (kill_cnt >= 4'd7);
                end else begin
                    kill_cnt <= (kill_cnt == 4'd0) ? 4'd0 : kill_cnt - 4'd1;
                    killed <= (kill_cnt >= 4'd9);   // i.e. (kill_cnt-1) >= 8: never
                end
            end
            if (cv_x == BDEC + 11'd2) begin
                corr_r <= corr16; flip_r <= flip;
                acc_mag <= acc_mx[26:0] + {2'b0, acc_mn[26:2]} + {3'b0, acc_mn[26:3]};   // |bu|, |bv| < 2^25
                acc_upd <= present_r && !killed;
            end
            if (cv_x == BDEC + 11'd3) begin
                if (acc_upd) acc_mf <= acc_mf + {{4{acc_dif[27]}}, acc_dif[27:6]};   // += (mag - mf) >>> 6
                acc_go <= 1'b1;                                      // g and the next saturation
            end
            if (cv_x == LS - 1) begin
                // corr = -(err >> 9) (+ half turn if bu > 0), err = bv (+ bv_prev for PAL)
                // + feed-forward: the resampler moved the next line's start by the jump that
                // video_timing reports, so the subcarrier there moved by jump x inc (not in old-lock mode)
                phi_line <= phi_line + inc * 16'd1280 + corr_r
                            + (lock_legacy ? 16'd0 : pal ? cv_ff_pal : cv_ff_ntsc);
                if (lock_legacy) bv_prev <= bv;
                else if (present_r) begin
                    bu_prev <= flip_r ? -bu : bu; bv_prev <= flip_r ? -bv : bv; have_prev <= 1'b1;
                end else begin
                    bu_prev <= 0; bv_prev <= 0; have_prev <= 1'b0;
                end
                log_we <= 1'b1; log_bu <= sat16(bu); log_bv <= sat16(bv); log_corr <= corr_r;
                log_fl <= {flip_r, pal_sw_neg, killed};
            end
        end
    end

    // ACC: g = REF << 8 / acc_mf (restoring, 29 steps), clamp, then sat * g (10 shift-add steps):
    // ~42 clocks from x = BDEC + 3, long before the line end where sat_eff takes the result
    reg  [28:0] dv_n, dv_q; reg [25:0] dv_r, dv_d; reg [4:0] dv_k; reg dv_run = 1'b0;
    reg  [9:0]  acc_g; reg [17:0] acc_p; reg [3:0] acc_k; reg acc_mrun = 1'b0;
    wire [26:0] dv_t = {dv_r, dv_n[28]};
    wire        dv_ge = dv_t >= {1'b0, dv_d};
    wire [9:0]  gcl = (dv_q > 29'd1023) ? 10'd1023 : (dv_q < 29'd128) ? 10'd128 : dv_q[9:0];
    wire [25:0] acc_ref = pal ? ACC_REF_PAL : ACC_REF_NTSC;
    always @(posedge clk) begin
        if (rst) begin dv_run <= 1'b0; acc_mrun <= 1'b0; sat_nxt <= {2'b0, sat}; end
        else if (acc_go) begin
            dv_n <= {acc_ref[20:0], 8'd0};              // REF < 2^21
            dv_r <= 0; dv_q <= 0; dv_d <= acc_mf; dv_k <= 5'd29; dv_run <= 1'b1; acc_mrun <= 1'b0;
        end else if (dv_run) begin
            dv_r <= dv_ge ? dv_t[25:0] - dv_d : dv_t[25:0];
            dv_n <= dv_n << 1; dv_q <= {dv_q[27:0], dv_ge};
            dv_k <= dv_k - 5'd1;
            if (dv_k == 5'd1) begin dv_run <= 1'b0; acc_mrun <= 1'b1; acc_k <= 4'd15; end
        end else if (acc_mrun) begin
            if (acc_k == 4'd15) begin acc_g <= gcl; acc_p <= 0; acc_k <= 4'd0; end          // quotient final
            else if (acc_k == 4'd10) begin acc_mrun <= 1'b0; sat_nxt <= acc_p[17:8]; end
            else begin
                if (acc_g[acc_k]) acc_p <= acc_p + ({10'd0, sat} << acc_k);
                acc_k <= acc_k + 4'd1;
            end
        end
    end

    always @(posedge clk) begin
        if (rst) begin bu <= 0; bv <= 0; end
        else if (k3_v) begin
            if (k3_x == BX0) begin bu <= k3_s; bv <= k3_c; end
            else begin bu <= bu + k3_s; bv <= bv + k3_c; end
        end
    end

    // ---------------- stage B: separation + mixer (centre = s[1] after the shift) ----------------
    // When a_v shifts, the new centre sample is s_*[1] (old s[0]); its neighbours are
    // x-1 = s[2] (old s[1]) ... for the notch we need x-2 and x+2: use a 5-tap window.
    reg signed [11:0] w [0:4];
    reg [15:0] w_phi [0:4];
    reg signed [11:0] w_dl [0:4];
    reg [10:0] w_x [0:4];
    reg [2:0]  w_n;
    reg        w_v;
    integer i, i2, i3;
    always @(posedge clk) begin
        w_v <= 1'b0;
        if (rst) begin
            w_n <= 0;
            for (i = 0; i < 5; i = i + 1) begin w[i] <= 0; w_phi[i] <= 0; w_dl[i] <= 0; w_x[i] <= 0; end
        end
        else if (a_v) begin
            w[0] <= a_cv; w_phi[0] <= a_phi; w_dl[0] <= pal ? d2_q : d1_q; w_x[0] <= a_x;
            for (i = 1; i < 5; i = i + 1) begin
                w[i] <= w[i-1]; w_phi[i] <= w_phi[i-1]; w_dl[i] <= w_dl[i-1]; w_x[i] <= w_x[i-1];
            end
            if (w_n != 3'd5) w_n <= w_n + 3'd1;
            w_v <= (w_n >= 3'd2);
        end
    end
    // after the shift, centre (x - 2 relative to newest) is w[2]
    wire signed [13:0] notch_c = ($signed({w[2], 1'b0}) - w[0] - w[4]) >>> 2;
    wire signed [12:0] comb_c  = ($signed(w[2]) - $signed(w_dl[2])) >>> 1;
    wire signed [12:0] ch      = comb ? comb_c : notch_c[12:0];
    wire [15:0] kd_w = w_phi[2] + hue;
    // B1: filtered chroma, luma and the mixer phase
    reg signed [12:0] b1_ch, b1_y; reg [7:0] b1_kd; reg [10:0] b1_x; reg b1_v;
    // B2: sin / cos
    reg signed [12:0] b2_ch, b2_y; reg signed [9:0] b2_s, b2_c; reg [10:0] b2_x; reg b2_v;
    // B3: products (m_u, m_v with y_b, x_b, v_b as before); U and V share one multiplier
    reg signed [22:0] mp /* synthesis syn_dspstyle = "dsp" */;
    reg signed [22:0] m_u, m_v;
    reg signed [12:0] y_b, b3_ch, b3_y;
    reg signed [9:0]  b3_c;
    reg [10:0] x_b, b3_x;
    reg        v_b, mp_b, mp_c;
    wire signed [12:0] mma = b2_v ? b2_ch : b3_ch;
    wire signed [9:0]  mmb = b2_v ? b2_s : b3_c;
    always @(posedge clk) begin
        b1_v <= w_v;
        if (w_v) begin b1_ch <= ch; b1_y <= $signed(w[2]) - ch; b1_kd <= kd_w[15:8]; b1_x <= w_x[2]; end
        b2_v <= b1_v;
        if (b1_v) begin b2_ch <= b1_ch; b2_y <= b1_y; b2_s <= sin_rom[b1_kd]; b2_c <= cos_rom[b1_kd]; b2_x <= b1_x; end
        mp <= mma * mmb;
        mp_b <= b2_v; mp_c <= mp_b; v_b <= mp_c;
        if (b2_v) begin b3_ch <= b2_ch; b3_c <= b2_c; b3_y <= b2_y; b3_x <= b2_x; end
        if (mp_b) m_u <= mp;                   // U product (made on the sample's clock)
        if (mp_c) begin m_v <= mp; y_b <= b3_y; x_b <= b3_x; end
    end

    // ---------------- boxcars (8 then 6), reset per line at x == 0 ----------------
    reg signed [22:0] bu1 [0:7];
    reg signed [22:0] bv1 [0:7];
    reg signed [25:0] su1, sv1;
    reg signed [25:0] bu2 [0:5];
    reg signed [25:0] bv2 [0:5];
    reg signed [28:0] su2, sv2;
    reg signed [12:0] y_c, y_d;
    reg [10:0] x_c, x_d;
    reg        v_c, v_d;
    wire first = (x_b == 0);
    wire signed [25:0] su1_n = (first ? 26'sd0 : su1 - bu1[7]) + m_u;
    wire signed [25:0] sv1_n = (first ? 26'sd0 : sv1 - bv1[7]) + m_v;
    always @(posedge clk) begin
        v_c <= v_b;
        if (v_b) begin
            su1 <= su1_n; sv1 <= sv1_n;
            bu1[0] <= m_u; bv1[0] <= m_v;
            for (i2 = 1; i2 < 8; i2 = i2 + 1) begin
                bu1[i2] <= first ? 23'sd0 : bu1[i2-1];
                bv1[i2] <= first ? 23'sd0 : bv1[i2-1];
            end
            y_c <= y_b; x_c <= x_b;
        end
    end
    wire first_c = (x_c == 0);
    wire signed [28:0] su2_n = (first_c ? 29'sd0 : su2 - bu2[5]) + su1;
    wire signed [28:0] sv2_n = (first_c ? 29'sd0 : sv2 - bv2[5]) + sv1;
    always @(posedge clk) begin
        v_d <= v_c;
        if (v_c) begin
            su2 <= su2_n; sv2 <= sv2_n;
            bu2[0] <= su1; bv2[0] <= sv1;
            for (i3 = 1; i3 < 6; i3 = i3 + 1) begin
                bu2[i3] <= first_c ? 26'sd0 : bu2[i3-1];
                bv2[i3] <= first_c ? 26'sd0 : bv2[i3-1];
            end
            y_d <= y_c; x_d <= x_c;
        end
    end

    // ---------------- saturation, V switch, gating, PAL-D average ----------------
    // saturation: U and V share one multiplier (U on the sample's clock, V on the next)
    reg signed [39:0] sp /* synthesis syn_dspstyle = "dsp" */;
    reg signed [39:0] us, vs;
    reg signed [28:0] sv_h;
    reg signed [12:0] y_h, y_e; reg [10:0] x_h, x_e; reg v_e, sp_b, sp_c;
    wire signed [28:0] sma = v_d ? su2 : sv_h;
    // a line's saturation changes where its first sample reaches this multiplier (sat_nxt was
    // computed during the previous line), so every sample of a line uses the same value
    wire [9:0] sat_m = (v_d && x_d == 11'd0) ? sat_nxt : sat_eff;
    always @(posedge clk) begin
        if (rst) sat_eff <= {2'b0, sat}; else if (v_d) sat_eff <= sat_m;
        sp <= sma * $signed({1'b0, sat_m});
        sp_b <= v_d; sp_c <= sp_b; v_e <= sp_c;
        if (v_d) begin sv_h <= sv2; y_h <= y_d; x_h <= x_d; end
        if (sp_b) us <= sp;
        if (sp_c) begin vs <= sp; y_e <= y_h; x_e <= x_h; end
    end
    wire signed [17:0] uo0 = us >>> 20;
    wire signed [17:0] vo1 = vs >>> 20;
    wire signed [17:0] vo0 = pal_sw_neg ? -vo1 : vo1;
    wire gate = (x_e < XACT0) || killed;
    wire signed [17:0] uo = gate ? 18'sd0 : uo0;
    wire signed [17:0] vo = gate ? 18'sd0 : vo0;
    reg signed [17:0] pu [0:LS-1];
    reg signed [17:0] pv [0:LS-1];
    always @(posedge clk) begin
        out_valid <= 1'b0;
        if (v_e) begin
            if (pal) begin
                u_out <= (uo + pu[x_e]) >>> 1;
                v_out <= (vo + pv[x_e]) >>> 1;
                pu[x_e] <= uo; pv[x_e] <= vo;
            end else begin
                u_out <= uo[15:0]; v_out <= vo[15:0];
            end
            y_out <= y_e[11:0];
            x_out <= x_e;
            out_valid <= 1'b1;
        end
    end
    integer n;
    initial begin
        $readmemh(SIN_FILE, sin_rom); $readmemh(COS_FILE, cos_rom);
        // BSRAM powers up zeroed in the bitstream; mirror that for simulation
        for (n = 0; n < 1280; n = n + 1) begin lb1[n] = 0; lb2[n] = 0; pu[n] = 0; pv[n] = 0; end
    end
endmodule
`default_nettype wire
