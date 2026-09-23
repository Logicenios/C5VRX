// Output path (pixel clock domain): field -> 720p with aspect handling and bob.
//
// PRE-SCALER VERSION (Phase 4 gate): nearest-neighbour in both directions, the plan's
// debug mode. The polyphase scaler replaces src_x/src_y selection after the resource
// and timing gate (fpga/README.md).
//
// Geometry: 4:3 -> 960x720 active at x = 160..1119 (160 px black bars); 16:9 stretch
// -> 1280x720. Bob: output line y samples frame position f = (y + 0.5) * 2L/720 - 0.5
// (L = 240 NTSC / 288 PAL lines per field); the field supplies frame lines 2k + p
// (p = 0 odd/top field, 1 even/bottom), so source line k = round((f - p) / 2)
//   = floor(((2y + 1) L + 360 - 720 p) / 1440), clamped to 0..L-1.
`default_nettype none
module out_path (
    input  wire        clk,            // pixel clock
    input  wire        rst,
    input  wire [10:0] hc,
    input  wire [9:0]  vc,
    input  wire        aspect_169,     // 1 = stretch to 1280
    input  wire        cur_odd,        // field info latched by fb_ctrl at frame_tog (2-FF synchronised)
    input  wire        cur_pal,
    input  wire        cur_valid,
    input  wire        dim,            // signal lost: show the last frame dimmed
    // fb_ctrl handshakes
    output reg         frame_tog,
    output reg         req_tog,
    output reg  [8:0]  req_line,
    output reg  [1:0]  req_slot,
    // line cache (dual-clock RAM) write port from fb_ctrl
    input  wire        lc_wclk,
    input  wire        lc_we,
    input  wire [10:0] lc_waddr,
    input  wire [31:0] lc_wdata,
    output reg  [23:0] rgb            // 2 clocks after (hc, vc)
);
    // ---- line cache: 4 slots x 512 words ----
    reg [31:0] lc [0:2047];
    always @(posedge lc_wclk) if (lc_we) lc[lc_waddr] <= lc_wdata;

    // ---- vertical mapping (nearest): source line for output line y (formula above) ----
    // Computed incrementally: N(0) = L + 360 - 720 p (-120..648, k = 0 while negative) and
    // each output line adds 2L (<= 576 < 1440), so k steps by at most one per line.
    wire [9:0] L = cur_pal ? 10'd288 : 10'd240;
    wire [9:0] vn = (vc == 10'd749) ? 10'd0 : vc + 10'd1;
    reg signed [12:0] acc_n;      // N(vn) - 1440 k(vn)
    reg  [8:0]  k_n;              // source line for vn
    reg  [8:0]  src_line;         // source line for vc
    wire [8:0]  src_line_n = k_n;
    wire signed [12:0] acc0 = $signed({3'd0, L}) + 13'sd360 - (cur_odd ? 13'sd0 : 13'sd720);
    wire signed [12:0] acc_step = acc_n + $signed({2'd0, L, 1'b0});
    always @(posedge clk) begin
        if (hc == 11'd0) begin         // line start: src_line for vc, then k_n for vn = vc + 1
            src_line <= k_n;
            if (vn == 10'd0) begin acc_n <= acc0; k_n <= 9'd0; end
            else if (acc_step >= 13'sd1440) begin
                acc_n <= acc_step - 13'sd1440;
                if (k_n != L[8:0] - 9'd1) k_n <= k_n + 9'd1;
            end else acc_n <= acc_step;
        end
    end
    reg  [8:0]  slot_line [0:3];
    reg  [1:0]  next_slot;
    reg  [1:0]  cur_slot;
    reg         req_busy;
    reg  [2:0]  done_s;
    integer i;
    // Output frame event in vertical blanking (line 740 of 750): fb_ctrl latches the newest
    // field and cur_* settle long before line 749 prefetches the first source line.
    wire frame_evt = (vc == 10'd740) && (hc == 11'd0);

    always @(posedge clk) begin
        if (rst) begin
            frame_tog <= 0; req_tog <= 0; next_slot <= 0; req_busy <= 1'b0;
            for (i = 0; i < 4; i = i + 1) slot_line[i] <= 9'h1FF;
        end else begin
            if (frame_evt) begin
                frame_tog <= ~frame_tog;
                for (i = 0; i < 4; i = i + 1) slot_line[i] <= 9'h1FF;   // new field: invalidate
            end
            // at the start of each line, request the next line's source if not cached
            if (hc == 11'd2 && vn < 10'd720 && !req_busy) begin
                if (slot_line[0] != src_line_n && slot_line[1] != src_line_n &&
                    slot_line[2] != src_line_n && slot_line[3] != src_line_n) begin
                    req_line <= src_line_n; req_slot <= next_slot; req_tog <= ~req_tog;
                    slot_line[next_slot] <= src_line_n; next_slot <= next_slot + 2'd1;
                    req_busy <= 1'b1;
                end
            end
            done_s <= {done_s[1:0], 1'b0};
            if (hc == 11'd1300) req_busy <= 1'b0;   // one request per line; fb_ctrl completes in ~12 us
            // slot holding the current line
            if (hc == 11'd2)
                cur_slot <= (slot_line[0] == src_line) ? 2'd0 : (slot_line[1] == src_line) ? 2'd1 :
                            (slot_line[2] == src_line) ? 2'd2 : 2'd3;
        end
    end

    // ---- horizontal mapping (nearest): source pixel for output x ----
    wire        in_43  = (hc >= 11'd160) && (hc < 11'd1120);
    wire [10:0] x43    = hc - 11'd160;
    // 4:3: sx = x * 720 / 960 = x * 3 / 4; 16:9: sx = x * 720 / 1280 = x * 9 / 16
    wire [12:0] sx43   = ({2'd0, x43} * 13'd3) >> 2;
    wire [14:0] sx169  = ({4'd0, hc} * 15'd9) >> 4;
    wire [9:0]  sx     = aspect_169 ? sx169[9:0] : sx43[9:0];
    wire        active = (vc < 10'd720) && (aspect_169 ? (hc < 11'd1280) : in_43) && cur_valid;

    reg [31:0] word;
    reg        sel_odd, act_d;
    always @(posedge clk) begin
        word <= lc[{cur_slot, sx[9:1]}];
        sel_odd <= sx[0];
        act_d <= active;
    end

    // ---- YCbCr (BT.601 limited) -> RGB full range, Q10 ----
    wire [7:0] Y  = sel_odd ? word[23:16] : word[7:0];
    wire [7:0] Cb = word[15:8];
    wire [7:0] Cr = word[31:24];
    wire signed [21:0] yy = ($signed({1'b0, Y}) - 22'sd16) * 22'sd1192;
    wire signed [21:0] cb = $signed({1'b0, Cb}) - 22'sd128;
    wire signed [21:0] cr = $signed({1'b0, Cr}) - 22'sd128;
    wire signed [21:0] r = (yy + cr * 22'sd1634) >>> 10;
    wire signed [21:0] g = (yy - cb * 22'sd401 - cr * 22'sd833) >>> 10;
    wire signed [21:0] b = (yy + cb * 22'sd2065) >>> 10;
    function [7:0] clip(input signed [21:0] v);
        clip = (v < 0) ? 8'd0 : (v > 255) ? 8'd255 : v[7:0];
    endfunction
    wire [7:0] r8 = clip(r), g8 = clip(g), b8 = clip(b);
    always @(posedge clk) begin
        if (!act_d) rgb <= 24'h000000;
        else if (dim) rgb <= {1'b0, r8[7:1], 1'b0, g8[7:1], 1'b0, b8[7:1]};
        else rgb <= {r8, g8, b8};
    end
endmodule
`default_nettype wire
