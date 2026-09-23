// Sync separation, level normalisation and line-locked resampling (THEORY §8, §9, §11).
//
// Input : de-emphasised frequency f (1 LSB = 610 Hz) at 20 MS/s (f_valid every 2nd clock).
// Output: composite in millivolts (blanking 0, sync tip -300, white ~+700) on a
//         line-locked grid of 1280 points per line, plus line/field timing.
//
//  * Slicer    : midpoint of measured sync tip S and blanking B (THEORY §11); bootstraps
//                from a slowly-released running minimum + 400 kHz.
//  * Levels    : S = mean of samples 20..83 (64) inside the sync pulse, B = mean of samples
//                110..173 after the leading edge (back porch; burst averages out),
//                IIR 1/8 per line. G = 300 mV / (B - S) (serial divider, per line).
//  * H-PLL     : period P and line start in Q16 input samples, locked to sync leading
//                edges (P 1/256, phase 1/8), with a flywheel through vertical blanking.
//  * Resampler : 1280 points per line, step P/1280, linear interpolation.
//  * Vertical  : first broad pulse of a field -> field start; parity from its position
//                within the line (0H = odd field, H/2 = even field).
`default_nettype none
module video_timing (
    input  wire               clk,
    input  wire               rst,
    input  wire signed [17:0] f,
    input  wire               f_valid,
    output reg  signed [11:0] cv,
    output reg                cv_valid,
    output reg  [10:0]        cv_x,
    output reg                line_start,
    output reg  [9:0]         line_no,
    output reg                field_odd,
    output reg                field_start,
    output reg                is_pal,
    output reg                locked,
    output reg signed [17:0]  meas_tip,
    output reg signed [17:0]  meas_blank
);
    localparam integer LS = 1280;

    // ---------------- input history for the resampler ----------------
    reg signed [17:0] hist [0:7];
    reg [31:0] in_idx;
    always @(posedge clk)
        if (rst) in_idx <= 0;
        else if (f_valid) begin hist[in_idx[2:0]] <= f; in_idx <= in_idx + 1; end

    // ---------------- slicer, pulse classifier, level measurement ----------------
    reg signed [17:0] run_min, slice;
    reg        have_levels, below;
    reg [11:0] low_cnt;
    reg [31:0] edge_idx, broad_idx, pend_edge;
    reg        hsync_evt, broad_evt;
    reg signed [25:0] tip_acc, tip_hold, blank_acc;
    // Slicer input: 8-sample moving average (-13 dB at 3.58 MHz, -18 dB at 4.43 MHz),
    // so burst troughs (-20 IRE, exactly at the 50 % slice of a 40 IRE sync) cannot
    // start a false pulse. Pulse widths are unchanged; edges shift by 3.5 samples.
    reg signed [17:0] fh [0:7];
    reg signed [20:0] fsum;
    wire signed [17:0] fl = fsum >>> 3;
    integer j;
    always @(posedge clk)
        if (rst) begin fsum <= 0; for (j = 0; j < 8; j = j + 1) fh[j] <= 0; end
        else if (f_valid) begin
            fsum <= fsum + f - fh[7];
            fh[0] <= f;
            for (j = 1; j < 8; j = j + 1) fh[j] <= fh[j-1];
        end
    reg        porch_pending;
    wire [31:0] since_pend = in_idx - pend_edge;

    always @(posedge clk) begin
        hsync_evt <= 1'b0;
        broad_evt <= 1'b0;
        if (rst) begin
            below <= 1'b0; low_cnt <= 0; run_min <= 0; slice <= 0; have_levels <= 1'b0; tip_hold <= 0;
            meas_tip <= 0; meas_blank <= 0; porch_pending <= 1'b0; tip_acc <= 0; blank_acc <= 0;
        end else if (f_valid) begin
            run_min <= (fl < run_min) ? fl : run_min + 18'sd1;
            slice <= have_levels ? ((meas_tip + meas_blank) >>> 1) : (run_min + 18'sd655);

            if (fl < slice) begin
                if (!below) begin below <= 1'b1; low_cnt <= 12'd1; tip_acc <= 0; end
                else begin
                    if (low_cnt != 12'hFFF) low_cnt <= low_cnt + 12'd1;
                    if (low_cnt >= 12'd20 && low_cnt < 12'd84) tip_acc <= tip_acc + f;   // 64 samples, inside the flat bottom
                end
            end else if (below) begin
                below <= 1'b0;
                if (low_cnt >= 12'd70 && low_cnt <= 12'd120) begin          // H sync (3.5..6 us)
                    hsync_evt <= 1'b1;
                    edge_idx <= in_idx - {20'd0, low_cnt};
                    pend_edge <= in_idx - {20'd0, low_cnt};
                    porch_pending <= 1'b1;
                    tip_hold <= tip_acc;
                    blank_acc <= 0;
                end else if (low_cnt >= 12'd360) begin                      // broad pulse (>18 us)
                    broad_evt <= 1'b1;
                    broad_idx <= in_idx - {20'd0, low_cnt};
                end
            end

            if (porch_pending) begin
                if (since_pend >= 110 && since_pend < 174) blank_acc <= blank_acc + f;
                if (since_pend == 174) begin
                    porch_pending <= 1'b0;
                    meas_tip   <= have_levels ? meas_tip   + (((tip_hold >>> 6)  - meas_tip)   >>> 3) : (tip_hold >>> 6);
                    meas_blank <= have_levels ? meas_blank + (((blank_acc >>> 6) - meas_blank) >>> 3) : (blank_acc >>> 6);
                    have_levels <= 1'b1;
                end
            end
        end
    end

    // ---------------- gain G = 300 * 2^16 / (B - S), serial restoring divider ----------------
    reg [17:0] gain;              // Q16 mV per f-LSB (5000..30000 for 0.6..4 MHz sync amplitude)
    reg [31:0] dv_rem, dv_q;
    reg [17:0] dv_den;
    reg [5:0]  dv_i;
    reg        dv_busy;
    wire signed [18:0] amp = meas_blank - meas_tip;
    wire [32:0] dv_trial = {dv_rem[31:0], dv_q[31]};
    always @(posedge clk) begin
        if (rst) begin gain <= 0; dv_busy <= 1'b0; end
        else if (!dv_busy) begin
            if (hsync_evt && have_levels && amp > 19'sd400) begin
                dv_rem <= 0; dv_q <= 32'd300 << 16; dv_den <= amp[17:0]; dv_i <= 6'd32; dv_busy <= 1'b1;
            end
        end else if (dv_i == 0) begin
            gain <= (dv_q > 32'h3FFFF) ? 18'h3FFFF : dv_q[17:0]; dv_busy <= 1'b0;
        end else begin
            // shift the dividend bit into the remainder, subtract when possible
            if (dv_trial >= {15'd0, dv_den}) begin
                dv_rem <= dv_trial[31:0] - {14'd0, dv_den};
                dv_q <= {dv_q[30:0], 1'b1};
            end else begin
                dv_rem <= dv_trial[31:0];
                dv_q <= {dv_q[30:0], 1'b0};
            end
            dv_i <= dv_i - 6'd1;
        end
    end

    // ---------------- H-PLL with flywheel ----------------
    localparam [47:0] P_NTSC = 48'd1271 * 65536 + 48'd7282;   // 1271.111 samples = 63.5556 us
    localparam [47:0] P_PAL  = 48'd1280 * 65536;              // 1280.000 samples = 64 us
    reg [47:0] period, line_pos;
    reg [7:0]  good;
    reg [7:0]  miss;
    wire [47:0] edge_q = {edge_idx, 16'd0};
    wire [47:0] next_pred = line_pos + period;
    wire signed [48:0] perr = $signed({1'b0, edge_q}) - $signed({1'b0, next_pred});
    wire [47:0] now_q = {in_idx, 16'd0};
    wire coast = locked && (now_q > next_pred + (48'd140 << 16));   // no edge by +7 us after prediction
    // Corrections computed in an explicitly signed context (an unsigned operand would
    // turn >>> into a logical shift and a small negative error into a huge one).
    wire signed [49:0] phase_corr = perr >>> 3;
    wire signed [49:0] freq_corr  = perr >>> 8;
    wire [47:0] line_next_trk   = $unsigned($signed({2'b0, next_pred}) + phase_corr);
    wire [47:0] period_next_trk = $unsigned($signed({2'b0, period}) + freq_corr);

    always @(posedge clk) begin
        if (rst) begin
            period <= P_PAL; line_pos <= 0; locked <= 1'b0; good <= 0; miss <= 0; is_pal <= 1'b1;
        end else if (hsync_evt && !locked) begin
            if (line_pos != 0 && edge_q - line_pos > (48'd1260 << 16) && edge_q - line_pos < (48'd1290 << 16)) begin
                period <= edge_q - line_pos;
                good <= good + 8'd1;
                if (good == 8'd8) begin locked <= 1'b1; miss <= 0; end
            end else good <= 0;
            line_pos <= edge_q;
        end else if (hsync_evt && locked && perr > -$signed(49'd24 << 16) && perr < $signed(49'd24 << 16)) begin
            line_pos <= line_next_trk;
            period <= period_next_trk;
            miss <= 0;
        end else if (coast) begin
            line_pos <= next_pred;                                   // flywheel
            miss <= miss + 8'd1;
            if (miss == 8'd40) begin locked <= 1'b0; good <= 0; end  // > vblank: lost
        end
        is_pal <= period > (48'd1275 << 16);
    end

    // ---------------- resampler ----------------
    reg [47:0] rs_pos, rs_line;
    reg [10:0] rs_x;
    reg        rs_on;
    // step = period / 1280 ~= period * 52429 / 2^26 (rel. error 4e-6; re-anchored every line)
    wire [63:0] step_w = period * 64'd52429;
    wire [47:0] rs_step = step_w[63:26];
    wire [31:0] ri = rs_pos[47:16];
    wire [15:0] rf = rs_pos[15:0];
    wire rs_ready = rs_on && (in_idx >= ri + 2) && (in_idx - ri <= 7);
    wire signed [17:0] s0 = hist[ri[2:0]];
    wire signed [17:0] s1 = hist[ri[2:0] + 3'd1];
    wire signed [35:0] prod = ($signed(s1) - $signed(s0)) * $signed({1'b0, rf[15:0]});
    wire signed [18:0] fi = $signed(s0) + $signed(prod[35:16]);
    wire signed [18:0] rel = fi - meas_blank;
    wire signed [37:0] mv = rel * $signed({1'b0, gain});
    wire signed [21:0] mv_i = mv[37:16];

    // Next line start: this line's PLL-corrected start + P when the PLL has already
    // processed this line's edge (line_pos within +-P/2 of rs_line), else coast.
    wire signed [48:0] adiff = $signed({1'b0, line_pos}) - $signed({1'b0, rs_line});
    wire [47:0] anchor_next = (adiff > -$signed({2'b0, period[47:1]}) && adiff < $signed({2'b0, period[47:1]}))
                              ? line_pos + period : rs_line + period;

    always @(posedge clk) begin
        cv_valid <= 1'b0;
        line_start <= 1'b0;
        if (rst || !locked) begin
            rs_on <= 1'b0;
        end else if (!rs_on) begin
            rs_line <= next_pred; rs_pos <= next_pred; rs_x <= 0; rs_on <= 1'b1;
        end else if (rs_ready) begin
            cv <= (mv_i > 22'sd1023) ? 12'sd1023 : (mv_i < -22'sd1024) ? -12'sd1024 : mv_i[11:0];
            cv_valid <= 1'b1;
            cv_x <= rs_x;
            line_start <= (rs_x == 0);
            if (rs_x == LS - 1) begin
                rs_x <= 0;
                // next line starts one PLL period after this line's (corrected) start
                rs_line <= anchor_next;
                rs_pos  <= anchor_next;
            end else begin
                rs_x <= rs_x + 11'd1;
                rs_pos <= rs_pos + rs_step;
            end
        end
    end

    // ---------------- vertical ----------------
    reg [9:0] vline;
    reg [47:0] into;
    wire [47:0] broad_q = {broad_idx, 16'd0};
    always @(posedge clk) begin
        field_start <= 1'b0;
        if (rst) begin
            vline <= 0; line_no <= 0; field_odd <= 1'b0;
        end else begin
            if (broad_evt && vline > 10'd100) begin
                // position of the broad pulse within its line (mod P)
                into = broad_q - line_pos;
                if (into >= period) into = into - period;
                field_odd <= !(into > (period >> 2) && into < (period - (period >> 2)));
                field_start <= 1'b1;
                vline <= 0;
            end else if (line_start) begin
                line_no <= vline;
                if (vline != 10'h3FF) vline <= vline + 10'd1;
            end
        end
    end
endmodule
`default_nettype wire
