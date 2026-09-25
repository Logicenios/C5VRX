// Active-line formatter (link clock domain): chroma_dec output -> 720 BT.601 pixels
// (53.33 us centred active line) -> 8-bit Y'CbCr 4:2:2 -> FIFO words.
//
// FIFO word (36 bits):
//   descriptor : [35] = 1, [34] = start of field, [33] = odd field, [32] = PAL, [8:0] = line
//   pixel pair : [35] = 0, [31:0] = {Cr, Y1, Cb, Y0}
// Levels (THEORY §9, §11; video_timing normalises sync to -300 mV, blanking 0):
//   PAL : black 0 mV, white 700 mV      -> Y' = 16 + Y * 219/700
//   NTSC: black 56 mV (7.5 IRE setup, x 300/286), white 750 mV -> Y' = 16 + (Y-56) * 219/694
//   Cb = 128 + U * 0.2452 (PAL) / 0.2473 (NTSC), Cr = 128 + V * 0.1739 / 0.1754
//   (U, V from chroma_dec are 1.497 x the colour-difference amplitude in mV)
`default_nettype none
module fb_format (
    input  wire               clk,
    input  wire               rst,
    input  wire signed [11:0] y_in,
    input  wire signed [15:0] u_in,
    input  wire signed [15:0] v_in,
    input  wire [10:0]        x_in,
    input  wire               in_valid,
    // line tags from video_timing, recorded with its x = 0 sample (tag_strobe = cv_valid at
    // cv_x == 0). video_timing's line_no register advances before the resampler emits the
    // next line's x = 0, so sampling line_no directly at chroma_dec's x = 0 (latency < 1 line)
    // would take the NEXT line's tags; the recorded tags belong to the line chroma_dec is
    // emitting (verified bit-exact against the host model, sim/tb_full.v).
    input  wire               tag_strobe,
    input  wire [9:0]         line_no,
    input  wire               field_odd,
    input  wire               is_pal,
    input  wire               locked,
    // user picture controls
    input  wire signed [7:0]  brightness,   // added to Y' (codes)
    input  wire [7:0]         contrast,     // Y' gain, 128 = 1.0
    // FIFO
    output reg  [35:0]        fifo_data,
    output reg                fifo_wr
);
    // PAL / NTSC constants, registered (is_pal is quasi-static)
    reg        pal;
    reg [10:0] x0;                // active window on the 1280 grid (x = 0 is the detected sync leading edge + 175 ns)
    reg [31:0] step;              // Q16 grid samples per pixel
    reg [9:0]  first_line;        // field line of the first active line
    reg [9:0]  n_lines;
    reg signed [11:0] yblack, kY, kCb, kCr;       // colour conversion (Q10)
    always @(posedge clk) begin
        pal <= is_pal;
        x0 <= is_pal ? 11'd193 : 11'd179;
        step <= is_pal ? 32'd97090 : 32'd97767;
        first_line <= is_pal ? 10'd22 : 10'd17;
        n_lines <= is_pal ? 10'd288 : 10'd240;
        yblack <= is_pal ? 12'sd0 : 12'sd56;
        kY  <= is_pal ? 12'sd320 : 12'sd323;
        kCb <= is_pal ? 12'sd251 : 12'sd253;
        kCr <= is_pal ? 12'sd178 : 12'sd180;
    end

    reg [9:0]  ln_cur = 0;
    reg        od_cur = 0;
    always @(posedge clk) if (tag_strobe) begin ln_cur <= line_no; od_cur <= field_odd; end
    reg [9:0]  last_line_no;
    reg        line_active;
    reg [31:0] spos;             // Q16 source position of the next output pixel
    reg [9:0]  px;               // next output pixel 0..719
    reg signed [11:0] y_p;

    // ---- input stage: which sample makes which pixel; line descriptors ----
    // The arithmetic follows in P1..P5 (three multiplies in series in one clock failed timing by
    // 23 ns at 74.25 MHz; MEASUREMENTS M75). Descriptors ride the same pipeline, so the FIFO
    // order is unchanged; the FIFO sees the same word stream, 5 clocks later.
    wire [31:0] src_int = spos[31:16];
    reg        e_pix, e_desc, e_even;
    reg [35:0] e_word;
    reg signed [11:0] e_yp, e_y;
    reg [15:0] e_fr;
    reg signed [15:0] e_u, e_v;
    always @(posedge clk) begin
        e_pix <= 1'b0; e_desc <= 1'b0;
        if (rst) begin
            line_active <= 1'b0; last_line_no <= 10'h3FF; px <= 0;
        end else if (in_valid) begin
            y_p <= y_in;
            if (x_in == 0) begin
                // new line: decide whether it is an active line, emit the descriptor
                last_line_no <= ln_cur;
                if (locked && ln_cur >= first_line && ln_cur < first_line + n_lines) begin
                    line_active <= 1'b1;
                    e_desc <= 1'b1;
                    e_word <= {1'b1, (ln_cur == first_line), od_cur, pal, 22'd0, ln_cur - first_line};   // 36 bits
                end else line_active <= 1'b0;
                spos <= {5'd0, x0, 16'd0};
                px <= 0;
            end else if (line_active && px < 10'd720 && x_in == src_int[10:0] + 11'd1) begin
                // emit pixel px from samples (x-1, x); chroma sampled at even pixels
                e_pix <= 1'b1; e_even <= !px[0];
                e_yp <= y_p; e_y <= y_in; e_fr <= spos[15:0]; e_u <= u_in; e_v <= v_in;
                px <= px + 10'd1;
                spos <= spos + step;
            end
        end
    end

    // ---- P1: interpolation product (between the previous (x-1) and current (x) samples) ----
    wire signed [27:0] prod_w = ($signed(e_y) - $signed(e_yp)) * $signed({1'b0, e_fr});
    reg        p1_pix, p1_desc, p1_even; reg [35:0] p1_word;
    reg signed [27:0] p1_prod; reg signed [11:0] p1_yp; reg signed [15:0] p1_u, p1_v;
    always @(posedge clk) begin
        p1_pix <= e_pix && !rst; p1_desc <= e_desc && !rst; p1_even <= e_even; p1_word <= e_word;
        p1_prod <= prod_w; p1_yp <= e_yp; p1_u <= e_u; p1_v <= e_v;
    end
    // ---- P2: interpolated luma; chroma products ----
    wire signed [27:0] yi = $signed({p1_yp, 16'd0}) + p1_prod;
    wire signed [31:0] cbm_w = p1_u * kCb;
    wire signed [31:0] crm_w = p1_v * kCr;
    reg        p2_pix, p2_desc, p2_even; reg [35:0] p2_word;
    reg signed [11:0] p2_y; reg signed [31:0] p2_cbm, p2_crm;
    always @(posedge clk) begin
        p2_pix <= p1_pix; p2_desc <= p1_desc; p2_even <= p1_even; p2_word <= p1_word;
        p2_y <= yi[27:16]; p2_cbm <= cbm_w; p2_crm <= crm_w;
    end
    // ---- P3: luma gain; chroma offset and limits ----
    wire signed [23:0] ys_w = ($signed(p2_y) - yblack) * kY;              // Q10 codes above black
    wire signed [31:0] cbv = (p2_cbm >>> 10) + 32'sd128;
    wire signed [31:0] crv = (p2_crm >>> 10) + 32'sd128;
    reg        p3_pix, p3_desc, p3_even; reg [35:0] p3_word;
    reg signed [23:0] p3_ys; reg [7:0] p3_cb, p3_cr;
    always @(posedge clk) begin
        p3_pix <= p2_pix; p3_desc <= p2_desc; p3_even <= p2_even; p3_word <= p2_word;
        p3_ys <= ys_w;
        p3_cb <= (cbv < 16) ? 8'd16 : (cbv > 240) ? 8'd240 : cbv[7:0];
        p3_cr <= (crv < 16) ? 8'd16 : (crv > 240) ? 8'd240 : crv[7:0];
    end
    // ---- P4: contrast ----
    wire signed [31:0] yc_w = ((p3_ys >>> 10) * $signed({1'b0, contrast})) >>> 7;
    reg        p4_pix, p4_desc, p4_even; reg [35:0] p4_word;
    reg signed [31:0] p4_yc; reg [7:0] p4_cb, p4_cr;
    always @(posedge clk) begin
        p4_pix <= p3_pix; p4_desc <= p3_desc; p4_even <= p3_even; p4_word <= p3_word;
        p4_yc <= yc_w; p4_cb <= p3_cb; p4_cr <= p3_cr;
    end
    // ---- P5: brightness, limits, pixel pairing, FIFO write ----
    wire signed [31:0] yv = p4_yc + 32'sd16 + brightness;
    wire [7:0] y8 = (yv < 0) ? 8'd0 : (yv > 255) ? 8'd255 : yv[7:0];
    reg [7:0]  y0_q, cb_q;
    always @(posedge clk) begin
        fifo_wr <= 1'b0;
        if (p4_desc) begin
            fifo_data <= p4_word; fifo_wr <= 1'b1;
        end else if (p4_pix) begin
            if (p4_even) begin
                y0_q <= y8; cb_q <= p4_cb;
            end else begin
                fifo_data <= {4'd0, p4_cr, y8, cb_q, y0_q};
                fifo_wr <= 1'b1;
            end
        end
    end
endmodule
`default_nettype wire
