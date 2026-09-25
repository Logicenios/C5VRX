// Internal PAL test source (receive chain, pixel-clock domain): 75 % EBU colour bars with a white line that
// moves down one line per field, in the format chroma_dec + video_timing hand to fb_format.
// Selected from the menu ("Test pattern"); it exercises the whole frame-buffer path (FIFO,
// fb_ctrl, SDRAM, scaler, HDMI) without a VTX.
//
// Timing: 20 MS/s samples (every second `en` tick at 40 MS/s), 1280 samples per 64 us line, fields of 312 and
// 313 lines alternating (odd/even), like video_timing's resampled output.
// Levels (fb_format input units): y = luma in mV (black 0, white 700), u / v = 1.497 x the
// colour-difference amplitude in mV. 75 % bars: Y = .299R + .587G + .114B, U = .492 (B - Y),
// V = .877 (R - Y) with R, G, B = 0 or 525 mV; through fb_format they give the BT.601 codes,
// e.g. yellow Y'/Cb/Cr = 161/44/142, red 65/100/212.
`default_nettype none
module test_src (
    input  wire               clk,
    input  wire               rst,
    input  wire               en,             // 40 MS/s sample tick (the link sample rate)
    output reg  signed [11:0] y = 0,
    output reg  signed [15:0] u = 0,
    output reg  signed [15:0] v = 0,
    output reg  [10:0]        x = 0,
    output reg                valid = 1'b0,
    output reg  [9:0]         line = 0,
    output reg                odd = 1'b1
);
    reg        ph = 1'b0;
    reg [10:0] xc = 0;
    reg [9:0]  lc = 0;
    reg [7:0]  fcnt = 0;
    wire [9:0] nlines = odd ? 10'd312 : 10'd313;

    // bar index across fb_format's PAL active window (x = 193 .. 1260, 8 bars of ~134 samples)
    wire [2:0] bar = (xc < 11'd327) ? 3'd0 : (xc < 11'd460) ? 3'd1 : (xc < 11'd594) ? 3'd2 :
                     (xc < 11'd727) ? 3'd3 : (xc < 11'd860) ? 3'd4 : (xc < 11'd994) ? 3'd5 :
                     (xc < 11'd1127) ? 3'd6 : 3'd7;
    reg signed [11:0] by; reg signed [15:0] bu, bv;
    always @(*) begin
        case (bar)
            3'd0: begin by = 12'sd525; bu =  16'sd0;   bv =  16'sd0;   end   // white
            3'd1: begin by = 12'sd465; bu = -16'sd343; bv =  16'sd79;  end   // yellow
            3'd2: begin by = 12'sd368; bu =  16'sd116; bv = -16'sd483; end   // cyan
            3'd3: begin by = 12'sd308; bu = -16'sd227; bv = -16'sd405; end   // green
            3'd4: begin by = 12'sd217; bu =  16'sd227; bv =  16'sd405; end   // magenta
            3'd5: begin by = 12'sd157; bu = -16'sd116; bv =  16'sd483; end   // red
            3'd6: begin by = 12'sd60;  bu =  16'sd343; bv = -16'sd79;  end   // blue
            default: begin by = 12'sd0; bu = 16'sd0;   bv =  16'sd0;   end   // black
        endcase
    end
    // moving marker: field line 22 + (field count mod 256) is white
    wire marker = (lc == 10'd22 + {2'd0, fcnt});

    always @(posedge clk) begin
        valid <= 1'b0;
        if (rst) begin
            ph <= 1'b0; xc <= 0; lc <= 0; odd <= 1'b1; fcnt <= 0;
        end else if (en) begin
            ph <= ~ph;
            if (ph) begin
                valid <= 1'b1;
                x <= xc; line <= lc;
                y <= marker ? 12'sd700 : by;
                u <= marker ? 16'sd0 : bu;
                v <= marker ? 16'sd0 : bv;
                if (xc == 11'd1279) begin
                    xc <= 0;
                    if (lc == nlines - 10'd1) begin lc <= 0; odd <= ~odd; fcnt <= fcnt + 8'd1; end
                    else lc <= lc + 10'd1;
                end else xc <= xc + 11'd1;
            end
        end
    end
endmodule
`default_nettype wire
