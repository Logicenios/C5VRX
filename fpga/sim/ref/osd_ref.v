// On-screen display overlay (pixel clock), drawn after scaling so text stays sharp.
//
// Text window: 40 columns x 16 rows of 8x16 glyphs scaled x2 (16x32 px cells, 640x512 px),
// top-left at (x0, y0). Text RAM: 16 rows x 64 entries of {attr[7:0], char[7:0]}, written by
// the control CPU (clk27) and read here. Font: rtl/osd/font.hex (model/font_rom.py).
//   attr[0]   cell has a background box (video darkened to 1/4 and tinted)
//   attr[3:1] colour: 0 white, 1 yellow, 2 green, 3 red, 4 cyan, 5 grey, 6 black, 7 orange
//   attr[4]   inverse (box in the colour, glyph black): the menu cursor line
// Timing: overlay decision is ready 3 clocks after (hc, vc); `rgb_out` is registered from
// `rgb_in` (which must be valid 6 clocks after (hc, vc)), so rgb_out is valid after 7.
`default_nettype none
module osd_ref (
    input  wire        clk,
    input  wire [10:0] hc,
    input  wire [9:0]  vc,
    input  wire        enable,
    input  wire [10:0] x0,
    input  wire [9:0]  y0,
    // text RAM write port (CPU clock)
    input  wire        wclk,
    input  wire        we,
    input  wire [9:0]  waddr,          // {row[3:0], col[5:0]}
    input  wire [15:0] wdata,
    input  wire [23:0] rgb_in,
    output reg  [23:0] rgb_out
);
    (* ram_style = "block" *) reg [15:0] text [0:1023];
    reg [7:0] font [0:2047];
    initial $readmemh("rtl/osd/font.hex", font);
    always @(posedge wclk) if (we) text[waddr] <= wdata;

    // c0: position
    wire [10:0] dx = hc - x0;
    wire [9:0]  dy = vc - y0;
    wire in_win = enable && (dx < 11'd640) && (dy < 10'd512);
    reg  [15:0] tq;
    reg  [3:0]  gy1; reg [2:0] gx1; reg in1;
    always @(posedge clk) begin
        tq <= text[{dy[8:5], dx[9:4]}];
        gy1 <= dy[4:1]; gx1 <= dx[3:1]; in1 <= in_win;
    end
    // c1: glyph row
    reg [7:0] fq; reg [7:0] at2; reg [2:0] gx2; reg in2;
    always @(posedge clk) begin
        fq <= font[{tq[6:0], gy1}];
        at2 <= tq[15:8]; gx2 <= gx1; in2 <= in1;
    end
    // c2: pixel classification
    function [23:0] colour(input [2:0] c);
        case (c)
            3'd0: colour = 24'hF0F0F0; 3'd1: colour = 24'hF0E040; 3'd2: colour = 24'h40E060;
            3'd3: colour = 24'hF04040; 3'd4: colour = 24'h40D0F0; 3'd5: colour = 24'h909090;
            3'd6: colour = 24'h000000; default: colour = 24'hF09020;
        endcase
    endfunction
    reg        o_fg, o_box; reg [23:0] o_col; reg o_inv;
    always @(posedge clk) begin
        o_fg  <= in2 && fq[3'd7 - gx2];
        o_box <= in2 && at2[0];
        o_inv <= at2[4];
        o_col <= colour(at2[3:1]);
    end
    // delay the decision by 3 to align with rgb_in (valid 6 after (hc, vc))
    reg [2:0] fg_d, box_d, inv_d; reg [23:0] col_d [0:2];
    always @(posedge clk) begin
        fg_d <= {fg_d[1:0], o_fg}; box_d <= {box_d[1:0], o_box}; inv_d <= {inv_d[1:0], o_inv};
        col_d[0] <= o_col; col_d[1] <= col_d[0]; col_d[2] <= col_d[1];
    end
    wire fg = fg_d[2], box = box_d[2], inv = inv_d[2];
    wire [23:0] col = col_d[2];
    wire [23:0] dark = {2'b0, rgb_in[23:18], 2'b0, rgb_in[15:10], 2'b0, rgb_in[7:2]} + 24'h080818;
    always @(posedge clk) begin
        if (inv && box) rgb_out <= fg ? 24'h000000 : col;
        else if (fg) rgb_out <= col;
        else if (box) rgb_out <= dark;
        else rgb_out <= rgb_in;
    end
endmodule
`default_nettype wire
