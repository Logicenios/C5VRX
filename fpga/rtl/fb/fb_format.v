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
    // line tags from video_timing (latched at x_in == 0)
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
    // active window on the 1280 grid (x = 0 is the detected sync leading edge + 175 ns)
    wire [10:0] x0   = is_pal ? 11'd193 : 11'd179;
    wire [31:0] step = is_pal ? 32'd97090 : 32'd97767;          // Q16 grid samples per pixel
    wire [9:0]  first_line = is_pal ? 10'd22 : 10'd17;          // field line of the first active line
    wire [9:0]  n_lines    = is_pal ? 10'd288 : 10'd240;

    reg [9:0]  line_tag;
    reg        odd_tag, pal_tag, sof;
    reg [9:0]  last_line_no;
    reg        line_active;
    reg [31:0] spos;             // Q16 source position of the next output pixel
    reg [9:0]  px;               // next output pixel 0..719
    reg signed [11:0] y_p;
    reg signed [15:0] u_p, v_p;
    reg [7:0]  y0_q, cb_q;

    // colour conversion (Q10)
    wire signed [11:0] yblack = is_pal ? 12'sd0 : 12'sd56;
    wire signed [11:0] kY  = is_pal ? 12'sd320 : 12'sd323;
    wire signed [11:0] kCb = is_pal ? 12'sd251 : 12'sd253;
    wire signed [11:0] kCr = is_pal ? 12'sd178 : 12'sd180;

    // interpolation between the previous (x-1) and current (x) samples
    wire [15:0] fr = spos[15:0];
    wire signed [27:0] yi = $signed({y_p, 16'd0}) + ($signed(y_in) - $signed(y_p)) * $signed({1'b0, fr});
    wire signed [11:0] y_int = yi[27:16];
    wire signed [23:0] ys = ($signed(y_int) - yblack) * kY;              // Q10 codes above black
    wire signed [31:0] yc = ((ys >>> 10) * $signed({1'b0, contrast})) >>> 7;
    wire signed [31:0] yv = yc + 32'sd16 + brightness;
    wire [7:0] y8 = (yv < 0) ? 8'd0 : (yv > 255) ? 8'd255 : yv[7:0];
    wire signed [31:0] cbv = ((u_in * kCb) >>> 10) + 32'sd128;
    wire signed [31:0] crv = ((v_in * kCr) >>> 10) + 32'sd128;
    wire [7:0] cb8 = (cbv < 16) ? 8'd16 : (cbv > 240) ? 8'd240 : cbv[7:0];
    wire [7:0] cr8 = (crv < 16) ? 8'd16 : (crv > 240) ? 8'd240 : crv[7:0];

    wire [31:0] src_int = spos[31:16];
    always @(posedge clk) begin
        fifo_wr <= 1'b0;
        if (rst) begin
            line_active <= 1'b0; last_line_no <= 10'h3FF; px <= 0;
        end else if (in_valid) begin
            y_p <= y_in; u_p <= u_in; v_p <= v_in;
            if (x_in == 0) begin
                // new line: decide whether it is an active line, emit the descriptor
                sof <= (line_no < last_line_no);
                last_line_no <= line_no;
                if (locked && line_no >= first_line && line_no < first_line + n_lines) begin
                    line_active <= 1'b1;
                    line_tag <= line_no - first_line;
                    fifo_data <= {1'b1, (line_no == first_line), field_odd, is_pal, 23'd0, line_no - first_line};
                    fifo_wr <= 1'b1;
                end else line_active <= 1'b0;
                spos <= {5'd0, x0, 16'd0};
                px <= 0;
            end else if (line_active && px < 10'd720 && x_in == src_int[10:0] + 11'd1) begin
                // emit pixel px from samples (x-1, x); chroma sampled at even pixels
                if (!px[0]) begin
                    y0_q <= y8; cb_q <= cb8;
                end else begin
                    fifo_data <= {4'd0, cr8, y8, cb_q, y0_q};
                    fifo_wr <= 1'b1;
                end
                px <= px + 10'd1;
                spos <= spos + step;
            end
        end
    end
endmodule
`default_nettype wire
