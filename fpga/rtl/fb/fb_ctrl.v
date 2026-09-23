// Frame-buffer controller (SDRAM clock domain): triple-buffered fields in SDRAM.
//
// Layout (32-bit words): buffer b at b * 147456 (288 lines x 512 words); line pitch
// 512 words (2 SDRAM rows); a line is 360 words (720 px, 4:2:2 {Cr,Y1,Cb,Y0}).
// Bandwidth at 54 MHz (8-word burst ~ 14 clk): write 15.7k lines/s x 45 bursts and
// read <= 18k lines/s x 45 bursts -> ~40 % of the SDRAM (fpga/README.md budget).
//
// Triple buffering: the writer fills wbuf; at the start of a new field it publishes
// wbuf as `newest` and takes the buffer that is neither newest nor rbuf. The output
// side latches rbuf = newest at every output frame start (frame_tog), so a field is
// never read while it is written and the newest complete field is always shown.
`default_nettype none
module fb_ctrl (
    input  wire        clk,
    input  wire        rst,
    // input FIFO (FWFT)
    input  wire [35:0] fifo_data,
    input  wire        fifo_empty,
    input  wire [9:0]  fifo_level,
    output wire        fifo_pop,
    // SDRAM controller
    output reg         sd_req,
    output reg         sd_we,
    output reg  [20:0] sd_addr,
    input  wire        sd_ack,
    input  wire        sd_wd_pop,
    input  wire [31:0] sd_rdata,
    input  wire        sd_rd_valid,
    input  wire        sd_ready,
    // output-side requests (toggle handshakes from the pixel domain, synchronised here)
    input  wire        frame_tog,          // output frame start
    input  wire        req_tog,            // fetch source line req_line into cache slot req_slot
    input  wire [8:0]  req_line,
    input  wire [1:0]  req_slot,
    output reg         done_tog,
    // latched at frame_tog for the output side (stable for a whole output frame)
    output reg         cur_odd,
    output reg         cur_pal,
    output reg         cur_valid,          // a complete field exists
    output reg  [7:0]  field_count,        // increments per completed field (signal-loss detection)
    // line-cache write port (dual-clock RAM in the output path)
    output reg         lc_we,
    output reg  [10:0] lc_waddr,           // {slot[1:0], word[8:0]}
    output reg  [31:0] lc_wdata
);
    localparam [20:0] BUF_WORDS = 21'd147456;
    function [20:0] buf_base(input [1:0] b);
        buf_base = (b == 2'd0) ? 21'd0 : (b == 2'd1) ? BUF_WORDS : BUF_WORDS * 2;
    endfunction

    // ---- CDC for toggles ----
    reg [2:0] ft_s, rt_s;
    always @(posedge clk) begin ft_s <= {ft_s[1:0], frame_tog}; rt_s <= {rt_s[1:0], req_tog}; end
    wire frame_evt = ft_s[2] ^ ft_s[1];
    wire req_evt = rt_s[2] ^ rt_s[1];

    // ---- buffer ownership ----
    reg [1:0] wbuf, newest, rbuf;
    reg       have_newest, w_odd, w_pal, newest_odd, newest_pal, w_any;
    function [1:0] other(input [1:0] a, input [1:0] b);
        other = (a != 2'd0 && b != 2'd0) ? 2'd0 : (a != 2'd1 && b != 2'd1) ? 2'd1 : 2'd2;
    endfunction

    // ---- writer ----
    reg        w_line;                 // a line is being written
    reg [8:0]  w_lineno;
    reg [5:0]  w_burst;                // 0..44
    reg        w_inflight;
    reg [3:0]  w_left;                 // words of the in-flight burst not yet popped
    wire head_desc = !fifo_empty && fifo_data[35];
    // pop descriptors when not in a line; pop pixel words as the SDRAM consumes them
    // (orphan pixel words outside a line are discarded so the FIFO can never wedge)
    assign fifo_pop = (!w_line && !fifo_empty) || (w_inflight && sd_wd_pop);

    // ---- reader ----
    reg        r_pend, r_active;
    reg [8:0]  r_line;
    reg [1:0]  r_slot;
    reg [5:0]  r_burst;
    reg        r_inflight;
    reg [8:0]  r_word;

    always @(posedge clk) begin
        lc_we <= 1'b0;
        if (rst || !sd_ready) begin
            wbuf <= 2'd0; newest <= 2'd1; rbuf <= 2'd2; have_newest <= 1'b0; w_any <= 1'b0;
            w_line <= 1'b0; w_inflight <= 1'b0; r_pend <= 1'b0; r_active <= 1'b0; r_inflight <= 1'b0;
            sd_req <= 1'b0; done_tog <= 1'b0; cur_valid <= 1'b0; field_count <= 0;
        end else begin
            // output frame start: lock the newest complete field
            if (frame_evt) begin
                rbuf <= newest; cur_odd <= newest_odd; cur_pal <= newest_pal; cur_valid <= have_newest;
            end
            if (req_evt) begin r_pend <= 1'b1; r_line <= req_line; r_slot <= req_slot; end

            // descriptor handling
            if (!w_line && head_desc) begin
                if (fifo_data[34] && w_any) begin
                    // start of a new field: publish the finished one, take a free buffer
                    newest <= wbuf; newest_odd <= w_odd; newest_pal <= w_pal; have_newest <= 1'b1;
                    wbuf <= other(wbuf, frame_evt ? newest : rbuf);
                    field_count <= field_count + 8'd1;
                    w_any <= 1'b0;
                end
                w_odd <= fifo_data[33]; w_pal <= fifo_data[32];
                w_lineno <= fifo_data[8:0];
                w_line <= (fifo_data[8:0] < 9'd288);
                w_burst <= 0;
            end

            // issue SDRAM requests: a write burst whenever 8 pixel words are queued
            if (!sd_req && !w_inflight && !r_inflight) begin
                if (w_line && fifo_level >= 10'd8 && !head_desc) begin
                    sd_req <= 1'b1; sd_we <= 1'b1;
                    sd_addr <= buf_base(wbuf) + {w_lineno, 9'd0} + {12'd0, w_burst, 3'd0};
                end else if (r_pend || r_active) begin
                    if (!r_active) begin r_active <= 1'b1; r_pend <= 1'b0; r_burst <= 0; r_word <= 0; end
                    sd_req <= 1'b1; sd_we <= 1'b0;
                    sd_addr <= buf_base(rbuf) + {r_line, 9'd0} + {12'd0, r_active ? r_burst : 6'd0, 3'd0};
                end
            end
            if (sd_req && sd_ack) begin
                sd_req <= 1'b0;
                if (sd_we) begin w_inflight <= 1'b1; w_left <= 4'd8; end
                else r_inflight <= 1'b1;
            end
            // write burst progress
            if (w_inflight && sd_wd_pop) begin
                w_left <= w_left - 4'd1;
                if (w_left == 4'd1) begin
                    w_inflight <= 1'b0;
                    w_any <= 1'b1;
                    if (w_burst == 6'd44) w_line <= 1'b0; else w_burst <= w_burst + 6'd1;
                end
            end
            // read burst progress -> line cache
            if (r_inflight && sd_rd_valid) begin
                lc_we <= 1'b1; lc_waddr <= {r_slot, r_word}; lc_wdata <= sd_rdata;
                r_word <= r_word + 9'd1;
                if (r_word[2:0] == 3'd7) begin
                    r_inflight <= 1'b0;
                    if (r_burst == 6'd44) begin r_active <= 1'b0; done_tog <= ~done_tog; end
                    else r_burst <= r_burst + 6'd1;
                end
            end
        end
    end
endmodule
`default_nettype wire
