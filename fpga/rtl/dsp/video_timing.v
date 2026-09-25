// Sync separation, level normalisation and line-locked resampling (THEORY §8, §9, §11).
//
// Input : de-emphasised frequency f (1 LSB = 610 Hz) at 20 MS/s (f_valid every 2nd clock).
// Output: composite in millivolts (blanking 0, sync tip -300, white ~+700) on a
//         line-locked grid of 1280 points per line, plus line/field timing.
//
//  * Slicer    : midpoint of measured sync tip S and blanking B (THEORY §11); bootstraps
//                from a running minimum (released 1 LSB per 16 samples) + 400 kHz.
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
    output reg signed [17:0]  meas_blank,
    output wire [23:0]        dbg,                 // {have_levels, locked, good[5:0], miss[7:0], 8'd0}
    output wire               hsync_pulse,         // one clock per accepted-width H sync pulse
    output wire               broad_pulse          // one clock per broad (vertical) pulse
);
    localparam integer LS = 1280;

    // Clock: the receive chain runs on the pixel clock (74.25 / 74.176 MHz) with f_valid at
// 20 MS/s. The pipelined PLL and resampler need >= ~2.5 clocks per sample (3.7 here); at one
// sample every 2 clocks the resampler falls behind its 8-sample history.
    // ---------------- input history for the resampler ----------------
    reg signed [17:0] hist [0:7];
    reg [31:0] in_idx;
    always @(posedge clk)
        if (rst) in_idx <= 0;
        else if (f_valid) begin hist[in_idx[2:0]] <= f; in_idx <= in_idx + 1; end

    // ---------------- slicer, pulse classifier, level measurement ----------------
    reg signed [17:0] run_min, slice;
    reg [3:0]  rm_div;
    reg        have_levels, below;
    reg [14:0] no_sync;           // samples since the last accepted H sync (saturating)
    reg [11:0] low_cnt;
    reg [31:0] edge_idx, broad_idx, pend_edge;
    reg        hsync_evt, broad_evt;
    assign hsync_pulse = hsync_evt;
    assign broad_pulse = broad_evt;
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
            below <= 1'b0; low_cnt <= 0; run_min <= 0; rm_div <= 0; slice <= 0; have_levels <= 1'b0; tip_hold <= 0;
            meas_tip <= 0; meas_blank <= 0; porch_pending <= 1'b0; tip_acc <= 0; blank_acc <= 0;
            no_sync <= 0;
        end else if (f_valid) begin
            // level watchdog: levels latched from noise (VTX off) put the midpoint slice above the
            // real blanking level, after which no H sync is ever accepted and the levels never
            // update (hardware, VTX switched on after noise). No H sync for 16 lines (20480
            // samples): drop the levels and return to the bootstrap slicer.
            if (no_sync != 15'h7FFF) no_sync <= no_sync + 15'd1;
            if (no_sync == 15'd20480) begin have_levels <= 1'b0; porch_pending <= 1'b0; end
            // slow release: 1 LSB (610 Hz) per 16 samples = ~49 kHz per line. Releasing every
            // sample (~0.78 MHz per line) lifted the bootstrap slice above blanking when the
            // carrier is off-tune (real Tank II PAL: blanking -0.6 MHz, tip -1.5 MHz; MEASUREMENTS M66)
            rm_div <= rm_div + 4'd1;
            run_min <= (fl < run_min) ? fl : (rm_div == 4'd15 ? run_min + 18'sd1 : run_min);
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
                    no_sync <= 0;
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
    // The divider advances two steps per input sample (on f_valid and the clock after it), so
    // the new gain takes effect at the same sample whatever the clock rate: with a 40 MHz clock
    // and 20 MS/s samples that is one step per clock; with the 74.25 MHz receive clock and
    // gapped samples it is still 2 per sample (sim/tb_chain_a.v GAP=1 is bit-identical).
    reg  fv_d;
    always @(posedge clk) fv_d <= f_valid & ~rst;
    wire dv_tick = f_valid | fv_d;
    always @(posedge clk) begin
        if (rst) begin gain <= 0; dv_busy <= 1'b0; end
        else if (!dv_busy) begin
            if (hsync_evt && have_levels && amp > 19'sd400) begin
                dv_rem <= 0; dv_q <= 32'd300 << 16; dv_den <= amp[17:0]; dv_i <= 6'd32; dv_busy <= 1'b1;
            end
        end else if (!dv_tick) begin
            // wait for the next sample tick
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
    reg        per_wr;                    // period written this clock (the resampler's step follows)
    reg [7:0]  good;
    reg [7:0]  miss;
    assign dbg = {have_levels, locked, good[5:0], miss, 8'd0};
    // positions are sample indices in Q16 and wrap every 2^32 samples (3.6 min at 20 MS/s):
    // differences are taken modulo 2^48 and read as signed, so the wrap is invisible.
    //
    // Pipelined for the 74.25 MHz receive clock (the combinational version chained three 48-bit
    // adders and failed timing by up to 5 ns; MEASUREMENTS M75): the prediction is a register,
    // an H sync is latched (ev_pend) and processed in two clocks (A: errors, B: update) once the
    // prediction is settled, and after every PLL write a 3-clock hold (pll_hold) keeps the coast
    // check and the resampler start off stale values. All PLL events are tens of samples apart
    // (sync end, line end, coast at +7 us), so the output stream is unchanged.
    reg [47:0] next_pred, pred_late;
    reg [1:0]  pll_hold;
    reg        ev_pend, ev_a;
    reg [47:0] ev_edge, ev_d;
    reg signed [48:0] perr_r;
    wire [47:0] edge_q = {edge_idx, 16'd0};
    wire [47:0] now_q = {in_idx, 16'd0};
    wire [47:0] late_m = now_q - pred_late;
    wire coast = locked && !late_m[47] && (late_m < (48'd1 << 46));   // no edge by +7 us after prediction
    // Corrections computed in an explicitly signed context (an unsigned operand would
    // turn >>> into a logical shift and a small negative error into a huge one).
    wire signed [49:0] phase_corr = perr_r >>> 3;
    wire signed [49:0] freq_corr  = perr_r >>> 8;
    wire [47:0] line_next_trk   = $unsigned($signed({2'b0, next_pred}) + phase_corr);
    wire [47:0] period_next_trk = $unsigned($signed({2'b0, period}) + freq_corr);
    reg  per_wr_n;                        // any line_pos / period write this clock
    wire [47:0] pm_w = ev_edge - next_pred;

    always @(posedge clk) begin
        next_pred <= line_pos + period;
        pred_late <= next_pred + (48'd140 << 16);
        pll_hold  <= per_wr_n ? 2'd3 : (pll_hold != 0) ? pll_hold - 2'd1 : 2'd0;
    end
    always @(posedge clk) begin
        per_wr <= 1'b0; per_wr_n <= 1'b0; ev_a <= 1'b0;
        if (rst) begin
            period <= P_PAL; line_pos <= 0; locked <= 1'b0; good <= 0; miss <= 0; is_pal <= 1'b1;
            per_wr <= 1'b1; per_wr_n <= 1'b1; ev_pend <= 1'b0;
        end else begin
            if (hsync_evt) begin ev_pend <= 1'b1; ev_edge <= edge_q; end
            if (ev_pend && !ev_a && !per_wr_n && pll_hold == 0 && !hsync_evt) begin
                // A: errors against the settled prediction
                ev_pend <= 1'b0; ev_a <= 1'b1;
                ev_d <= ev_edge - line_pos;
                perr_r <= $signed({pm_w[47], pm_w});
            end else if (ev_a && !locked) begin
                // B (unlocked): period from successive edges
                if (line_pos != 0 && ev_d > (48'd1260 << 16) && ev_d < (48'd1290 << 16)) begin
                    period <= ev_d; per_wr <= 1'b1;
                    good <= good + 8'd1;
                    if (good == 8'd8) begin locked <= 1'b1; miss <= 0; end
                end else good <= 0;
                line_pos <= ev_edge; per_wr_n <= 1'b1;
            end else if (ev_a && locked && perr_r > -$signed(49'd24 << 16) && perr_r < $signed(49'd24 << 16)) begin
                // B (locked): phase and frequency correction
                line_pos <= line_next_trk;
                period <= period_next_trk; per_wr <= 1'b1; per_wr_n <= 1'b1;
                miss <= 0;
            end else if (coast && !ev_pend && !ev_a && !per_wr_n && pll_hold == 0) begin
                line_pos <= next_pred; per_wr_n <= 1'b1;                 // flywheel
                miss <= miss + 8'd1;
                if (miss == 8'd40) begin locked <= 1'b0; good <= 0; end  // > vblank: lost
            end
        end
        is_pal <= period > (48'd1275 << 16);
    end

    // ---------------- resampler ----------------
    reg [47:0] rs_pos, rs_line;
    reg [10:0] rs_x;
    reg        rs_on;
    // step = period / 1280 ~= period * 52429 / 2^26 (rel. error 4e-6; re-anchored every line).
    // The period changes once per line, so the product is computed serially (shift-and-add over
    // the 16 bits of 52429, 17 clocks, one adder) instead of in a 48 x 16 DSP multiplier (DSP
    // blocks are the scarce resource; MEASUREMENTS M75). The resampler pauses until the new
    // step is ready, so no sample uses a stale step: the pause only delays when a sample is
    // produced (the 8-sample history covers ~5 samples of lag), never its value.
    localparam [15:0] K_STEP = 16'd52429;
    reg [63:0] sm_acc, sm_a;
    reg [4:0]  sm_i;
    reg        sm_busy;
    reg [47:0] rs_step;
    wire       step_wait = sm_busy;
    always @(posedge clk) begin
        if (rst) begin
            sm_busy <= 1'b1; sm_i <= 5'd16; sm_acc <= 0; sm_a <= {16'd0, P_PAL};
        end else if (per_wr) begin
            sm_busy <= 1'b1; sm_i <= 5'd16; sm_acc <= 0; sm_a <= {16'd0, period};
        end else if (sm_busy) begin
            if (sm_i == 0) begin
                rs_step <= sm_acc[63:26]; sm_busy <= 1'b0;
            end else begin
                // bit (16 - sm_i) of K, LSB first
                if (K_STEP[16 - sm_i]) sm_acc <= sm_acc + sm_a;
                sm_a <= sm_a << 1;
                sm_i <= sm_i - 5'd1;
            end
        end
    end
    wire [31:0] ri = rs_pos[47:16];
    wire [15:0] rf = rs_pos[15:0];
    // ready is precomputed a clock ahead; after a sample the next clock is skipped so the
    // precomputed flag always sees the advanced position
    reg rdy_r, rs_fired;
    always @(posedge clk) rdy_r <= (in_idx >= ri + 2) && (in_idx - ri <= 7);
    wire rs_ready = rs_on && rdy_r && !rs_fired && !per_wr && !step_wait;
    wire signed [17:0] s0 = hist[ri[2:0]];
    wire signed [17:0] s1 = hist[ri[2:0] + 3'd1];

    // Next line start: this line's PLL-corrected start + P when the PLL has already
    // processed this line's edge (line_pos within +-P/2 of rs_line), else coast. Registered:
    // it is used at the line end, ~1200 samples after rs_line and the PLL last changed.
    reg signed [48:0] adiff;
    reg        a_near;
    reg [47:0] rs_line_p, anchor_next;
    always @(posedge clk) begin
        adiff <= $signed({1'b0, line_pos}) - $signed({1'b0, rs_line});
        a_near <= adiff > -$signed({2'b0, period[47:1]}) && adiff < $signed({2'b0, period[47:1]});
        rs_line_p <= rs_line + period;
        anchor_next <= a_near ? next_pred : rs_line_p;
    end

    // p0: capture everything the output sample depends on at the resampling clock (blanking and
    // gain too, so an update at an H sync lands exactly as before). The value is then computed in
    // p1..p4: in one clock (two multiplies in series) it failed timing by 14 ns at 74.25 MHz
    // (MEASUREMENTS M75). All outputs are delayed by the same 4 clocks, so the output stream is
    // the single-clock one shifted by 4 (sim/tb_chain_a, sim/tb_full).
    reg        p0_v, p0_ls, ls_int;
    reg [10:0] p0_x;
    reg signed [17:0] p0_s0, p0_s1, p0_blank;
    reg [15:0] p0_rf;
    reg [17:0] p0_gain;
    always @(posedge clk) begin
        p0_v <= 1'b0;
        ls_int <= 1'b0;
        rs_fired <= 1'b0;
        if (rst || !locked) begin
            rs_on <= 1'b0;
        end else if (!rs_on) begin
            if (pll_hold == 0 && !per_wr_n) begin
                rs_line <= next_pred; rs_pos <= next_pred; rs_x <= 0; rs_on <= 1'b1;
            end
        end else if (rs_ready) begin
            rs_fired <= 1'b1;
            p0_v <= 1'b1; p0_x <= rs_x; p0_ls <= (rs_x == 0);
            p0_s0 <= s0; p0_s1 <= s1; p0_rf <= rf; p0_blank <= meas_blank; p0_gain <= gain;
            ls_int <= (rs_x == 0);
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

    // p1: interpolation product
    reg        p1_v, p1_ls; reg [10:0] p1_x;
    reg signed [35:0] p1_prod;
    reg signed [17:0] p1_s0, p1_blank;
    reg [17:0] p1_gain;
    // p2: interpolated value minus blanking
    reg        p2_v, p2_ls; reg [10:0] p2_x;
    reg signed [18:0] p2_rel;
    reg [17:0] p2_gain;
    // p3: gain
    reg        p3_v, p3_ls; reg [10:0] p3_x;
    reg signed [37:0] p3_mv;
    wire signed [18:0] fi2 = $signed(p1_s0) + $signed(p1_prod[35:16]);
    wire signed [21:0] mv_i = p3_mv[37:16];
    always @(posedge clk) begin
        p1_v <= p0_v; p1_ls <= p0_ls; p1_x <= p0_x;
        p1_prod <= ($signed(p0_s1) - $signed(p0_s0)) * $signed({1'b0, p0_rf});
        p1_s0 <= p0_s0; p1_blank <= p0_blank; p1_gain <= p0_gain;
        p2_v <= p1_v; p2_ls <= p1_ls; p2_x <= p1_x;
        p2_rel <= fi2 - p1_blank; p2_gain <= p1_gain;
        p3_v <= p2_v; p3_ls <= p2_ls; p3_x <= p2_x;
        p3_mv <= p2_rel * $signed({1'b0, p2_gain});
        // p4: outputs
        cv_valid <= p3_v && !rst;
        line_start <= p3_ls && p3_v && !rst;
        if (p3_v) begin
            cv <= (mv_i > 22'sd1023) ? 12'sd1023 : (mv_i < -22'sd1024) ? -12'sd1024 : mv_i[11:0];
            cv_x <= p3_x;
        end
    end

    // ---------------- vertical ----------------
    reg [9:0] vline;
    reg [47:0] into1, into2;
    reg        bv1, bv2;
    always @(posedge clk) begin bv1 <= broad_evt && vline > 10'd100 && !rst; bv2 <= bv1; end
    wire [47:0] broad_q = {broad_idx, 16'd0};
    reg [9:0] line_no_i; reg field_odd_i, field_start_i;
    always @(posedge clk) begin
        field_start_i <= 1'b0;
        if (rst) begin
            vline <= 0; line_no_i <= 0; field_odd_i <= 1'b0;
        end else begin
            // field parity: position of the broad pulse within its line (mod P), two clocks
            if (bv1) into2 <= (into1 >= period) ? into1 - period : into1;
            if (bv2) begin
                field_odd_i <= !(into2 > (period >> 2) && into2 < (period - (period >> 2)));
                field_start_i <= 1'b1;
            end
            if (broad_evt && vline > 10'd100) begin
                into1 <= broad_q - line_pos;
                vline <= 0;
            end else if (ls_int) begin
                line_no_i <= vline;
                if (vline != 10'h3FF) vline <= vline + 10'd1;
            end
        end
    end
    // line / field outputs delayed by the same 4 clocks as the sample pipeline (p0..p4)
    reg [9:0] ln_d [0:2]; reg [2:0] fo_d, fs_d;
    integer dk;
    always @(posedge clk) begin
        ln_d[0] <= line_no_i; fo_d[0] <= field_odd_i; fs_d[0] <= field_start_i;
        for (dk = 1; dk < 3; dk = dk + 1) begin ln_d[dk] <= ln_d[dk-1]; fo_d[dk] <= fo_d[dk-1]; fs_d[dk] <= fs_d[dk-1]; end
        line_no <= ln_d[2]; field_odd <= fo_d[2]; field_start <= fs_d[2];
    end
endmodule
`default_nettype wire
